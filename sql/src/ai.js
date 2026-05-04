/**
 * Kenyalang Careers — AI via Groq (groq-sdk).
 * Set GROQ_API_KEY in .env. Optional: GROQ_MODEL (default llama-3.1-8b-instant).
 */
import Groq from "groq-sdk";

const EMPLOYMENT_LABELS = {
  FULL_TIME: "full-time",
  PART_TIME: "part-time",
  INTERNSHIP: "internship",
};

const PAY_BASIS_LABELS = {
  HOURLY: "per hour",
  DAILY: "per day",
  MONTHLY: "per month",
  OTHER: "as described in the compensation field",
  UNSPECIFIED: "",
};

const DEFAULT_GROQ_MODEL = "llama-3.1-8b-instant";

function splitLines(text) {
  if (text == null || String(text).trim() === "") return [];
  return String(text)
    .split(/\r?\n/)
    .map((s) => s.trim())
    .filter(Boolean);
}

function requireGroqApiKey() {
  const key = process.env.GROQ_API_KEY;
  if (key == null || String(key).trim() === "") {
    throw new Error("GROQ_API_KEY is not configured");
  }
  return String(key).trim();
}

function groqModelId() {
  const m = process.env.GROQ_MODEL;
  return (m && String(m).trim()) || DEFAULT_GROQ_MODEL;
}

let groqClient = null;
function getGroq() {
  if (!groqClient) {
    groqClient = new Groq({ apiKey: requireGroqApiKey() });
  }
  return groqClient;
}

/**
 * Job title from the request: `jobTitle` (preferred) or legacy `title`.
 */
function resolveJobTitle(fields) {
  const raw = fields.jobTitle ?? fields.title;
  return String(raw ?? "").trim();
}

// --- Stub template -----------------------------------------------------------

export function stubJobScope({
  title,
  jobTitle,
  company,
  location,
  salary,
  employmentType,
  extraNotes,
  payBasis = "UNSPECIFIED",
  applicationRequirements = "",
  hiringManagerName = "",
}) {
  const t = resolveJobTitle({ title, jobTitle }) || "this role";
  const co = String(company || "our company").trim();
  const loc = String(location || "").trim() || "on-site / hybrid as agreed";
  const sal = String(salary || "competitive").trim();
  const et = EMPLOYMENT_LABELS[employmentType] || "full-time";
  const pb = PAY_BASIS_LABELS[payBasis] || "";
  const payLine = pb ? `Compensation: ${sal} (${pb}).` : `Compensation: ${sal}.`;
  const notes = extraNotes ? `\n\nAdditional context from employer:\n${String(extraNotes).trim()}` : "";
  const mgr = hiringManagerName ? `\nContact: applications may be coordinated by ${String(hiringManagerName).trim()}.` : "";
  const reqLines = splitLines(applicationRequirements);
  const reqBlock =
    reqLines.length > 0
      ? ["", `What applicants must submit (for this listing)`, ...reqLines.map((line) => `- ${line}`)].join("\n")
      : "";

  return [
    `Overview`,
    `${co} is hiring for ${t} (${et}) based in ${loc}. ${payLine}${mgr}`,
    ``,
    `Key responsibilities`,
    `- Deliver outcomes appropriate to the ${t} role and team priorities`,
    `- Collaborate with colleagues and stakeholders; communicate clearly`,
    `- Meet deadlines and follow company policies and safety / compliance standards`,
    `- Use tools and processes relevant to ${t} as agreed with your manager`,
    ``,
    `What we look for`,
    `- Skills and experience suitable for ${t}, or strong transferable ability`,
    `- Reliability, professionalism, and teamwork`,
    notes,
    reqBlock,
  ]
    .filter(Boolean)
    .join("\n");
}

// --- Job description (Groq) ------------------------------------------------

