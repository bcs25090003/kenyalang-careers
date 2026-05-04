import "dotenv/config";
import express from "express";
import "express-async-errors";
import cors from "cors";
import crypto from "crypto";
import bcrypt from "bcrypt";
import { OAuth2Client } from "google-auth-library";
import { pool, ensureSchemaPatches } from "./db.js";
import { generateJobScopeWithOpenAI, stubFormalInboxDraft, generateFormalInboxWithOpenAI } from "./ai.js";

const BCRYPT_ROUNDS = 10;

function normStr(v) {
  if (v == null) return null;
  const s = String(v).trim();
  return s === "" ? null : s;
}

/** Client IDs whose ID tokens this API accepts (Web + optional native). */
function googleOAuthAudiences() {
  const ids = [];
  const w = normStr(process.env.GOOGLE_OAUTH_WEB_CLIENT_ID);
  if (w) ids.push(w);
  const a = normStr(process.env.GOOGLE_OAUTH_ANDROID_CLIENT_ID);
  if (a) ids.push(a);
  const i = normStr(process.env.GOOGLE_OAUTH_IOS_CLIENT_ID);
  if (i) ids.push(i);
  return ids;
}

/** Same JSON shape as `POST /auth/login` success (no password fields). */
async function buildSessionUserResponse(userId) {
  const uid = Number(userId);
  if (!uid) return null;
  const [[user]] = await pool.query(
    `SELECT u.id, u.email, u.name, u.role, u.phone, u.gov_id AS govId,
            u.address, u.verified_company AS verifiedCompany, u.about_text AS aboutText,
            COALESCE(u.avatar_base64, sp.profile_avatar_base64) AS avatarBase64
     FROM users u
     LEFT JOIN seeker_profiles sp ON sp.user_id = u.id
     WHERE u.id=?`,
    [uid]
  );
  if (!user) return null;
  const av = user.avatarBase64;
  return {
    id: user.id,
    email: user.email,
    name: user.name,
    role: user.role,
    phone: user.phone,
    govId: user.govId,
    address: user.address,
    verifiedCompany: user.verifiedCompany,
    aboutText: user.aboutText != null ? String(user.aboutText) : null,
    avatarBase64: av != null ? String(av) : null,
  };
}

async function saveUserAvatar(userId, imageBase64) {
  const b64 = String(imageBase64);
  const [[row]] = await pool.query(`SELECT role FROM users WHERE id=?`, [userId]);
  if (!row) throw new Error("user not found");
  await pool.query(`UPDATE users SET avatar_base64=? WHERE id=?`, [b64, userId]);
  if (row.role === "SEEKER") {
    await pool.query(
      `INSERT INTO seeker_profiles (user_id, profile_avatar_base64) VALUES (?, ?)
       ON DUPLICATE KEY UPDATE profile_avatar_base64=VALUES(profile_avatar_base64)`,
      [userId, b64]
    );
  }
}

async function assertProfileReadyForActions(userId) {
  const uid = Number(userId);
  const [[u]] = await pool.query(
    `SELECT role, phone, gov_id, avatar_base64, id_doc_base64 FROM users WHERE id=?`,
    [uid]
  );
  if (!u) throw new Error("user not found");
  if (!normStr(u.phone)) throw new Error("Add your phone number on Profile before continuing");
  if (!normStr(u.gov_id)) throw new Error("Add your identity card number on Profile before continuing");
  if (!u.avatar_base64) throw new Error("Upload a profile photo before continuing");
  if (!u.id_doc_base64) throw new Error("Upload your ID document on Profile before continuing");
  if (u.role === "SEEKER") {
    const [[sp]] = await pool.query(`SELECT ic_doc_base64 FROM seeker_profiles WHERE user_id=?`, [uid]);
    if (!sp?.ic_doc_base64) throw new Error("Upload your IC scan on Profile (Resume tab) before continuing");
  }
}

const EMPLOYMENT_TYPES = new Set(["FULL_TIME", "PART_TIME", "INTERNSHIP"]);
const PAY_BASIS = new Set(["HOURLY", "DAILY", "MONTHLY", "OTHER", "UNSPECIFIED"]);

const app = express();
// Any origin for now (Render + local + Flutter). `origin: true` reflects the request Origin so
// `credentials: true` stays valid (wildcard * cannot be used with credentials in browsers).
app.use(
  cors({
    origin: true,
    credentials: true,
    methods: ["GET", "HEAD", "PUT", "PATCH", "POST", "DELETE", "OPTIONS"],
    allowedHeaders: ["Content-Type", "Authorization", "Accept"],
  })
);
app.use(express.json({ limit: "12mb" }));

/** Shared inbox delete (mounted on multiple POST paths for proxy / stale-cache quirks). */
async function deleteFormalInboxMessage(req, res) {
  const messageId = Number(req.body?.messageId);
  const userId = Number(req.body?.userId);
  if (!messageId || !userId) return res.status(400).json({ error: "messageId and userId required" });
  try {
    const [r] = await pool.query(`DELETE FROM formal_inbox WHERE id=? AND recipient_user_id=?`, [messageId, userId]);
    if (!r.affectedRows) return res.status(404).json({ error: "Message not found" });
    res.json({ ok: true });
  } catch (e) {
    console.error("[deleteFormalInboxMessage]", e);
    res.status(500).json({ error: String(e?.message ?? e) });
  }
}

/** Shared notification delete. */
async function deleteNotificationRecord(req, res) {
  const notificationId = Number(req.body?.notificationId);
  const userId = Number(req.body?.userId);
  if (!notificationId || !userId) return res.status(400).json({ error: "notificationId and userId required" });
  try {
    const [r] = await pool.query(`DELETE FROM notifications WHERE id=? AND user_id=?`, [notificationId, userId]);
    if (!r.affectedRows) return res.status(404).json({ error: "Notification not found" });
    res.json({ ok: true });
  } catch (e) {
    console.error("[deleteNotificationRecord]", e);
    res.status(500).json({ error: String(e?.message ?? e) });
  }
}

app.get("/health", async (_req, res) => {
  try {
    const [rows] = await pool.query("SELECT 1 AS ok");
    res.json({
      ok: true,
      db: rows?.[0]?.ok === 1,
      // Bump when adding routes so you can confirm the running API is current.
      apiBuild: "2026-05-04-groq-llama3-job-description",
    });
  } catch (e) {
    res.status(500).json({ ok: false, error: String(e?.message ?? e) });
  }
});

// --- Auth (email / phone + password; MySQL is source of truth) ---
app.post("/auth/register", async (req, res) => {
  const {
    email,
    password,
    name,
    role = "SEEKER",
    phone = null,
    govId = null,
  } = req.body ?? {};
  const cleanEmail = normStr(email)?.toLowerCase() ?? null;
  const cleanName = normStr(name);
  const cleanPhone = normStr(phone);
  const cleanGov = normStr(govId);
  if (!cleanEmail || !password || !cleanName) {
    return res.status(400).json({ error: "email, password, and name required" });
  }
  if (String(password).length < 8) return res.status(400).json({ error: "password must be at least 8 characters" });

  const r = role === "EMPLOYER" ? "EMPLOYER" : "SEEKER";
  let hash;
  try {
    hash = await bcrypt.hash(String(password), BCRYPT_ROUNDS);
  } catch {
    return res.status(500).json({ error: "password hash failed" });
  }

  try {
    const [result] = await pool.query(
      `INSERT INTO users (email, name, password_hash, role, phone, gov_id) VALUES (?, ?, ?, ?, ?, ?)`,
      [cleanEmail, cleanName, hash, r, cleanPhone, cleanGov]
    );
    const id = result.insertId;
    res.json({
      id,
      email: cleanEmail,
      name: cleanName,
      role: r,
      phone: cleanPhone,
      govId: cleanGov,
      verifiedCompany: 0,
    });
  } catch (e) {
    if (String(e?.code) === "ER_DUP_ENTRY") {
      const msg = String(e?.message ?? "");
      if (msg.includes("uq_users_email") || msg.includes("email")) {
        return res.status(409).json({ error: "An account with this email already exists" });
      }
      if (msg.includes("uq_users_phone")) {
        return res.status(409).json({ error: "This phone number is already registered" });
      }
      if (msg.includes("uq_users_gov_id")) {
        return res.status(409).json({ error: "This ID number is already registered to another account" });
      }
      return res.status(409).json({ error: "Duplicate value (email, phone, or identity card number)" });
    }
    res.status(500).json({ error: String(e?.message ?? e) });
  }
});

