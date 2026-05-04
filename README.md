## Kenyalang Careers Backend (MySQL + REST)

This backend is for **local development** and provides a safe architecture:

**Flutter app → REST API → MySQL**

### Prereqs
- Node.js (LTS)
- Docker Desktop (recommended for MySQL)

### Start MySQL (Docker)
From repo root:

```powershell
docker compose up -d
```

### Run API
```powershell
cd backend
npm install
npm run dev
```

API runs at `https://kenyalang-careers-backend.onrender.com`.

Environment variables are read from **`backend/.env`** (via [dotenv](https://github.com/motdotla/dotenv)) and from the shell. Copy **`.env.example`** to **`.env`** and set values there; **`.env` is gitignored** so local secrets are not committed.

### Google Sign-In (optional)
`POST /auth/google` accepts a Google **ID token** from the Flutter app (`google_sign_in`), verifies it with Google, then signs the user in or creates a **SEEKER** account.

Set at least the **Web** OAuth client ID in **`backend/.env`** (must match the Web client ID in the Flutter app):

```env
GOOGLE_OAUTH_WEB_CLIENT_ID=123456789-xxxx.apps.googleusercontent.com
# Optional:
# GOOGLE_OAUTH_ANDROID_CLIENT_ID=...
# GOOGLE_OAUTH_IOS_CLIENT_ID=...
```

Or set the same variables in your shell before `npm run dev`.

Create OAuth clients in [Google Cloud Console](https://console.cloud.google.com/apis/credentials) (Web application + Android/iOS if you use those platforms). For a new MySQL volume, `users.google_sub` is included in `001_init.sql`; existing DBs get the column when the API starts (`ensureSchemaPatches`) or run `backend/sql/009_google_sub.sql`.

### AI job descriptions (optional)
Employers can call `POST /ai/job-description`. If **`OPENAI_API_KEY`** is set, the server uses the OpenAI Chat Completions API (`OPENAI_MODEL` defaults to `gpt-4o-mini`). If the key is missing or the call fails, a **local template** is returned so the app still works.

```powershell
set OPENAI_API_KEY=sk-...
set OPENAI_MODEL=gpt-4o-mini
npm run dev
```

### DB migrations (existing database)
New columns are added under `backend/sql/`. If your MySQL volume already existed before a change, run the matching `ALTER` (e.g. `003_employment_type.sql`) or apply it with:

```powershell
docker exec -i kenyalang_mysql mysql -ukenyalang -pkenyalang kenyalang_careers < backend/sql/003_employment_type.sql
```

