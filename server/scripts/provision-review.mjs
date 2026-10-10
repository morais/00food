#!/usr/bin/env node
// Node 22.18+. Codes stay in an ignored owner-readable file; D1 stores a hash.
import { randomBytes, randomUUID, createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync, chmodSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { reviewFixtureIds, reviewSeed } from "../src/reviewSeed.ts";

const server = dirname(dirname(fileURLToPath(import.meta.url)));
const flags = process.argv.slice(2);
if (flags.some(flag => !["--local", "--reset"].includes(flag))) throw new Error("Usage: provision-review.mjs [--local] [--reset]");
const local = flags.includes("--local");
const credentialPath = join(server, local ? ".review-access.local.json" : ".review-access.json");
const saved = existsSync(credentialPath) ? JSON.parse(readFileSync(credentialPath, "utf8")) : {
  tenantId: randomUUID(), accessCode: `fd_review_${randomBytes(32).toString("base64url")}`,
  expiresAt: new Date(Date.now() + 365 * 86400000).toISOString(), ids: reviewFixtureIds(),
  seededAt: new Date().toISOString(), provisioned: false,
};
if (!/^[a-f0-9-]{36}$/.test(saved.tenantId) || !/^fd_review_[A-Za-z0-9_-]{43}$/.test(saved.accessCode)
  || !saved.ids || !Object.values(saved.ids).every(id => /^[a-f0-9-]{36}$/.test(id))) throw new Error("Invalid saved reviewer fixture");
if (saved.expiresAt <= new Date().toISOString()) throw new Error("Reviewer code expired; revoke its grants and provision a new fixture");
if (saved.provisioned && !flags.includes("--reset")) {
  chmodSync(credentialPath, 0o600);
  console.log(`Reviewer tenant already provisioned: ${saved.tenantId}`);
  process.exit(0);
}
// Retain the code before the remote write so an interrupted run can retry.
writeFileSync(credentialPath, JSON.stringify(saved, null, 2) + "\n", { mode: 0o600 });
chmodSync(credentialPath, 0o600);
const temporary = mkdtempSync(join(tmpdir(), "00food-review-"));
try {
  const path = join(temporary, "seed.sql");
  writeFileSync(path, reviewSeed(saved.tenantId, createHash("sha256").update(saved.accessCode).digest("hex"),
    saved.expiresAt, saved.ids, new Date(saved.seededAt), flags.includes("--reset")), { mode: 0o600 });
  execFileSync("npx", ["wrangler", "d1", "execute", "00food", local ? "--local" : "--remote", "--file", path], { cwd: server, stdio: "inherit" });
  saved.provisioned = true;
  writeFileSync(credentialPath, JSON.stringify(saved, null, 2) + "\n", { mode: 0o600 });
  console.log(`Reviewer tenant provisioned: ${saved.tenantId}`);
  console.log(`Set REVIEW_TENANT_IDS to this UUID and deploy. Credential saved to ${credentialPath}; secure portal fields only.`);
} finally { rmSync(temporary, { recursive: true, force: true }); }