app.post("/auth/login", async (req, res) => {
  const { emailOrPhone, password } = req.body ?? {};
  const ident = normStr(emailOrPhone);
  if (!ident || !password) return res.status(400).json({ error: "emailOrPhone and password required" });

  let rows;
  if (ident.includes("@")) {
    [rows] = await pool.query(
      `SELECT u.id, u.email, u.name, u.role, u.password_hash AS passwordHash, u.google_sub AS googleSub, u.phone, u.gov_id AS govId,
              u.address, u.verified_company AS verifiedCompany, u.about_text AS aboutText,
              COALESCE(u.avatar_base64, sp.profile_avatar_base64) AS avatarBase64
       FROM users u
       LEFT JOIN seeker_profiles sp ON sp.user_id = u.id
       WHERE u.email=? LIMIT 1`,
      [ident.toLowerCase()]
    );
  } else {
    [rows] = await pool.query(
      `SELECT u.id, u.email, u.name, u.role, u.password_hash AS passwordHash, u.google_sub AS googleSub, u.phone, u.gov_id AS govId,
              u.address, u.verified_company AS verifiedCompany, u.about_text AS aboutText,
              COALESCE(u.avatar_base64, sp.profile_avatar_base64) AS avatarBase64
       FROM users u
       LEFT JOIN seeker_profiles sp ON sp.user_id = u.id
       WHERE u.phone=? LIMIT 1`,
      [ident]
    );
  }
  if (rows.length === 0) return res.status(401).json({ error: "Invalid email/phone or password" });

  const user = rows[0];
  if (!user.passwordHash) {
    const googleOnly = Boolean(user.googleSub);
    return res.status(401).json({
      error: googleOnly
        ? "This account uses Google sign-in. Use “Sign in with Google”, or set a password via Forgot password (when email delivery is configured)."
        : "This account has no password set. Use account recovery or contact support.",
    });
  }

  const ok = await bcrypt.compare(String(password), String(user.passwordHash));
  if (!ok) return res.status(401).json({ error: "Invalid email/phone or password" });

  const out = await buildSessionUserResponse(user.id);
  if (!out) return res.status(500).json({ error: "Session build failed" });
  res.json(out);
});

app.post("/auth/google", async (req, res) => {
  const idToken = normStr(req.body?.idToken);
  if (!idToken) return res.status(400).json({ error: "idToken required" });

  const audiences = googleOAuthAudiences();
  if (!audiences.length) {
    return res.status(503).json({
      error:
        "Google Sign-In is not configured on this server. Set GOOGLE_OAUTH_WEB_CLIENT_ID (and optionally GOOGLE_OAUTH_ANDROID_CLIENT_ID / GOOGLE_OAUTH_IOS_CLIENT_ID).",
    });
  }

  const client = new OAuth2Client();
  let payload;
  try {
    const ticket = await client.verifyIdToken({
      idToken,
      audience: audiences.length === 1 ? audiences[0] : audiences,
    });
    payload = ticket.getPayload();
  } catch {
    return res.status(401).json({ error: "Invalid or expired Google token" });
  }

  if (!payload?.sub) return res.status(401).json({ error: "Invalid Google token" });
  const email = normStr(payload.email)?.toLowerCase();
  if (!email) return res.status(400).json({ error: "Your Google account has no email address" });
  if (!payload.email_verified) {
    return res.status(400).json({ error: "Your Google email must be verified before signing in" });
  }

  const sub = String(payload.sub);
  const nameFromToken = normStr(payload.name) || email.split("@")[0];

  const [[bySub]] = await pool.query(
    `SELECT id, google_sub AS googleSub, email FROM users WHERE google_sub=? LIMIT 1`,
    [sub]
  );

  let userId;
  if (bySub) {
    userId = Number(bySub.id);
  } else {
    const [[byEmail]] = await pool.query(
      `SELECT id, google_sub AS googleSub, email FROM users WHERE email=? LIMIT 1`,
      [email]
    );
    if (byEmail) {
      if (byEmail.googleSub && String(byEmail.googleSub) !== sub) {
        return res.status(409).json({ error: "This email is already linked to a different Google account" });
      }
      userId = Number(byEmail.id);
      if (!byEmail.googleSub) {
        await pool.query(`UPDATE users SET google_sub=? WHERE id=?`, [sub, userId]);
      }
    } else {
      const [ins] = await pool.query(
        `INSERT INTO users (email, name, role, password_hash, google_sub) VALUES (?, ?, 'SEEKER', NULL, ?)`,
        [email, nameFromToken, sub]
      );
      userId = Number(ins.insertId);
    }
  }

  const out = await buildSessionUserResponse(userId);
  if (!out) return res.status(500).json({ error: "User lookup failed" });
  res.json(out);
});

app.post("/auth/forgot-password", async (req, res) => {
  const raw = normStr(req.body?.emailOrPhone ?? req.body?.email);
  if (!raw) return res.status(400).json({ error: "email or phone required" });

  let rows;
  if (raw.includes("@")) {
    [rows] = await pool.query(`SELECT id FROM users WHERE email=? LIMIT 1`, [raw.toLowerCase()]);
  } else {
    [rows] = await pool.query(`SELECT id FROM users WHERE phone=? LIMIT 1`, [raw]);
  }
  const generic = {
    ok: true,
    message: "If an account exists for that email or phone, password reset instructions were sent.",
  };

  if (rows.length === 0) return res.json(generic);

  const userId = rows[0].id;
  const token = crypto.randomBytes(32).toString("hex");
  const expires = new Date(Date.now() + 60 * 60 * 1000);
  await pool.query(`DELETE FROM password_resets WHERE user_id=?`, [userId]);
  await pool.query(`INSERT INTO password_resets (user_id, token, expires_at) VALUES (?, ?, ?)`, [userId, token, expires]);

  const devHint =
    process.env.NODE_ENV === "production"
      ? undefined
      : { devResetToken: token, devResetExpires: expires.toISOString() };

  res.json({ ...generic, ...devHint });
});

app.post("/auth/reset-password", async (req, res) => {
  const { token, newPassword } = req.body ?? {};
  const cleanTok = normStr(token);
  if (!cleanTok || !newPassword) return res.status(400).json({ error: "token and newPassword required" });
  if (String(newPassword).length < 8) return res.status(400).json({ error: "password must be at least 8 characters" });

  const [rows] = await pool.query(
    `SELECT user_id AS userId FROM password_resets WHERE token=? AND expires_at > NOW() LIMIT 1`,
    [cleanTok]
  );
  if (rows.length === 0) return res.status(400).json({ error: "Invalid or expired reset link" });

  const userId = rows[0].userId;
  const hash = await bcrypt.hash(String(newPassword), BCRYPT_ROUNDS);
  await pool.query(`UPDATE users SET password_hash=? WHERE id=?`, [hash, userId]);
  await pool.query(`DELETE FROM password_resets WHERE user_id=?`, [userId]);
  res.json({ ok: true });
});

