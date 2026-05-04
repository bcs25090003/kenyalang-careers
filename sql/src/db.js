import mysql from "mysql2/promise";

const {
  DB_HOST = "127.0.0.1",
  // docker-compose maps MySQL to host 3307 (to avoid conflicts)
  DB_PORT = "3307",
  DB_USER = "kenyalang",
  DB_PASSWORD = "kenyalang",
  DB_NAME = "kenyalang_careers",
} = process.env;

export const pool = mysql.createPool({
  host: DB_HOST,
  port: Number(DB_PORT),
  user: DB_USER,
  password: DB_PASSWORD,
  database: DB_NAME,
  connectionLimit: 10,
});

async function columnExists(table, column) {
  const [[row]] = await pool.query(
    `SELECT COUNT(*) AS c FROM information_schema.COLUMNS
     WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ? AND COLUMN_NAME = ?`,
    [DB_NAME, table, column]
  );
  return Number(row?.c) > 0;
}

/** Ensures columns / indexes expected by the API exist (idempotent). */
export async function ensureSchemaPatches() {
  if (!(await columnExists("jobs", "pay_basis"))) {
    await pool.query(
      `ALTER TABLE jobs
       ADD COLUMN pay_basis ENUM('HOURLY','DAILY','MONTHLY','OTHER','UNSPECIFIED') NOT NULL DEFAULT 'UNSPECIFIED'
       AFTER employment_type`
    );
  }

  if (!(await columnExists("users", "google_sub"))) {
    await pool.query(`ALTER TABLE users ADD COLUMN google_sub VARCHAR(255) NULL`);
  }

  const [[idx]] = await pool.query(
    `SELECT COUNT(*) AS c FROM information_schema.STATISTICS
     WHERE TABLE_SCHEMA = ? AND TABLE_NAME = 'users' AND INDEX_NAME = 'uq_users_google_sub'`,
    [DB_NAME]
  );
  if (Number(idx?.c) === 0) {
    try {
      await pool.query(`CREATE UNIQUE INDEX uq_users_google_sub ON users (google_sub)`);
    } catch (e) {
      if (String(e?.code) !== "ER_DUP_KEYNAME") console.warn("[ensureSchemaPatches] uq_users_google_sub", e);
    }
  }
}
