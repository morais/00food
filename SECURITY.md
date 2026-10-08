# Security policy

## Reporting a vulnerability

Please report security issues **privately**, not through public GitHub issues.

Use GitHub's [private vulnerability
reporting](https://github.com/morais/00food/security/advisories/new) — the
"Report a vulnerability" button under this repository's **Security** tab. It
opens a private advisory only you and the maintainers can see.

Please include:

- A description of the issue and its impact
- Steps to reproduce (or a proof-of-concept)
- The affected component (`server/`, `ios/`, or specific files)
- Whether you'd like to be credited in the fix announcement

You'll get an acknowledgement within 3 working days. We aim to ship a fix or
mitigation within 30 days for high-severity issues; coordinated disclosure
timelines are negotiable.

## Scope

In scope:

- The Cloudflare Worker under `server/` (REST API, MCP endpoint and webhook
  events, OAuth authorization server, Sign in with Apple, tenant isolation,
  private photo storage)
- The iOS app and widget under `ios/` (Keychain handling, App Group storage,
  offline queue, Apple Health data handling)

Out of scope:

- Noisy or destructive probes against the hosted deployment at
  `api.00food.com`. Bugs in the code apply equally to a local Worker.
- Bugs in upstream dependencies (zod, Wrangler, Cloudflare Workers, Apple
  frameworks). Report those upstream.
- Issues that require physical access to an unlocked device, or a malicious
  profile or sideloaded build.

## Defensive properties this project tries to maintain

If you find a way to break any of these, please report it:

1. **Tenant isolation.** Every food, log, estimate, photo, and daily-feedback
   query is scoped by `tenant_id`, and account deletion cascades to all of
   them.
2. **Credential opacity.** App and MCP credentials are stored only as SHA-256
   hashes. App credentials cannot call MCP, and MCP credentials cannot call
   REST.
3. **Scoped agent access.** MCP tools require `food:*` or `daily:*` scopes.
   A food-only connection cannot read Health aggregates until the user
   approves a scope upgrade. Agents can propose estimates but cannot log food.
4. **Apple identity validation.** Sign-in verifies the identity token's RS256
   signature against Apple's keys, its issuer, audience, lifetime, and nonce,
   then exchanges the one-time code with Apple and requires the same subject.
5. **OAuth for MCP.** Authorization codes require S256 PKCE, are bound to the
   client, redirect URI, and resource, and are redeemable exactly once. The
   consent page is protected by a per-flow secret cookie and form token.
6. **Webhook delivery.** Event subscriptions accept only HTTPS callbacks on
   ChatGPT or OpenAI hosts, and deliveries are signed with Standard Webhooks.
7. **Bounded inputs.** Every endpoint caps request bodies and validates field
   lengths; photos are limited to 2 MB.

## Things that look bad but aren't

- `wrangler.toml.sample` and `project.yml.sample` contain placeholders such as
  `REPLACE_WITH_D1_DATABASE_ID` and `com.example` identifiers. The real
  `wrangler.toml` and `project.yml` are gitignored.
- `server/scripts/smoke-local.mjs` inserts disposable credentials into a local
  D1 database only.
- The screenshot demo under `ios/ScreenshotDemo` uses fictional foods and
  measurements, not anyone's data.