app.get("/users/:id/full", async (req, res) => {
  const id = Number(req.params.id);
  if (!id) return res.status(400).json({ error: "invalid id" });

  const [[user]] = await pool.query(
    `SELECT u.id, u.email, u.name, u.role, u.phone, u.gov_id AS govId, u.address, u.verified_company AS verifiedCompany,
            u.about_text AS aboutText, u.id_doc_filename AS idDocFilename,
            COALESCE(u.avatar_base64, sp.profile_avatar_base64) AS avatarBase64
     FROM users u
     LEFT JOIN seeker_profiles sp ON sp.user_id = u.id
     WHERE u.id=?`,
    [id]
  );
  if (!user) return res.status(404).json({ error: "User not found" });

  const avatarStr = user.avatarBase64 != null ? String(user.avatarBase64) : null;
  const userOut = {
    id: user.id,
    email: user.email,
    name: user.name,
    role: user.role,
    phone: user.phone,
    govId: user.govId,
    address: user.address,
    verifiedCompany: user.verifiedCompany,
    aboutText: user.aboutText != null ? String(user.aboutText) : null,
    idDocFilename: user.idDocFilename != null ? String(user.idDocFilename) : null,
    avatarBase64: avatarStr,
  };

  let seekerProfile = null;
  if (userOut.role === "SEEKER") {
    const [[sp]] = await pool.query(
      `SELECT user_id AS userId, ic_number AS icNumber, age, phone AS profilePhone, address AS profileAddress,
              education, experience, skills, personal_word AS personalWord, open_to_work AS openToWork,
              ic_doc_filename AS icDocFilename, transcript_doc_filename AS transcriptDocFilename
       FROM seeker_profiles WHERE user_id=?`,
      [id]
    );
    seekerProfile = sp ?? null;
  }

  res.json({ user: userOut, seekerProfile });
});

app.post("/users/set-role", async (req, res) => {
  const { userId, role } = req.body ?? {};
  const uid = Number(userId);
  if (!uid) return res.status(400).json({ error: "userId required" });
  const r = role === "EMPLOYER" ? "EMPLOYER" : "SEEKER";
  await pool.query(`UPDATE users SET role=? WHERE id=?`, [r, uid]);
  res.json({ ok: true, role: r });
});

app.post("/users/profile-update", async (req, res) => {
  const body = req.body ?? {};
  const uid = Number(body.userId);
  if (!uid) return res.status(400).json({ error: "userId required" });

  const n = normStr(body.name);
  try {
    if (n) await pool.query(`UPDATE users SET name=? WHERE id=?`, [n, uid]);
    const sets = [];
    const vals = [];
    if ("phone" in body) {
      sets.push("phone=?");
      vals.push(normStr(body.phone));
    }
    if ("address" in body) {
      sets.push("address=?");
      vals.push(normStr(body.address));
    }
    if ("govId" in body) {
      sets.push("gov_id=?");
      vals.push(normStr(body.govId));
    }
    if ("aboutText" in body) {
      sets.push("about_text=?");
      vals.push(normStr(body.aboutText));
    }
    if (sets.length) {
      vals.push(uid);
      await pool.query(`UPDATE users SET ${sets.join(", ")} WHERE id=?`, vals);
    }
    res.json({ ok: true });
  } catch (e) {
    if (String(e?.code) === "ER_DUP_ENTRY") {
      return res.status(409).json({ error: "Phone or identity card number already in use" });
    }
    res.status(500).json({ error: String(e?.message ?? e) });
  }
});

app.post("/auth/change-password", async (req, res) => {
  const { userId, currentPassword, newPassword } = req.body ?? {};
  const uid = Number(userId);
  if (!uid || !currentPassword || !newPassword) {
    return res.status(400).json({ error: "userId, currentPassword, newPassword required" });
  }
  if (String(newPassword).length < 8) return res.status(400).json({ error: "new password must be at least 8 characters" });

  const [[u]] = await pool.query(`SELECT password_hash AS h FROM users WHERE id=?`, [uid]);
  if (!u?.h) return res.status(400).json({ error: "No password on file" });
  const ok = await bcrypt.compare(String(currentPassword), String(u.h));
  if (!ok) return res.status(401).json({ error: "Current password is incorrect" });
  const hash = await bcrypt.hash(String(newPassword), BCRYPT_ROUNDS);
  await pool.query(`UPDATE users SET password_hash=? WHERE id=?`, [hash, uid]);
  res.json({ ok: true });
});

app.post("/seeker-profiles/upload-docs", async (req, res) => {
  const {
    userId,
    icBase64 = null,
    icFilename = null,
    transcriptBase64 = null,
    transcriptFilename = null,
  } = req.body ?? {};
  const uid = Number(userId);
  if (!uid) return res.status(400).json({ error: "userId required" });

  const ib64 = icBase64 ? String(icBase64) : null;
  const tb64 = transcriptBase64 ? String(transcriptBase64) : null;
  if (!ib64 && !tb64) return res.status(400).json({ error: "icBase64 or transcriptBase64 required" });

  const ifn = normStr(icFilename) ?? (ib64 ? "upload" : null);
  const tfn = normStr(transcriptFilename) ?? (tb64 ? "upload" : null);

  await pool.query(
    `INSERT INTO seeker_profiles (user_id) VALUES (?)
     ON DUPLICATE KEY UPDATE user_id=user_id`,
    [uid]
  );

  const parts = [];
  const vals = [];
  if (ib64) {
    parts.push("ic_doc_base64=?", "ic_doc_filename=?");
    vals.push(ib64, ifn ?? "upload.bin");
  }
  if (tb64) {
    parts.push("transcript_doc_base64=?", "transcript_doc_filename=?");
    vals.push(tb64, tfn ?? "upload.bin");
  }
  vals.push(uid);
  await pool.query(`UPDATE seeker_profiles SET ${parts.join(", ")} WHERE user_id=?`, vals);
  res.json({ ok: true });
});

app.post("/users/avatar", async (req, res) => {
  const { userId, imageBase64 } = req.body ?? {};
  const uid = Number(userId);
  if (!uid || !imageBase64) return res.status(400).json({ error: "userId and imageBase64 required" });
  try {
    await saveUserAvatar(uid, imageBase64);
    res.json({ ok: true });
  } catch (e) {
    res.status(500).json({ error: String(e?.message ?? e) });
  }
});

app.post("/users/id-doc", async (req, res) => {
  const { userId, imageBase64, filename = "id" } = req.body ?? {};
  const uid = Number(userId);
  if (!uid || !imageBase64) return res.status(400).json({ error: "userId and imageBase64 required" });
  await pool.query(`UPDATE users SET id_doc_base64=?, id_doc_filename=? WHERE id=?`, [
    String(imageBase64),
    normStr(filename) ?? "upload",
    uid,
  ]);
  res.json({ ok: true });
});

app.get("/users/:id/profile-ready", async (req, res) => {
  const id = Number(req.params.id);
  if (!id) return res.status(400).json({ error: "invalid id" });
  try {
    await assertProfileReadyForActions(id);
    res.json({ ok: true });
  } catch (e) {
    res.json({ ok: false, message: String(e?.message ?? e) });
  }
});

app.post("/seeker-profiles/avatar", async (req, res) => {
  const { userId, imageBase64 } = req.body ?? {};
  const uid = Number(userId);
  if (!uid || !imageBase64) return res.status(400).json({ error: "userId and imageBase64 required" });
  try {
    await saveUserAvatar(uid, imageBase64);
    res.json({ ok: true });
  } catch (e) {
    res.status(500).json({ error: String(e?.message ?? e) });
  }
});

// Create or fetch a user row (legacy dev helper; prefer /auth/register + /auth/login)
app.post("/users/ensure", async (req, res) => {
  const { email = null, name = null, role = "SEEKER" } = req.body ?? {};
  const cleanEmail = typeof email === "string" ? email.trim().toLowerCase() : null;
  const cleanName = typeof name === "string" ? name.trim() : null;

  if (!cleanEmail && !cleanName) return res.status(400).json({ error: "email or name required" });

  if (cleanEmail) {
    const [existing] = await pool.query(`SELECT id, email, name, role, verified_company AS verifiedCompany FROM users WHERE email=?`, [
      cleanEmail,
    ]);
    if (existing.length > 0) return res.json(existing[0]);
  }

  const [result] = await pool.query(`INSERT INTO users (email, name, role) VALUES (?, ?, ?)`, [
    cleanEmail,
    cleanName,
    role === "EMPLOYER" ? "EMPLOYER" : "SEEKER",
  ]);

  res.json({ id: result.insertId, email: cleanEmail, name: cleanName, role, verifiedCompany: 0 });
});

// NOTE: For now this backend uses a simple "userId" passed by client.
// In production: replace with proper auth (JWT/Firebase) and derive userId server-side.

