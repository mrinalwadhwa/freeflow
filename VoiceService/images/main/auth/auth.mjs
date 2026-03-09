import { betterAuth } from "better-auth";
import { bearer } from "better-auth/plugins";
import { emailOTP } from "better-auth/plugins";
import { createHash, createDecipheriv } from "node:crypto";
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

// Decrypt an api_key stored in email_config. The key is encrypted with
// AES-256-CBC using BETTER_AUTH_SECRET as the passphrase. The stored
// format is "iv_hex:encrypted_hex". If the value does not contain a
// colon it is treated as plaintext (backward compat / initial setup).
function decryptApiKey(stored) {
  if (!stored || !stored.includes(":")) {
    return stored;
  }
  try {
    const [ivHex, encHex] = stored.split(":");
    const key = createHash("sha256").update(secret).digest();
    const iv = Buffer.from(ivHex, "hex");
    const decipher = createDecipheriv("aes-256-cbc", key, iv);
    let decrypted = decipher.update(encHex, "hex", "utf8");
    decrypted += decipher.final("utf8");
    return decrypted;
  } catch {
    // If decryption fails, return as-is (may be plaintext).
    return stored;
  }
}

// Read email configuration from the zone database. Returns null if
// no config exists or if the provider is not configured.
async function getEmailConfig() {
  try {
    const result = await pool.query(
      "SELECT provider, api_key, from_address, verified FROM email_config ORDER BY id LIMIT 1",
    );
    if (result.rows.length === 0) {
      return null;
    }
    const row = result.rows[0];
    if (!row.provider || !row.api_key || !row.from_address) {
      return null;
    }
    return {
      provider: row.provider,
      apiKey: decryptApiKey(row.api_key),
      fromAddress: row.from_address,
      verified: row.verified,
    };
  } catch (err) {
    console.error("[auth] Failed to read email_config:", err.message);
    return null;
  }
}

// Send an email via the configured provider's REST API.
async function sendEmail({ to, subject, text, html, config }) {
  const { provider, apiKey, fromAddress } = config;

  if (provider === "resend") {
    const resp = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${apiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        from: fromAddress,
        to: [to],
        subject,
        text,
        html,
      }),
    });
    if (!resp.ok) {
      const body = await resp.text();
      throw new Error(`Resend API error ${resp.status}: ${body}`);
    }
    return;
  }

  if (provider === "sendgrid") {
    const resp = await fetch("https://api.sendgrid.com/v3/mail/send", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${apiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        personalizations: [{ to: [{ email: to }] }],
        from: { email: fromAddress },
        subject,
        content: [
          ...(text ? [{ type: "text/plain", value: text }] : []),
          ...(html ? [{ type: "text/html", value: html }] : []),
        ],
      }),
    });
    if (!resp.ok) {
      const body = await resp.text();
      throw new Error(`SendGrid API error ${resp.status}: ${body}`);
    }
    return;
  }

  throw new Error(`Unsupported email provider: ${provider}`);
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
    changeEmail: {
      enabled: true,
    },
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
  plugins: [
    bearer(),
    emailOTP({
      disableSignUp: true,
      otpLength: 6,
      expiresIn: 600, // 10 minutes
      async sendVerificationOTP({ email, otp, type }) {
        const config = await getEmailConfig();
        if (!config) {
          console.error(`[auth] Cannot send OTP to ${email}: email not configured`);
          throw new Error("Email is not configured. Ask your admin to set up an email provider.");
        }

        const appName = "Voice";
        let subject;
        let text;
        let html;

        if (type === "sign-in") {
          subject = `Your ${appName} sign-in code`;
          text = `Your sign-in code is: ${otp}\n\nThis code expires in 10 minutes. If you did not request this, you can ignore this email.`;
          html = `<p>Your sign-in code is:</p><p style="font-size:32px;font-weight:bold;letter-spacing:4px;margin:24px 0">${otp}</p><p style="color:#6e6e73;font-size:14px">This code expires in 10 minutes. If you did not request this, you can ignore this email.</p>`;
        } else if (type === "email-verification") {
          subject = `Verify your email for ${appName}`;
          text = `Your verification code is: ${otp}\n\nThis code expires in 10 minutes.`;
          html = `<p>Your verification code is:</p><p style="font-size:32px;font-weight:bold;letter-spacing:4px;margin:24px 0">${otp}</p><p style="color:#6e6e73;font-size:14px">This code expires in 10 minutes.</p>`;
        } else {
          subject = `Your ${appName} code`;
          text = `Your code is: ${otp}\n\nThis code expires in 10 minutes.`;
          html = `<p>Your code is:</p><p style="font-size:32px;font-weight:bold;letter-spacing:4px;margin:24px 0">${otp}</p><p style="color:#6e6e73;font-size:14px">This code expires in 10 minutes.</p>`;
        }

        try {
          await sendEmail({ to: email, subject, text, html, config });
          console.log(`[auth] Sent ${type} OTP to ${email} via ${config.provider}`);
        } catch (err) {
          console.error(`[auth] Failed to send ${type} OTP to ${email}:`, err.message);
          throw err;
        }
      },
    }),
  ],
});
