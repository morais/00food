# 00Food Worker

Cloudflare Worker, D1, and private R2 photo storage. Node 22+ and Wrangler are needed.

## Setup

Copy `wrangler.toml.sample` to ignored `wrangler.toml`. Set the D1 database ID, public HTTPS origin and custom domain, Apple identifiers, and team/key IDs. Create the D1 database and R2 bucket, then apply migrations before deployment.

```sh
npm ci
npx wrangler whoami
npx wrangler d1 create 00food
npx wrangler r2 bucket create 00food-photos
npx wrangler r2 bucket lifecycle add 00food-photos expire-photos-30-days --expire-days 30
npx wrangler d1 migrations apply 00food --remote
npm run typecheck
npm run deploy
```

Photos are deleted when an estimate is accepted or discarded and when the account is deleted. The lifecycle rule is a backstop: it removes any photo older than 30 days, such as one whose delete failed or one attached to an estimate that was never reviewed. After 30 days such an estimate keeps its description, but its photo is gone.

Install `APPLE_PRIVATE_KEY` and `OAUTH_SIGNING_SECRET` as Wrangler secrets. Never put private key material in `wrangler.toml`, Git, or app code. The Sign in with Apple key must be associated with the app's primary App ID or Apple sign-in group. For MCP web sign-in, register a Services ID with the API host and `https://<API host>/auth/apple/callback` in Apple Developer. `MCP_VERIFIED_CLIENTS` maps exact HTTPS callback addresses to names shown on the consent page. The sample recognizes ChatGPT's stable callback; other callbacks remain marked unverified. The page also shows only the scopes requested by that authorization. An existing food-only connection has no daily or Health access until the daily tools request an upgrade and the user approves it.

For local work, use a separate ignored `wrangler.toml` with `PUBLIC_ORIGIN = "http://localhost:8787"`, `workers_dev = true`, and no custom-domain route. Apply `npx wrangler d1 migrations apply 00food --local`, start `npm run dev`, and run `node scripts/smoke-local.mjs` in another terminal. The smoke test inserts disposable local credentials and checks profile saving, idempotent logging, photo upload, MCP photo retrieval, agent proposal, and user acceptance. Native Apple login needs a deployed HTTPS origin to test end to end.

## Dedicated MCP reviewer access

After migrations, run `node scripts/provision-review.mjs` (Node 22.18+) to seed a
dedicated account with synthetic saved foods, a food log, a pending yogurt-bowl
estimate, and a completed-day request with seven synthetic Health days. It saves
the one-year sign-in code and fixture IDs in ignored `.review-access.json` with
mode 0600; only the SHA-256 code hash goes into D1. Put the printed tenant UUID
in `REVIEW_TENANT_IDS` under `[vars]` in the ignored deployment config and deploy.
`--local` uses a separate local database and `.review-access.local.json`.

Reviewers can select **Reviewer access** alongside Apple in the MCP OAuth flow,
enter the code from the portal's secure reviewer-access field, and approve the
normal food/daily scopes. The code has no app or MCP bearer permissions. It
requires no Apple account, mailbox, phone, or iPhone. The rate-limited callback
requires a valid pending OAuth flow and same-origin form submission; grants still
require explicit consent and PKCE. Keep the code out of Git, ZIPs, and chat.

The same code signs in at `/dashboard/login` to a read-only `/dashboard` showing
only the demo account's saved foods, logs, proposals, and daily reflections.
Sessions are signed, expire in a day, and recheck code expiry, revocation, and
the tenant allowlist on every read. The dashboard cannot approve or log foods.

Run `node scripts/smoke-review.mjs` after deployment to verify the OAuth flow and
all five review workflows, reset the synthetic fixtures, and revoke its temporary
grant. `node scripts/provision-review.mjs --reset` restores only the saved fixture
IDs for another run; dates remain fixed to the original fixture day.
Remove the allowlisted UUID or revoke `review_credentials.revoked_at` to disable
sign-in and dashboard access. Separately revoke issued MCP credentials and their
webhook subscriptions when review ends, since ordinary grants outlive sign-in.

## Silent agent-response pushes

Configure a production APNs topic-specific key restricted to the iPhone bundle ID (`APPLE_APP_CLIENT_ID`). Set `APNS_KEY_ID` in Wrangler variables and install its private key as the `APNS_PRIVATE_KEY` secret. An optional separate development key uses `APNS_DEVELOPMENT_KEY_ID` and `APNS_DEVELOPMENT_PRIVATE_KEY`; without it, development registrations stay disabled. Enable Push Notifications on the iPhone App ID and regenerate its distribution profile. Apply migration `0013_agent_response_push.sql` before deploying the Worker.

Food proposals, clarification replies, and completed daily reviews atomically queue a per-account push outbox. The Durable Object delivers it with retries, coalescing accepted pushes to at most one per device every 20 minutes. Undelivered signals expire after a day. Only enabled devices belonging to an unexpired, unrevoked app credential receive pushes; MCP credentials cannot register devices. Sign-out and account deletion remove registrations. Pushes contain only a refresh signal, with no food or Health data. APNs acceptance does not guarantee iOS background execution; foreground polling remains the fallback.

## Calorie budgets