app.post("/ai/job-description", async (req, res) => {
  const body = req.body ?? {};
  const title = normStr(body.title) ?? normStr(body.jobTitle);
  const co = normStr(body.co);
  const {
    loc,
    sal,
    employmentType = "FULL_TIME",
    extraNotes = "",
    payBasis = "UNSPECIFIED",
    applicationRequirements = "",
    hiringManagerName = "",
  } = body;
  if (!title || !co) {
    return res.status(400).json({ error: "title (or jobTitle) and co are required" });
  }
  const et = EMPLOYMENT_TYPES.has(String(employmentType)) ? String(employmentType) : "FULL_TIME";
  const pb = PAY_BASIS.has(String(payBasis)) ? String(payBasis) : "UNSPECIFIED";

  try {
    const aiText = await generateJobScopeWithOpenAI({
      jobTitle: title,
      title,
      company: co,
      location: loc,
      salary: sal,
      employmentType: et,
      extraNotes,
      payBasis: pb,
      applicationRequirements: normStr(applicationRequirements) ?? "",
      hiringManagerName: normStr(hiringManagerName) ?? "",
    });
    return res.json({ text: aiText, source: "groq" });
  } catch (e) {
    const message = e?.message ?? String(e);
    console.warn("AI job description failed:", message);
    return res.status(502).json({
      error: "ai_generation_failed",
      message,
    });
  }
});

app.post("/ai/formal-message", async (req, res) => {
  const { jobTitle, company, recipientLabel, intent = "general_update", notes = "", isEmployer = true } = req.body ?? {};
  if (!jobTitle || String(jobTitle).trim() === "") {
    return res.status(400).json({ error: "jobTitle required" });
  }
  const emp = Boolean(isEmployer);
  try {
    const draft = await generateFormalInboxWithOpenAI({
      jobTitle,
      company,
      recipientLabel,
      intent: String(intent),
      notes: String(notes),
      isEmployer: emp,
    });
    if (draft) return res.json({ ...draft, source: "groq" });
  } catch (e) {
    console.warn("AI formal message failed, using template:", e?.message ?? e);
  }
  const out = stubFormalInboxDraft({
    jobTitle,
    company,
    recipientLabel,
    intent: String(intent),
    notes: String(notes),
    isEmployer: emp,
  });
  res.json({
    ...out,
    source: process.env.GROQ_API_KEY?.trim() ? "fallback" : "template",
  });
});

app.get("/jobs", async (_req, res) => {
  const [rows] = await pool.query(
    `SELECT id, employer_user_id AS employerUserId, title, company_name AS co, hiring_manager_name AS bossName, location AS loc,
            salary_text AS sal, employment_type AS employmentType,
            COALESCE(pay_basis, 'UNSPECIFIED') AS payBasis,
            scope AS \`desc\`,
            max_applicants AS maxApps, available_slots AS maxSlots,
            applied_count AS appliedCount, hired_count AS acceptedCount, status,
            image_base64 AS imageBase64, application_requirements AS applicationRequirements
     FROM jobs
     ORDER BY id DESC`
  );
  res.json(rows);
});

app.get("/jobs/:jobId/contact-for-seeker", async (req, res) => {
  const jobId = Number(req.params.jobId);
  const seekerUserId = Number(req.query.seekerUserId);
  if (!jobId || !seekerUserId) return res.status(400).json({ error: "jobId and seekerUserId required" });

  const [[row]] = await pool.query(
    `SELECT a.status AS applicationStatus, j.employer_user_id AS employerUserId
     FROM applications a INNER JOIN jobs j ON j.id = a.job_id
     WHERE a.job_id=? AND a.seeker_user_id=? LIMIT 1`,
    [jobId, seekerUserId]
  );
  if (!row) return res.json({ visible: false });
  if (row.applicationStatus === "REJECTED") return res.json({ visible: false, rejected: true });

  const eid = Number(row.employerUserId);
  const [[eu]] = await pool.query(
    `SELECT name, email, phone, address, about_text AS aboutText FROM users WHERE id=?`,
    [eid]
  );
  res.json({ visible: true, employer: eu ?? null });
});

async function deleteJobByEmployer(req, res, jobIdOverride = null) {
  const jobId = Number(jobIdOverride ?? req.params.jobId);
  const employerUserId = Number(req.body?.employerUserId);
  if (!jobId || !employerUserId) return res.status(400).json({ error: "jobId and employerUserId required" });

  const conn = await pool.getConnection();
  try {
    await conn.beginTransaction();
    const [[job]] = await conn.query(`SELECT id, employer_user_id FROM jobs WHERE id=? FOR UPDATE`, [jobId]);
    if (!job) {
      await conn.rollback();
      return res.status(404).json({ error: "Job not found" });
    }
    if (job.employer_user_id != null && Number(job.employer_user_id) !== employerUserId) {
      await conn.rollback();
      return res.status(403).json({ error: "Not allowed to delete this job" });
    }

    await conn.query(
      `DELETE im FROM interview_messages im
       INNER JOIN interviews i ON i.id = im.interview_id
       WHERE i.job_id = ?`,
      [jobId]
    );
    await conn.query(`DELETE FROM interviews WHERE job_id=?`, [jobId]);
    await conn.query(`DELETE FROM applications WHERE job_id=?`, [jobId]);
    await conn.query(`DELETE FROM jobs WHERE id=?`, [jobId]);
    await conn.commit();
    res.json({ ok: true });
  } catch (e) {
    await conn.rollback();
    res.status(500).json({ error: String(e?.message ?? e) });
  } finally {
    conn.release();
  }
}

app.delete("/jobs/:jobId", (req, res) => deleteJobByEmployer(req, res));

// POST: reliable on Flutter web (DELETE + JSON body is often dropped by browsers).
app.post("/jobs/remove", (req, res) => deleteJobByEmployer(req, res, Number(req.body?.jobId)));

