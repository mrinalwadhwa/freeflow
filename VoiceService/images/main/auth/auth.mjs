import { betterAuth } from "better-auth";
import { bearer } from "better-auth/plugins";
import { createHash } from "node:crypto";
import pg from "pg";

const { Pool } = pg;

const secret = process.env.BETTER_AUTH_SECRET;
if (!secret) {
  throw new Error("BETTER_AUTH_SECRET environment variable is required.");
}

const instance = process.env.OCKAM_DATABASE_INSTANCE;
const user = process.env.OCKAM_DATABASE_USER;
const password = process.env.OCKAM_DATABASE_PASSWORD;

if (!instance || !user || !password) {
  throw new Error(
    "Database not configured. Set OCKAM_DATABASE_INSTANCE, " + "OCKAM_DATABASE_USER, and OCKAM_DATABASE_PASSWORD.",
  );
}

const pool = new Pool({
  connectionString: `postgresql://${user}:${encodeURIComponent(password)}@${instance}`,
});

// Use SHA-256 instead of scrypt for password hashing. Passwords in this
// system are throwaway: invite redemption generates a random hex string
// to satisfy better-auth's sign-up API, but no user ever sees or types
// a password. Auth is via session tokens from invite redemption (Tier 1)
// or email OTP (Tier 2). The default @noble/hashes scrypt triggers a
// V8 SIGSEGV on x86_64 containers due to its large memory allocations.
async function hashPassword(pwd) {
  return createHash("sha256").update(pwd).digest("hex");
}

async function verifyPassword({ hash, password: pwd }) {
  return hash === createHash("sha256").update(pwd).digest("hex");
}

export const auth = betterAuth({
  baseURL: "http://localhost:3456",
  secret,
  database: pool,
  emailAndPassword: {
    enabled: true,
    password: {
      hash: hashPassword,
      verify: verifyPassword,
    },
  },
  user: {
    modelName: "auth_user",
  },
  session: {
    modelName: "auth_session",
  },
  account: {
    modelName: "auth_account",
  },
  verification: {
    modelName: "auth_verification",
  },
  plugins: [bearer()],
});