Maintain (0%), Gentle (10%), Balanced (15%), Faster (20%). Allowance = (Health resting + active energy) × (1 − deficitPercent / 100), rounded to kcal. Exercise is included before applying the deficit. Today uses a full-day estimate from at least 5 of the last 7 completed resting-energy days, falling back to the latest weight/height/sex and reference age 35, plus active energy recorded so far. Completed-day charts use actual resting and active energy where available. Illustrations hold the recent mean of paired completed-day TDEE totals constant; they do not predict adaptive changes.

Migration `0014_percentage_deficits.sql` preserves existing pace selection (0/300/450/600 kcal → 0/10/15/20%) and cached/offline profiles migrate on decode. The API temporarily accepts and returns legacy `deficitKcal` values for installed builds; all new budget calculations use `deficitPercent`. Daily-review context includes the current percentage and each complete Health day's calculated TDEE, allowance and gap; missing energy yields a null budget. No adaptive calibration is implemented yet.

## App API

Daily-review context preserves the capped fruit/veg count and uncapped Health water totals, adds explicit minimum-intake and goal-completion fields, and includes `reviewGuidance` in every response. Completed produce progress means at least five portions; recorded water may omit unlogged drinks. Agents are asked to discuss protein sources and diet balance qualitatively from food descriptions, without inventing nutrient totals. This guidance also reaches existing clients with cached tool descriptions. Previously saved reviews remain unchanged.

App routes use `Authorization: Bearer <app token>`:

| Route | Purpose |
| --- | --- |
| `POST /v1/auth/apple` | Exchange a native Apple sign-in for an app session |
| `GET /v1/snapshot` | Account creation date, profile, reusable foods, recent logs, and pending estimates |
| `PUT /v1/push/device` | Register this app installation for silent agent-response pushes |
| `PUT /v1/profile` | Height, weight, estimate setting, deficit percentage (`deficitPercent`: 0, 10, 15 or 20), optional legacy birth year |
| `POST /v1/foods` | Save a reusable food |
| `POST /v1/foods/:id/dismiss` | Hide a food from the frequent list until it is logged again |
| `POST /v1/logs` | Log a serving, using a client UUID for retry safety |
| `DELETE /v1/logs/:id` | Remove a log |
| `POST /v1/estimations` | Submit a new food description and optional JPEG together as `multipart/form-data` (`id`, `description`, `localDate`, `photo`), creating one pending-food ID; JSON with base64 `photoBase64` is still accepted from older builds |
| `PUT /v1/estimations/:id/photo` | Add a private JPEG photo (up to 2 MB) to the same pending food |
| `PUT /v1/estimations/:id/proposal` | Edit an agent proposal during review |
| `POST /v1/estimations/:id/accept` | Save the proposed food and log it |
| `POST /v1/estimations/:id/clarifications` | Send an idempotent user clarification and return the item to the agent queue |
| `DELETE /v1/estimations/:id` | Discard a pending estimate and its photo |
| `GET /v1/daily-feedback` | List recent pending and completed daily reviews |
| `POST /v1/daily-feedback` | Queue one completed day with up to seven days of Health aggregates; idempotent by account and local day |
| `GET /v1/account/mcp-connections` | List connected agents and their active webhook event names (`activeEvents`), excluding expired subscriptions |
| `DELETE /v1/account/mcp-connections/:id` | Revoke an agent |
| `POST /v1/auth/delete-account` | Reauthenticate and remove account data |

`POST /mcp` supports `list_pending_foods`, `get_pending_food`, `view_food_photo`, `propose_food_estimate`, `list_known_foods`, and `list_food_events`. An agent uses one pending-food ID to read the description and inspect its photo together before proposing an estimate with a visible calorie rationale. The current iOS app sends both in one atomic submission; the separate photo upload route remains available for older clients. The remote MCP connection uses OAuth authorization code with PKCE and Apple web sign-in. The consent page explicitly says that a connected agent can inspect pending photos. The agent's proposal does not create a food or log until the app user accepts it.

There is no server-to-client SSE stream: `GET /mcp` returns 405, which Streamable HTTP clients treat as "request/response only". Automatic responses use MCP Events webhooks (below); any agent can catch up by calling `list_food_events` (or `resources/read` on `food://events`) with its last `after` cursor. The D1 event journal is kept for 30 days. The per-account `FoodEventStream` Durable Object only sends queued webhook deliveries from its alarm, so it runs briefly per event and never holds a connection open.

ChatGPT Work uses MCP 2.0 webhook events. `server/discover` advertises event support, and `events/list` exposes `food.logged`, `food.estimate_requested`, `food.clarification_added`, and `day.feedback_requested`. The authenticated `events/subscribe` verifies a signed ChatGPT callback before storing it. Matching events are signed with Standard Webhooks, delivered through a durable outbox with retries, and stopped by `events/unsubscribe`, token revocation, or expiry. ChatGPT callback URLs must use HTTPS on a ChatGPT or OpenAI host. Connect or rescan the server as a ChatGPT plugin, then subscribe from a Work chat and tell ChatGPT how to handle each event. For daily reviews, enable automatic Daily feedback or request missing days manually in the app. Rescan the MCP server and call `list_pending_daily_feedback`; its tool metadata declares `daily:read` and prompts a scope upgrade when the existing connection has only food access. Approve `daily:read` and `daily:write` for reading the seven-day context and saving the review, then subscribe to `day.feedback_requested`. The agent can call `get_daily_feedback_request` for the selected day and its seven-day food and Health context, then `submit_daily_feedback` to show the review in the app. The 2025 resource stream remains available for other MCP clients.
