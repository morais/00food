# 00Food Worker

Cloudflare Worker, D1, and private R2 photo storage. Node 22+ and Wrangler are needed.

## Setup

Copy `wrangler.toml.sample` to ignored `wrangler.toml`. Set the D1 database ID, public HTTPS origin and custom domain, Apple identifiers, and team/key IDs. Create the D1 database and R2 bucket, then apply migrations before deployment.

```sh
npm ci
npx wrangler whoami
npx wrangler d1 create 00food
npx wrangler r2 bucket create 00food-photos
npx wrangler d1 migrations apply 00food --remote
npm run typecheck
npm run deploy
```

Install `APPLE_PRIVATE_KEY` and `OAUTH_SIGNING_SECRET` as Wrangler secrets. Never put private key material in `wrangler.toml`, Git, or app code. The Sign in with Apple key must be associated with the app's primary App ID or Apple sign-in group. For MCP web sign-in, register a Services ID with the API host and `https://<API host>/auth/apple/callback` in Apple Developer. `MCP_VERIFIED_CLIENTS` maps exact HTTPS callback addresses to names shown on the consent page. The sample recognizes ChatGPT's stable callback; other callbacks remain marked unverified. The page also shows only the scopes requested by that authorization. An existing food-only connection has no daily or Health access until the daily tools request an upgrade and the user approves it.

For local work, use a separate ignored `wrangler.toml` with `PUBLIC_ORIGIN = "http://localhost:8787"`, `workers_dev = true`, and no custom-domain route. Apply `npx wrangler d1 migrations apply 00food --local`, start `npm run dev`, and run `node scripts/smoke-local.mjs` in another terminal. The smoke test inserts disposable local credentials and checks profile saving, idempotent logging, photo upload, MCP photo retrieval, agent proposal, and user acceptance. Native Apple login needs a deployed HTTPS origin to test end to end.

## API

App routes use `Authorization: Bearer <app token>`:

| Route | Purpose |
| --- | --- |
| `POST /v1/auth/apple` | Exchange a native Apple sign-in for an app session |
| `GET /v1/snapshot` | Account creation date, profile, reusable foods, recent logs, and pending estimates |
| `PUT /v1/profile` | Height, weight, estimate setting, weight-loss adjustment, optional birth year |
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

For live updates on the 2025-11-25 MCP connection, the agent calls `resources/subscribe` with `{"uri":"food://events"}` and opens an authenticated `GET /mcp` stream with `Accept: text/event-stream`. New food logs, estimate requests, and user clarifications send `notifications/resources/updated` for that URI. The agent then calls `resources/read` or `list_food_events` with its last `after` cursor to catch up. The D1 event journal is kept for 30 days; the stream reconnects every 15 minutes to recheck authorization. MCP hosts need to support resource subscriptions and choose to act on notifications for autonomous processing.

ChatGPT Work uses MCP 2.0 webhook events. `server/discover` advertises event support, and `events/list` exposes `food.logged`, `food.estimate_requested`, `food.clarification_added`, and `day.feedback_requested`. The authenticated `events/subscribe` verifies a signed ChatGPT callback before storing it. Matching events are signed with Standard Webhooks, delivered through a durable outbox with retries, and stopped by `events/unsubscribe`, token revocation, or expiry. ChatGPT callback URLs must use HTTPS on a ChatGPT or OpenAI host. Connect or rescan the server as a ChatGPT plugin, then subscribe from a Work chat and tell ChatGPT how to handle each event. For daily reviews, enable automatic Daily feedback or request missing days manually in the app. Rescan the MCP server and call `list_pending_daily_feedback`; its tool metadata declares `daily:read` and prompts a scope upgrade when the existing connection has only food access. Approve `daily:read` and `daily:write` for reading the seven-day context and saving the review, then subscribe to `day.feedback_requested`. The agent can call `get_daily_feedback_request` for the selected day and its seven-day food and Health context, then `submit_daily_feedback` to show the review in the app. The 2025 resource stream remains available for other MCP clients.