app.post("/jobs", async (req, res) => {
  const {
    employerUserId = null,
    title,
    co,
    bossName,
    loc,
    sal,
    desc,
    employmentType = "FULL_TIME",
    payBasis = "UNSPECIFIED",
    maxApps = 50,
    maxSlots = 10,
    imageBase64 = null,
    applicationRequirements = null,
  } = req.body ?? {};

  if (!title || !co || !bossName || !loc || !sal || !desc) {
    return res.status(400).json({ error: "Missing required fields" });
  }
  const euid = Number(employerUserId);
  if (!euid) return res.status(400).json({ error: "employerUserId required" });

  try {
    await assertProfileReadyForActions(euid);
  } catch (e) {
    return res.status(400).json({ error: String(e?.message ?? e) });
  }

  const et = EMPLOYMENT_TYPES.has(String(employmentType)) ? String(employmentType) : "FULL_TIME";
  const pb = PAY_BASIS.has(String(payBasis)) ? String(payBasis) : "UNSPECIFIED";
  const img = imageBase64 ? String(imageBase64) : null;
  const appReq = normStr(applicationRequirements);

  const [result] = await pool.query(
    `INSERT INTO jobs (employer_user_id, title, company_name, hiring_manager_name, location, salary_text, employment_type, pay_basis, scope, max_applicants, available_slots, image_base64, application_requirements)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    [euid, title, co, bossName, loc, sal, et, pb, desc, Number(maxApps), Number(maxSlots), img, appReq]
  );

  res.json({ id: result.insertId });
});

app.patch("/jobs/:jobId", async (req, res) => {
  const jobId = Number(req.params.jobId);
  const employerUserId = Number(req.body?.employerUserId);
  if (!jobId || !employerUserId) return res.status(400).json({ error: "jobId and employerUserId required" });

  const {
    title = null,
    co = null,
    bossName = null,
    loc = null,
    sal = null,
    desc = null,
    employmentType = null,
    payBasis = null,
    maxApps = null,
    maxSlots = null,
    imageBase64 = undefined,
    applicationRequirements = undefined,
  } = req.body ?? {};

  const [[job]] = await pool.query(`SELECT id, employer_user_id, title FROM jobs WHERE id=?`, [jobId]);
  if (!job) return res.status(404).json({ error: "Job not found" });
  if (job.employer_user_id == null || Number(job.employer_user_id) !== employerUserId) {
    return res.status(403).json({ error: "Not allowed to edit this job" });
  }

  const sets = [];
  const vals = [];
  if (title != null) {
    sets.push("title=?");
    vals.push(String(title));
  }
  if (co != null) {
    sets.push("company_name=?");
    vals.push(String(co));
  }
  if (bossName != null) {
    sets.push("hiring_manager_name=?");
    vals.push(String(bossName));
  }
  if (loc != null) {
    sets.push("location=?");
    vals.push(String(loc));
  }
  if (sal != null) {
    sets.push("salary_text=?");
    vals.push(String(sal));
  }
  if (desc != null) {
    sets.push("scope=?");
    vals.push(String(desc));
  }
  if (employmentType != null && EMPLOYMENT_TYPES.has(String(employmentType))) {
    sets.push("employment_type=?");
    vals.push(String(employmentType));
  }
  if (payBasis != null && PAY_BASIS.has(String(payBasis))) {
    sets.push("pay_basis=?");
    vals.push(String(payBasis));
  }
  if (maxApps != null && Number(maxApps) > 0) {
    sets.push("max_applicants=?");
    vals.push(Number(maxApps));
  }
  if (maxSlots != null && Number(maxSlots) > 0) {
    sets.push("available_slots=?");
    vals.push(Number(maxSlots));
  }
  if (imageBase64 !== undefined) {
    sets.push("image_base64=?");
    vals.push(imageBase64 ? String(imageBase64) : null);
  }
  if (applicationRequirements !== undefined) {
    sets.push("application_requirements=?");
    vals.push(normStr(applicationRequirements));
  }

  if (sets.length === 0) return res.json({ ok: true, message: "Nothing to update" });

  vals.push(jobId);
  await pool.query(`UPDATE jobs SET ${sets.join(", ")} WHERE id=?`, vals);

  const [[updated]] = await pool.query(`SELECT title FROM jobs WHERE id=?`, [jobId]);
  const displayTitle = updated?.title ?? job.title ?? "Job";

  const [applicants] = await pool.query(`SELECT DISTINCT seeker_user_id AS uid FROM applications WHERE job_id=?`, [jobId]);
  for (const a of applicants) {
    const sid = Number(a.uid);
    if (!sid) continue;
    await pool.query(`INSERT INTO notifications (user_id, type, title, body) VALUES (?, ?, ?, ?)`, [
      sid,
      "job_update",
      `Job updated: ${displayTitle}`,
      `The employer updated the listing "${displayTitle}". Open Jobs and tap the role to see the latest description and details.`,
    ]);
  }

  res.json({ ok: true });
});

app.post("/jobs/:jobId/apply", async (req, res) => {
  const jobId = Number(req.params.jobId);
  const { seekerUserId, personalWord = null, applicantExtras = null } = req.body ?? {};
  if (!jobId || !seekerUserId) return res.status(400).json({ error: "jobId and seekerUserId required" });

  const sid = Number(seekerUserId);
  try {
    await assertProfileReadyForActions(sid);
  } catch (e) {
    return res.status(400).json({ error: String(e?.message ?? e) });
  }

  const conn = await pool.getConnection();
  try {
    await conn.beginTransaction();

    const [[job]] = await conn.query(
      `SELECT id, employer_user_id, title, company_name, max_applicants, available_slots, applied_count, hired_count, status,
              application_requirements AS applicationRequirements
       FROM jobs WHERE id=? FOR UPDATE`,
      [jobId]
    );
    if (!job) {
      await conn.rollback();
      return res.status(404).json({ error: "Job not found" });
    }

    const isFull =
      job.status !== "OPEN" ||
      job.applied_count >= job.max_applicants ||
      job.hired_count >= job.available_slots;

    if (isFull) {
      await conn.rollback();
      return res.status(409).json({ error: "Job is full/closed" });
    }

    const reqText = job.applicationRequirements != null ? String(job.applicationRequirements).trim() : "";
    let extrasJson = null;
    if (reqText) {
      const lines = reqText
        .split(/\r?\n/)
        .map((l) => l.trim())
        .filter(Boolean);
      const extras = Array.isArray(applicantExtras) ? applicantExtras : [];
      if (lines.length > 0 && extras.length < lines.length) {
        await conn.rollback();
        return res.status(400).json({
          error: `This job requires ${lines.length} document upload(s). Complete each item before applying.`,
        });
      }
      extrasJson = extras.length ? JSON.stringify(extras) : null;
    } else if (Array.isArray(applicantExtras) && applicantExtras.length) {
      extrasJson = JSON.stringify(applicantExtras);
    }

    const pw = normStr(personalWord);
    if (pw) {
      await conn.query(
        `INSERT INTO seeker_profiles (user_id, personal_word) VALUES (?, ?)
         ON DUPLICATE KEY UPDATE personal_word=VALUES(personal_word)`,
        [sid, pw]
      );
    }

    // Unique key prevents duplicates.
    await conn.query(
      `INSERT INTO applications (job_id, seeker_user_id, status, applicant_extras_json)
       VALUES (?, ?, 'NEW', ?)`,
      [jobId, sid, extrasJson]
    );

    await conn.query(`UPDATE jobs SET applied_count = applied_count + 1 WHERE id=?`, [jobId]);

    // Notifications: one to employer, one to seeker
    if (job.employer_user_id) {
      await conn.query(
        `INSERT INTO notifications (user_id, type, title, body) VALUES (?, ?, ?, ?)`,
        [
          job.employer_user_id,
          "apply",
          `New application: ${job.title}`,
          `Someone applied for ${job.title} at ${job.company_name}.`,
        ]
      );
    }
    await conn.query(
      `INSERT INTO notifications (user_id, type, title, body) VALUES (?, ?, ?, ?)`,
      [sid, "apply", `Applied: ${job.title}`, `Your application was sent successfully.`]
    );

    await conn.commit();
    res.json({ ok: true });
  } catch (e) {
    await conn.rollback();
    // Duplicate apply
    if (String(e?.code) === "ER_DUP_ENTRY") return res.status(409).json({ error: "Already applied" });
    res.status(500).json({ error: String(e?.message ?? e) });
  } finally {
    conn.release();
  }
});

app.get("/applications/has-applied", async (req, res) => {
  const jobId = Number(req.query.jobId);
  const seekerUserId = Number(req.query.seekerUserId);
  if (!jobId || !seekerUserId) return res.status(400).json({ error: "jobId and seekerUserId required" });

  const [rows] = await pool.query(`SELECT id FROM applications WHERE job_id=? AND seeker_user_id=? LIMIT 1`, [
    jobId,
    seekerUserId,
  ]);
  res.json({ applied: rows.length > 0 });
});

app.get("/applications/for-seeker", async (req, res) => {
  const seekerUserId = Number(req.query.seekerUserId);
  if (!seekerUserId) return res.status(400).json({ error: "seekerUserId required" });

  const [rows] = await pool.query(
    `SELECT a.id AS applicationId, a.job_id AS jobId, a.status AS statusDb,
            j.title AS jobTitle, j.company_name AS companyName, j.employer_user_id AS employerUserId, eu.name AS employerName
     FROM applications a
     INNER JOIN jobs j ON j.id = a.job_id
     LEFT JOIN users eu ON eu.id = j.employer_user_id
     WHERE a.seeker_user_id=?
     ORDER BY a.id DESC
     LIMIT 100`,
    [seekerUserId]
  );

  const mapped = rows.map((r) => ({
    ...r,
    status: r.statusDb === "NEW" ? "New" : String(r.statusDb),
  }));
  res.json(mapped);
});

app.get("/applications/for-employer", async (req, res) => {
  const employerUserId = Number(req.query.employerUserId);
  if (!employerUserId) return res.status(400).json({ error: "employerUserId required" });

  const [rows] = await pool.query(
    `SELECT a.id AS applicationId, a.job_id AS jobId, j.title AS jobTitle, j.company_name AS companyName,
            a.seeker_user_id AS seekerUserId, u.name AS name, a.status AS statusDb,
            a.rejection_reason AS rejectionReason,
            CASE WHEN a.status = 'REJECTED' THEN NULL ELSE sp.skills END AS skills,
            CASE WHEN a.status = 'REJECTED' THEN NULL ELSE sp.education END AS edu,
            CASE WHEN a.status = 'REJECTED' THEN NULL ELSE sp.personal_word END AS personalWord,
            CASE WHEN a.status = 'REJECTED' THEN NULL ELSE COALESCE(sp.phone, u.phone) END AS phone,
            CASE WHEN a.status = 'REJECTED' THEN NULL ELSE sp.experience END AS exp,
            CASE WHEN a.status = 'REJECTED' THEN NULL ELSE sp.ic_number END AS icNumber,
            CASE WHEN a.status = 'REJECTED' THEN NULL ELSE COALESCE(sp.address, u.address) END AS profileAddress,
            CASE WHEN a.status = 'REJECTED' THEN NULL ELSE u.gov_id END AS govId,
            CASE WHEN a.status = 'REJECTED' THEN NULL ELSE u.email END AS email,
            CASE WHEN a.status = 'REJECTED' THEN NULL ELSE COALESCE(u.avatar_base64, sp.profile_avatar_base64) END AS seekerAvatarBase64
     FROM applications a
     INNER JOIN jobs j ON j.id = a.job_id
     INNER JOIN users u ON u.id = a.seeker_user_id
     LEFT JOIN seeker_profiles sp ON sp.user_id = a.seeker_user_id
     WHERE j.employer_user_id = ?
     ORDER BY a.id DESC`,
    [employerUserId]
  );

  const mapped = rows.map((r) => ({
    ...r,
    status: r.statusDb === "NEW" ? "New" : String(r.statusDb),
    canViewSensitive: r.statusDb !== "REJECTED",
  }));
  res.json(mapped);
});

/** Employer (job owner) only: seeker ID/IC/transcript + files attached for this application. */
app.get("/applications/:applicationId/documents-for-employer", async (req, res) => {
  const applicationId = Number(req.params.applicationId);
  const employerUserId = Number(req.query.employerUserId);
  if (!applicationId || !employerUserId) {
    return res.status(400).json({ error: "applicationId and employerUserId required" });
  }

  const [[row]] = await pool.query(
    `SELECT a.id, a.status AS statusDb, a.applicant_extras_json AS applicantExtrasJson,
            j.employer_user_id AS employerUserId, a.seeker_user_id AS seekerUserId
     FROM applications a
     INNER JOIN jobs j ON j.id = a.job_id
     WHERE a.id=?`,
    [applicationId]
  );
  if (!row) return res.status(404).json({ error: "Application not found" });
  if (Number(row.employerUserId) !== employerUserId) return res.status(403).json({ error: "Not allowed" });
  if (row.statusDb === "REJECTED") {
    return res.status(403).json({ error: "Documents are not available for rejected applications." });
  }

  const sid = Number(row.seekerUserId);
  const [[u]] = await pool.query(
    `SELECT id_doc_base64 AS dataBase64, id_doc_filename AS filename FROM users WHERE id=?`,
    [sid]
  );
  const [[sp]] = await pool.query(
    `SELECT ic_doc_base64 AS icDataBase64, ic_doc_filename AS icFilename,
            transcript_doc_base64 AS transcriptDataBase64, transcript_doc_filename AS transcriptFilename
     FROM seeker_profiles WHERE user_id=?`,
    [sid]
  );

  let applicationAttachments = [];
  if (row.applicantExtrasJson) {
    try {
      const parsed = JSON.parse(String(row.applicantExtrasJson));
      if (Array.isArray(parsed)) applicationAttachments = parsed;
    } catch (_) {
      applicationAttachments = [];
    }
  }

  const idDocument =
    u?.dataBase64 && u?.filename
      ? { filename: String(u.filename), dataBase64: String(u.dataBase64) }
      : null;
  const icDocument =
    sp?.icDataBase64 && sp?.icFilename
      ? { filename: String(sp.icFilename), dataBase64: String(sp.icDataBase64) }
      : null;
  const transcriptDocument =
    sp?.transcriptDataBase64 && sp?.transcriptFilename
      ? { filename: String(sp.transcriptFilename), dataBase64: String(sp.transcriptDataBase64) }
      : null;

  res.json({
    idDocument,
    icDocument,
    transcriptDocument,
    applicationAttachments,
  });
});

app.post("/applications/:applicationId/reject", async (req, res) => {
  const applicationId = Number(req.params.applicationId);
  const { employerUserId, reason } = req.body ?? {};
  const eid = Number(employerUserId);
  if (!applicationId || !eid) return res.status(400).json({ error: "applicationId and employerUserId required" });

  const [[a]] = await pool.query(
    `SELECT a.id, a.seeker_user_id AS sid, a.job_id AS jid, j.employer_user_id AS eid
     FROM applications a INNER JOIN jobs j ON j.id = a.job_id WHERE a.id=?`,
    [applicationId]
  );
  if (!a) return res.status(404).json({ error: "Application not found" });
  if (Number(a.eid) !== eid) return res.status(403).json({ error: "Not allowed" });

  const reasonStr = normStr(reason) ?? "";
  await pool.query(`UPDATE applications SET status='REJECTED', rejection_reason=? WHERE id=?`, [reasonStr, applicationId]);
  await pool.query(`UPDATE interviews SET status='Rejected' WHERE job_id=? AND seeker_user_id=?`, [a.jid, a.sid]);

  const title = "Application not successful";
  const body = reasonStr ? `The employer declined your application.\n\nReason: ${reasonStr}` : `The employer declined your application.`;
  await pool.query(
    `INSERT INTO formal_inbox (recipient_user_id, sender_user_id, job_id, application_id, kind, title, body)
     VALUES (?, ?, ?, ?, 'rejection_summary', ?, ?)`,
    [Number(a.sid), eid, Number(a.jid), applicationId, title, body]
  );
  await pool.query(`INSERT INTO notifications (user_id, type, title, body) VALUES (?, ?, ?, ?)`, [
    Number(a.sid),
    "reject",
    title,
    body.slice(0, 400),
  ]);

  res.json({ ok: true });
});

app.get("/inbox", async (req, res) => {
  const userId = Number(req.query.userId);
  if (!userId) return res.status(400).json({ error: "userId required" });

  try {
    const [rows] = await pool.query(
      `SELECT f.id, f.sender_user_id AS senderUserId, f.recipient_user_id AS recipientUserId, f.job_id AS jobId,
            f.application_id AS applicationId, f.kind, f.title, f.body, f.is_read AS isRead, f.created_at AS createdAt,
            j.title AS jobTitle, su.name AS senderName
     FROM formal_inbox f
     LEFT JOIN jobs j ON j.id = f.job_id
     LEFT JOIN users su ON su.id = f.sender_user_id
     WHERE f.recipient_user_id=?
     ORDER BY f.id DESC LIMIT 100`,
      [userId]
    );
    res.json(rows);
  } catch (e) {
    console.error("[GET /inbox]", e);
    res.status(500).json({ error: String(e?.message ?? e) });
  }
});

app.post("/inbox/mark-read", async (req, res) => {
  const userId = Number(req.body?.userId);
  if (!userId) return res.status(400).json({ error: "userId required" });
  try {
    await pool.query(`UPDATE formal_inbox SET is_read=1 WHERE recipient_user_id=? AND is_read=0`, [userId]);
    res.json({ ok: true });
  } catch (e) {
    console.error("[POST /inbox/mark-read]", e);
    res.status(500).json({ error: String(e?.message ?? e) });
  }
});

app.post("/inbox/mark-one-read", async (req, res) => {
  const userId = Number(req.body?.userId);
  const messageId = Number(req.body?.messageId);
  if (!userId || !messageId) return res.status(400).json({ error: "userId and messageId required" });
  try {
    const [r] = await pool.query(
      `UPDATE formal_inbox SET is_read=1 WHERE id=? AND recipient_user_id=?`,
      [messageId, userId]
    );
    res.json({ ok: true, affected: r.affectedRows ?? 0 });
  } catch (e) {
    console.error("[POST /inbox/mark-one-read]", e);
    res.status(500).json({ error: String(e?.message ?? e) });
  }
});

app.delete("/inbox/:messageId", async (req, res) => {
  const messageId = Number(req.params.messageId);
  const userId = Number(req.body?.userId);
  if (!messageId || !userId) return res.status(400).json({ error: "messageId and userId required" });
  try {
    const [r] = await pool.query(`DELETE FROM formal_inbox WHERE id=? AND recipient_user_id=?`, [messageId, userId]);
    if (!r.affectedRows) return res.status(404).json({ error: "Message not found" });
    res.json({ ok: true });
  } catch (e) {
    console.error("[DELETE /inbox/:messageId]", e);
    res.status(500).json({ error: String(e?.message ?? e) });
  }
});

// POST variants (Flutter web + some proxies mishandle DELETE with body).
app.post("/inbox/delete", deleteFormalInboxMessage);
app.post("/formal-inbox/remove", deleteFormalInboxMessage);
// Extra aliases (some proxies / older clients only hit certain paths).
app.post("/inbox/remove", deleteFormalInboxMessage);
app.post("/formalinbox/remove", deleteFormalInboxMessage);

app.post("/inbox/send", async (req, res) => {
  const { senderUserId, recipientUserId, jobId, title, body } = req.body ?? {};
  const s = Number(senderUserId);
  const r = Number(recipientUserId);
  const j = Number(jobId);
  if (!s || !r || !j || body == null || String(body).trim() === "") {
    return res.status(400).json({ error: "senderUserId, recipientUserId, jobId, and body required" });
  }

  const [[job]] = await pool.query(`SELECT employer_user_id FROM jobs WHERE id=?`, [j]);
  if (!job) return res.status(404).json({ error: "Job not found" });
  const emp = Number(job.employer_user_id);
  if (s !== emp && r !== emp) return res.status(403).json({ error: "Invalid participants" });
  const seekerId = s === emp ? r : s;

  const [[appRow]] = await pool.query(`SELECT id, status FROM applications WHERE job_id=? AND seeker_user_id=?`, [j, seekerId]);
  if (!appRow) return res.status(400).json({ error: "No application for this job" });
  if (appRow.status === "REJECTED") return res.status(403).json({ error: "This application is closed" });

  try {
    const tit = normStr(title) ?? (s === emp ? "Message from employer" : "Message from applicant");
    const bod = String(body);
    await pool.query(
      `INSERT INTO formal_inbox (recipient_user_id, sender_user_id, job_id, application_id, kind, title, body)
     VALUES (?, ?, ?, ?, 'formal_message', ?, ?)`,
      [r, s, j, appRow.id, tit, bod]
    );
    await pool.query(`INSERT INTO notifications (user_id, type, title, body) VALUES (?, ?, ?, ?)`, [
      r,
      "inbox",
      tit,
      bod.slice(0, 240),
    ]);
    res.json({ ok: true });
  } catch (e) {
    console.error("[POST /inbox/send]", e);
    res.status(500).json({ error: String(e?.message ?? e) });
  }
});

app.post("/seeker-profiles/upsert", async (req, res) => {
  const {
    userId,
    name = null,
    icNumber = null,
    age = null,
    phone = null,
    address = null,
    education = null,
    experience = null,
    skills = null,
    personalWord = null,
    openToWork = 0,
  } = req.body ?? {};
  if (!userId) return res.status(400).json({ error: "userId required" });

  const uid = Number(userId);
  if (name != null && String(name).trim() !== "") {
    await pool.query(`UPDATE users SET name=? WHERE id=?`, [String(name).trim(), uid]);
  }

  await pool.query(
    `INSERT INTO seeker_profiles (user_id, ic_number, age, phone, address, education, experience, skills, personal_word, open_to_work)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
     ON DUPLICATE KEY UPDATE
       ic_number=VALUES(ic_number), age=VALUES(age), phone=VALUES(phone), address=VALUES(address),
       education=VALUES(education), experience=VALUES(experience), skills=VALUES(skills),
       personal_word=VALUES(personal_word), open_to_work=VALUES(open_to_work)`,
    [
      uid,
      icNumber ?? null,
      age ?? null,
      phone ?? null,
      address ?? null,
      education ?? null,
      experience ?? null,
      skills ?? null,
      personalWord ?? null,
      openToWork ? 1 : 0,
    ]
  );

  res.json({ ok: true });
});

app.get("/notifications", async (req, res) => {
  const userId = Number(req.query.userId);
  if (!userId) return res.status(400).json({ error: "userId required" });

  const [rows] = await pool.query(
    `SELECT id, type, title, body, is_read AS isRead, created_at AS createdAt
     FROM notifications
     WHERE user_id=?
     ORDER BY id DESC
     LIMIT 100`,
    [userId]
  );
  res.json(rows);
});

app.post("/notifications/mark-read", async (req, res) => {
  const { userId } = req.body ?? {};
  if (!userId) return res.status(400).json({ error: "userId required" });

  await pool.query(`UPDATE notifications SET is_read=1 WHERE user_id=? AND is_read=0`, [Number(userId)]);
  res.json({ ok: true });
});

app.delete("/notifications/:notificationId", async (req, res) => {
  const notificationId = Number(req.params.notificationId);
  const userId = Number(req.body?.userId);
  if (!notificationId || !userId) return res.status(400).json({ error: "notificationId and userId required" });
  try {
    const [r] = await pool.query(`DELETE FROM notifications WHERE id=? AND user_id=?`, [notificationId, userId]);
    if (!r.affectedRows) return res.status(404).json({ error: "Notification not found" });
    res.json({ ok: true });
  } catch (e) {
    console.error("[DELETE /notifications/:notificationId]", e);
    res.status(500).json({ error: String(e?.message ?? e) });
  }
});

app.post("/notifications/delete", deleteNotificationRecord);
app.post("/notification/remove", deleteNotificationRecord);

// ==========================================
// INTERVIEWS + CHAT (stored in MySQL)
// ==========================================
app.get("/interviews", async (req, res) => {
  const userId = Number(req.query.userId);
  const role = String(req.query.role ?? "");
  if (!userId) return res.status(400).json({ error: "userId required" });
  if (role !== "EMPLOYER" && role !== "SEEKER") return res.status(400).json({ error: "role must be EMPLOYER or SEEKER" });

  const where = role === "EMPLOYER" ? "employer_user_id=?" : "seeker_user_id=?";
  const [rows] = await pool.query(
    `SELECT i.id, i.job_id AS jobId, i.employer_user_id AS employerUserId, i.seeker_user_id AS seekerUserId,
            i.platform, i.datetime_text AS datetime, i.proposed_datetime_text AS proposedDatetime,
            i.link_text AS link, i.status, i.updated_at AS updatedAt, i.created_at AS createdAt,
            ej.title AS jobTitle, ej.company_name AS companyName,
            su.name AS seekerName, eu.name AS employerName,
            app.id AS applicationId, app.status AS applicationStatus, app.rejection_reason AS applicationRejectionReason,
            (
              SELECT COUNT(*) FROM interview_messages m
              WHERE m.interview_id = i.id
                AND m.sender_user_id <> ?
                AND m.id > COALESCE((
                  SELECT c.last_read_message_id FROM interview_read_cursors c
                  WHERE c.user_id = ? AND c.interview_id = i.id LIMIT 1
                ), 0)
            ) AS unreadMessageCount
     FROM interviews i
     LEFT JOIN jobs ej ON ej.id = i.job_id
     LEFT JOIN users su ON su.id = i.seeker_user_id
     LEFT JOIN users eu ON eu.id = i.employer_user_id
     LEFT JOIN applications app ON app.job_id = i.job_id AND app.seeker_user_id = i.seeker_user_id
     WHERE i.${where}
     ORDER BY i.id DESC
     LIMIT 100`,
    [userId, userId, userId]
  );
  res.json(rows);
});

app.post("/interviews", async (req, res) => {
  const { jobId = null, employerUserId, seekerUserId, platform, datetime, link = "", status = "Pending Seeker" } = req.body ?? {};
  if (!employerUserId || !seekerUserId || !platform || !datetime) {
    return res.status(400).json({ error: "employerUserId, seekerUserId, platform, datetime required" });
  }

  const [result] = await pool.query(
    `INSERT INTO interviews (job_id, employer_user_id, seeker_user_id, platform, datetime_text, link_text, status)
     VALUES (?, ?, ?, ?, ?, ?, ?)`,
    [jobId ? Number(jobId) : null, Number(employerUserId), Number(seekerUserId), String(platform), String(datetime), String(link), String(status)]
  );

  // Notify seeker
  await pool.query(
    `INSERT INTO notifications (user_id, type, title, body) VALUES (?, ?, ?, ?)`,
    [Number(seekerUserId), "invite", "Interview invite received", `Platform: ${platform}\nTime: ${datetime}`]
  );

  res.json({ id: result.insertId });
});

app.post("/interviews/:id/update", async (req, res) => {
  const interviewId = Number(req.params.id);
  const { actorUserId, datetime = null, proposedDatetime = null, link = null, status = null } = req.body ?? {};
  if (!interviewId || !actorUserId) return res.status(400).json({ error: "actorUserId required" });

  const [[inv]] = await pool.query(
    `SELECT id, job_id AS jobId, employer_user_id AS employerUserId, seeker_user_id AS seekerUserId
     FROM interviews WHERE id=?`,
    [interviewId]
  );
  if (!inv) return res.status(404).json({ error: "Interview not found" });

  const fields = [];
  const vals = [];
  if (datetime !== null) {
    fields.push("datetime_text=?");
    vals.push(String(datetime));
  }
  if (proposedDatetime !== null) {
    fields.push("proposed_datetime_text=?");
    vals.push(proposedDatetime === "" ? null : String(proposedDatetime));
  }
  if (link !== null) {
    fields.push("link_text=?");
    vals.push(String(link));
  }
  if (status !== null) {
    fields.push("status=?");
    vals.push(String(status));
  }
  if (fields.length === 0) return res.json({ ok: true });

  vals.push(interviewId);
  await pool.query(`UPDATE interviews SET ${fields.join(", ")} WHERE id=?`, vals);

  if (status !== null && String(status) === "HIRED" && inv.jobId) {
    const jid = Number(inv.jobId);
    const sid = Number(inv.seekerUserId);
    const eid = Number(inv.employerUserId);
    await pool.query(`UPDATE applications SET status='HIRED' WHERE job_id=? AND seeker_user_id=?`, [jid, sid]);
    const [[appRow]] = await pool.query(`SELECT id FROM applications WHERE job_id=? AND seeker_user_id=?`, [jid, sid]);
    const hireBody = `Congratulations — you have been hired for this role.\n\nYour employer may follow up through your Inbox with next steps.`;
    await pool.query(
      `INSERT INTO formal_inbox (recipient_user_id, sender_user_id, job_id, application_id, kind, title, body)
       VALUES (?, ?, ?, ?, 'hire_congrats', ?, ?)`,
      [sid, eid, jid, appRow?.id ?? null, "You're hired", hireBody]
    );
    await pool.query(`INSERT INTO notifications (user_id, type, title, body) VALUES (?, ?, ?, ?)`, [
      sid,
      "hire",
      "You're hired",
      hireBody.slice(0, 240),
    ]);
  }

  // Notify the other party
  const actor = Number(actorUserId);
  const target = actor === Number(inv.employerUserId) ? Number(inv.seekerUserId) : Number(inv.employerUserId);
  await pool.query(
    `INSERT INTO notifications (user_id, type, title, body) VALUES (?, ?, ?, ?)`,
    [target, "interview_change", "Interview updated", `Interview #${interviewId} updated.`]
  );

  res.json({ ok: true });
});