export async function generateJobDescriptionWithGroq({
  jobTitle,
  title,
  company,
  location,
  salary,
  employmentType,
  extraNotes,
  payBasis = "UNSPECIFIED",
  applicationRequirements = "",
  hiringManagerName = "",
}) {
  const jobTitleDisp = resolveJobTitle({ jobTitle, title });
  if (!jobTitleDisp) {
    throw new Error("jobTitle (or title) is required for AI job description generation");
  }

  const etKey = employmentType;
  const et = EMPLOYMENT_LABELS[etKey] || "full-time";
  const pb = PAY_BASIS_LABELS[payBasis] || "";
  const locDisp = (location && String(location).trim()) || "Not specified by employer";
  const salDisp = (salary && String(salary).trim()) || "Not specified by employer";
  const notesLines = splitLines(extraNotes);
  const appReqLines = splitLines(applicationRequirements);
  const mgr = (hiringManagerName && String(hiringManagerName).trim()) || "";

  const payBasisInstruction = pb
    ? `Pay is quoted ${pb}. Mention compensation exactly once in the Overview using only the employer’s wording: "${salDisp}". Do not add other amounts, ranges, bonuses, or benefits not implied there.`
    : `Mention compensation once in the Overview using only the employer’s wording: "${salDisp}". Do not invent numbers or benefits.`;

  const notesBlock =
    notesLines.length > 0
      ? [
          `Employer draft / keywords (you MUST work these into Responsibilities and/or Requirements with concrete bullets — do not ignore):`,
          ...notesLines.map((l, i) => `${i + 1}. ${l}`),
        ].join("\n")
      : `No extra draft text — infer realistic, role-specific duties from the job title "${jobTitleDisp}" only.`;

  const appReqBlock =
    appReqLines.length > 0
      ? [
          `Applicants will later be asked to submit the following (reflect under Requirements as document / eligibility expectations, one clear bullet per line):`,
          ...appReqLines.map((l, i) => `${i + 1}. ${l}`),
        ].join("\n")
      : "";

  const userContent = [
    `You are drafting a professional job listing for Kenyalang Careers (Malaysia).`,
    `The role is exactly: "${jobTitleDisp}". Every section must be specific to that job title — not generic office filler.`,
    ``,
    `=== FACT SHEET (do not contradict; preserve job title spelling, company name, location wording, compensation wording) ===`,
    `Job title (use this exact string at least once in the Overview): ${jobTitleDisp}`,
    `Company: ${company}`,
    `Location / work arrangement (use this phrasing): ${locDisp}`,
    `Compensation as stated by employer: ${salDisp}`,
    `Employment type (enum=${etKey}, use this label everywhere): ${et}`,
    payBasisInstruction,
    mgr ? `Hiring manager (optional; mention at most once in Overview if natural): ${mgr}` : "",
    ``,
    notesBlock,
    ``,
    appReqBlock,
    ``,
    `=== OUTPUT FORMAT ===`,
    `Plain text only. No markdown code fences. No preamble or chat sign-off.`,
    `Section headings in order, each on its own line: Overview, Responsibilities, Requirements, Nice to have`,
    ``,
    `Overview: 2–4 sentences. First sentence must say ${company} is hiring for ${jobTitleDisp}, ${et}, in/at ${locDisp}, with compensation exactly: ${salDisp}. Briefly state the sector/function implied by "${jobTitleDisp}".`,
    `Responsibilities: 5–8 lines starting with "- ". Day-to-day work realistic for "${jobTitleDisp}" in Malaysia/Southeast Asia. If keywords were given, at least half the bullets must reflect them.`,
    `Requirements: 4–7 lines. Qualifications typical for "${jobTitleDisp}". If applicant submissions were listed, each as a bullet.`,
    `Nice to have: 2–4 optional lines specific to "${jobTitleDisp}".`,
  ]
    .filter(Boolean)
    .join("\n");

  const systemContent = [
    "You help employers write job posts for Kenyalang Careers.",
    "Follow the FACT SHEET exactly for title, company, location, and pay.",
    "Different job titles must produce meaningfully different responsibilities and requirements.",
    "Output only the four sections with the requested headings.",
  ].join(" ");

  const client = getGroq();
  const model = groqModelId();

  let completion;
  try {
    completion = await client.chat.completions.create({
      model,
      temperature: 0.35,
      max_tokens: 4096,
      messages: [
        { role: "system", content: systemContent },
        { role: "user", content: userContent },
      ],
    });
  } catch (e) {
    throw new Error(`Groq error: ${e?.message ?? e}`);
  }

  const text = completion?.choices?.[0]?.message?.content?.trim();
  if (!text) throw new Error("Empty response from Groq");
  return text;
}

