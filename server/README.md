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

Install `APPLE_PRIVATE_KEY` and `OAUTH_SIGNING_SECRET` as Wrangler secrets. Never put private key material in `wrangler.toml`, Git, or app code. The Sign in with Apple key must be associated with the app's primary App ID or Apple sign-in group. For MCP web sign-in, register a Services ID with the API host and `https://<API host>/auth/apple/callback` in Apple Developer.

For local work, use a separate ignored `wrangler.toml` with `PUBLIC_ORIGIN = "http://localhost:8787"`, `workers_dev = true`, and no custom-domain route. Apply `npx wrangler d1 migrations apply 00food --local`, start `npm run dev`, and run `node scripts/smoke-local.mjs` in another terminal. The smoke test inserts disposable local credentials and checks profile saving, idempotent logging, photo upload, MCP photo retrieval, agent proposal, and user acceptance. Native Apple login needs a deployed HTTPS origin to test end to end.

## API

App routes use `Authorization: Bearer <app token>`:

| Route | Purpose |
| --- | --- |
| `POST /v1/auth/apple` | Exchange a native Apple sign-in for an app session |
| `GET /v1/snapshot` | Account creation date, profile, reusable foods, recent logs, and pending estimates |
| `PUT /v1/profile` | Height, weight, estimate setting, weight-loss adjustment |
| `POST /v1/foods` | Save a reusable food |
| `POST /v1/logs` | Log a serving, using a client UUID for retry safety |
| `DELETE /v1/logs/:id` | Remove a log |
| `POST /v1/estimations` | Submit a new food description and optional base64 JPEG together, creating one pending-food ID |
| `PUT /v1/estimations/:id/photo` | Add a private JPEG photo (up to 2 MB) to the same pending food |
| `PUT /v1/estimations/:id/proposal` | Edit an agent proposal during review |
| `POST /v1/estimations/:id/accept` | Save the proposed food and log it |
| `DELETE /v1/estimations/:id` | Discard a pending estimate and its photo |
| `GET /v1/account/mcp-connections` | List connected agents |
| `DELETE /v1/account/mcp-connections/:id` | Revoke an agent |
| `POST /v1/auth/delete-account` | Reauthenticate and remove account data |

`POST /mcp` supports `list_pending_foods`, `get_pending_food`, `view_food_photo`, `propose_food_estimate`, and `list_known_foods`. An agent uses one pending-food ID to read the description and inspect its photo together before proposing an estimate. The current iOS app sends both in one atomic submission; the separate photo upload route remains available for older clients. The remote MCP connection uses OAuth authorization code with PKCE and Apple web sign-in. The consent page explicitly says that a connected agent can inspect pending photos. The agent's proposal does not create a food or log until the app user accepts it.