app.get("/interviews/:id/messages", async (req, res) => {
  const interviewId = Number(req.params.id);
  if (!interviewId) return res.status(400).json({ error: "invalid interview id" });

  const [rows] = await pool.query(
    `SELECT id, sender_user_id AS senderUserId, message_text AS text, created_at AS createdAt
     FROM interview_messages
     WHERE interview_id=?
     ORDER BY id ASC
     LIMIT 500`,
    [interviewId]
  );
  res.json(rows);
});

app.post("/interviews/:id/messages", async (req, res) => {
  const interviewId = Number(req.params.id);
  const { senderUserId, text } = req.body ?? {};
  if (!interviewId || !senderUserId || !text) return res.status(400).json({ error: "senderUserId and text required" });

  const conn = await pool.getConnection();
  try {
    await conn.beginTransaction();
    const [[inv]] = await conn.query(
      `SELECT employer_user_id AS employerUserId, seeker_user_id AS seekerUserId, job_id AS jobId FROM interviews WHERE id=? FOR UPDATE`,
      [interviewId]
    );
    if (!inv) {
      await conn.rollback();
      return res.status(404).json({ error: "Interview not found" });
    }

    const [[appChk]] = await conn.query(
      `SELECT status FROM applications WHERE job_id=? AND seeker_user_id=? LIMIT 1`,
      [inv.jobId, inv.seekerUserId]
    );
    if (appChk?.status === "REJECTED") {
      await conn.rollback();
      return res.status(403).json({ error: "Application was rejected; messaging is closed." });
    }

    await conn.query(
      `INSERT INTO interview_messages (interview_id, sender_user_id, message_text) VALUES (?, ?, ?)`,
      [interviewId, Number(senderUserId), String(text)]
    );

    const target = Number(senderUserId) === Number(inv.employerUserId) ? Number(inv.seekerUserId) : Number(inv.employerUserId);
    await conn.query(
      `INSERT INTO notifications (user_id, type, title, body) VALUES (?, ?, ?, ?)`,
      [target, "chat", "New message", `You received a new message on interview #${interviewId}.`]
    );

    await conn.commit();
    res.json({ ok: true });
  } catch (e) {
    await conn.rollback();
    res.status(500).json({ error: String(e?.message ?? e) });
  } finally {
    conn.release();
  }
});