/** Used by `index.js`. */
export async function generateJobScopeWithOpenAI(params) {
  return generateJobDescriptionWithGroq(params);
}

/** @deprecated Prefer generateJobDescriptionWithGroq */
export async function generateJobDescriptionWithGemini(params) {
  return generateJobDescriptionWithGroq(params);
}

// --- Formal inbox (Groq + JSON) --------------------------------------------

export function stubFormalInboxDraft({ jobTitle, company, recipientLabel, intent, notes, isEmployer }) {
  const jt = String(jobTitle || "your application").trim();
  const co = String(company || "our company").trim();
  const who = String(recipientLabel || "there").trim();
  const n = notes ? String(notes).trim() : "";
  const intro = isEmployer
    ? `Dear ${who},\n\nThank you for your interest in the ${jt} opportunity at ${co}.`
    : `Dear hiring team,\n\nRegarding my application for ${jt} at ${co},`;

  let subj = "Update regarding your application";
  if (intent === "interview") subj = `Interview — ${jt}`;
  else if (intent === "offer") subj = `Next steps — ${jt}`;
  else if (intent === "documents") subj = `Documents requested — ${jt}`;

  const body = [
    intro,
    "",
    n ? `Details:\n${n}\n` : "We will share more details shortly.",
    "",
    "Kind regards",
  ].join("\n");

  return { title: subj, body };
}

export async function generateFormalInboxWithGroq({ jobTitle, company, recipientLabel, intent, notes, isEmployer }) {
  if (!process.env.GROQ_API_KEY?.trim()) return null;

  const roleLine = isEmployer
    ? "You are the employer writing a short formal message to an applicant."
    : "You are a job seeker writing a short formal message to an employer.";

  const userContent = [
    roleLine,
    `Job title: ${jobTitle || "n/a"}`,
    `Company: ${company || "n/a"}`,
    `Recipient reference: ${recipientLabel || "n/a"}`,
    `Intent: ${intent || "general_update"} (interview | offer | documents | general_update).`,
    notes ? `Notes to reflect: ${notes}` : "",
    ``,
    `Return a JSON object with keys "title" (string, max 120 characters) and "body" (string, plain text, 2–6 short paragraphs, professional). No other keys, no markdown.`,
  ]
    .filter(Boolean)
    .join("\n");

  const client = getGroq();
  const model = groqModelId();

  let completion;
  try {
    completion = await client.chat.completions.create({
      model,
      temperature: 0.6,
      max_tokens: 2048,
      response_format: { type: "json_object" },
      messages: [
        { role: "system", content: "You output only valid JSON with string fields title and body." },
        { role: "user", content: userContent },
      ],
    });
  } catch (e) {
    throw new Error(`Groq error: ${e?.message ?? e}`);
  }

  const raw = completion?.choices?.[0]?.message?.content?.trim();
  if (!raw) throw new Error("Empty response from Groq");

  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch {
    throw new Error("Groq did not return valid JSON");
  }

  const outTitle = String(parsed.title || "Message").slice(0, 200);
  const body = String(parsed.body || "").trim();
  if (!body) throw new Error("Empty body in Groq JSON");
  return { title: outTitle, body };
}

export async function generateFormalInboxWithOpenAI(params) {
  return generateFormalInboxWithGroq(params);
}

/** @deprecated Prefer generateFormalInboxWithGroq */
export async function generateFormalInboxWithGemini(params) {
  return generateFormalInboxWithGroq(params);
}
