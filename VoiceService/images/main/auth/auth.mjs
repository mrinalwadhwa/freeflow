import { betterAuth } from "better-auth";
import { bearer } from "better-auth/plugins";
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

export const auth = betterAuth({
  baseURL: "http://localhost:3456",
  secret,
  database: pool,
  plugins: [bearer()],
});
