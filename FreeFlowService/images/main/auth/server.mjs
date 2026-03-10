import { Hono } from "hono";
import { serve } from "@hono/node-server";
import { getMigrations } from "better-auth/db/migration";
import { auth } from "./auth.mjs";

const app = new Hono();

// Health endpoint for startup probes and liveness checks.
app.get("/api/auth/ok", (c) => c.json({ status: "ok" }));

// Mount better-auth handler for all auth routes.
app.on(["POST", "GET"], "/api/auth/*", (c) => auth.handler(c.req.raw));

async function start() {
  // Run database migrations before accepting traffic. better-auth's
  // programmatic migration inspects the current schema and applies
  // any missing tables or columns for its core tables (user, session,
  // account, verification) and any plugin tables.
  try {
    const { toBeCreated, toBeAdded, runMigrations } = await getMigrations(auth.options);

    if (toBeCreated.length > 0 || toBeAdded.length > 0) {
      if (toBeCreated.length > 0) {
        console.log(`[auth] Creating tables: ${toBeCreated.map((t) => t.table).join(", ")}`);
      }
      if (toBeAdded.length > 0) {
        console.log(`[auth] Adding columns: ${toBeAdded.map((a) => `${a.table}.${a.columns?.join(", ")}`).join("; ")}`);
      }
      await runMigrations();
      console.log("[auth] Migrations complete.");
    } else {
      console.log("[auth] Database schema is up to date.");
    }
  } catch (err) {
    console.error("[auth] Migration failed:", err);
    process.exit(1);
  }

  serve({ fetch: app.fetch, port: 3456 }, (info) => {
    console.log(`[auth] Listening on port ${info.port}`);
  });
}

start();