app.post("/interviews/:id/messages/mark-read", async (req, res) => {
  const interviewId = Number(req.params.id);
  const { userId } = req.body ?? {};
  if (!interviewId || !userId) return res.status(400).json({ error: "interview id and userId required" });

  const [[inv]] = await pool.query(
    `SELECT employer_user_id AS e, seeker_user_id AS s FROM interviews WHERE id=?`,
    [interviewId]
  );
  if (!inv) return res.status(404).json({ error: "Interview not found" });
  const uid = Number(userId);
  if (uid !== Number(inv.e) && uid !== Number(inv.s)) return res.status(403).json({ error: "Not a participant" });

  const [[m]] = await pool.query(`SELECT COALESCE(MAX(id), 0) AS mid FROM interview_messages WHERE interview_id=?`, [
    interviewId,
  ]);
  const lastId = Number(m?.mid ?? 0);
  await pool.query(
    `INSERT INTO interview_read_cursors (user_id, interview_id, last_read_message_id) VALUES (?, ?, ?)
     ON DUPLICATE KEY UPDATE last_read_message_id = GREATEST(COALESCE(last_read_message_id, 0), VALUES(last_read_message_id))`,
    [uid, interviewId, lastId]
  );
  res.json({ ok: true, lastReadMessageId: lastId });
});

app.use((err, _req, res, _next) => {
  console.error(err);
  if (res.headersSent) return;
  res.status(500).json({ error: String(err?.message ?? err) });
});

// Render sets PORT; local dev uses 4000. Bind 0.0.0.0 so the dyno accepts external traffic.
const PORT = process.env.PORT || 4000;

ensureSchemaPatches()
  .then(() => {
    app.listen(PORT, "0.0.0.0", () => {
      console.log(`API listening on http://localhost:${PORT} (bound 0.0.0.0:${PORT})`);
    });
  })
  .catch((e) => {
    console.error("[ensureSchemaPatches]", e);
    process.exit(1);
  });

