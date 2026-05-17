# apollo-backend (self-hosting fork)

A self-hostable fork of [`christianselig/apollo-backend`](https://github.com/christianselig/apollo-backend), the archived Go service that powered push notifications, inbox checks, and subreddit/user watchers for the original [Apollo for Reddit](https://apolloapp.io/) iOS app.

This fork is meant to be run together with **[JeffreyCA/Apollo-ImprovedCustomApi](https://github.com/JeffreyCA/Apollo-ImprovedCustomApi)** — the iOS tweak that lets sideloaded Apollo builds use the user's own Reddit OAuth credentials. The tweak's **Settings > Custom API > Notification Backend** URL field points at an instance of this fork; with that wired up, push notifications and watchers come back to life for sideloads that have a real APNs entitlement.

Single-tenant by design: one deployment serves one sideloaded Apollo build (one bundle ID, one Apple Developer team), and can be shared with a small group of friends running the same build.

## Before you start

Three hard prerequisites — none of these are negotiable, and skipping any of them produces failure modes that look like backend bugs but aren't:

1. **A paid Apple Developer account.** APNs delivery requires the `aps-environment` entitlement, which Apple only grants under a paid team ($99/yr). Free-account sideloads can register devices and exercise every endpoint, but the pushes never arrive.
2. **A custom bundle ID — *not* `com.christianselig.Apollo`.** Reddit's edge WAF has the original Apollo bundle ID on its blocklist; any request whose `User-Agent` contains that string gets a 403 HTML "blocked by network security" response from `oauth.reddit.com` and the token endpoint. Re-sign your sideloaded build under your own bundle ID (e.g. `com.you.Leto`) and use that everywhere — `APPLE_APNS_TOPIC`, the App ID's Push entitlement, the tweak's User Agent.
3. **An explicit App ID with Push Notifications enabled** at developer.apple.com — not Sideloadly's wildcard. Push capability isn't enabled on wildcard provisioning profiles, so the entitlement is silently absent and Apple drops every notification.

## What changed from upstream

The upstream backend was deeply tied to Christian's App Store deployment. This fork strips or reworks every assumption that depended on it.

- **Stripped entirely**: App Store IAP / Apollo Ultra receipt validation (the `internal/itunes/` package and its device-deletion side effect on receipt failure), Live Activities, the `/v1/contact` endpoint, Bugsnag, Heroku's hmetrics auto-emitter, and `render.yaml`.
- **APNs topic configurable** via `APPLE_APNS_TOPIC` — formerly hardcoded.
- **APNs gateway configurable** via `APPLE_APNS_SANDBOX`. Apollo's release-signed binary always sent `sandbox=false` (it was App Store production); sideloaded builds signed under a dev cert need sandbox APNs, and pinning this per deployment avoids `BadDeviceToken` errors and the worker's aggressive auto-delete on receipt of one. The notifications worker now picks its APNs gateway from `device.Sandbox` per-device, rather than the now-vestigial `account.Development` flag.
- **Reddit OAuth credentials are per-account**, stored on `accounts.reddit_client_id` / `reddit_client_secret` / `reddit_redirect_uri` / `reddit_user_agent`. Installed-app credentials (empty `client_secret`) are accepted. If the tweak doesn't manage to inject them on a given registration (it can't reach bodies attached to upload-tasks), the API falls back to `REDDIT_CLIENT_ID` / `REDDIT_CLIENT_SECRET` / `REDDIT_REDIRECT_URI` / `REDDIT_USER_AGENT` env vars on the API process.
- **CamelCase registration payloads accepted.** Apollo's iOS client posts `accessToken` / `refreshToken`, not the snake_case shape upstream documented. The handler accepts both.
- **Registration endpoints gated** by the optional `REGISTRATION_SECRET` env var.
- **StatsD is optional** — a `NoOpClient` is wired in when `STATSD_URL` is unset (formerly crashed at startup).
- **Diagnostic stubs for Apollo's three legacy hosts**: `/api/req_v2`, `/api/announcement`, `/v1/receipt[/{apns}]`. Returns permissive responses so the tweak's host-rewrite doesn't strand the client on dead endpoints. The receipt stub hardcodes Pro + Ultra as owned.
- **JWT-format access tokens supported.** Token columns widened from `varchar(64)` to `text` — Reddit switched to JWTs (~1100 chars) sometime after the original backend was archived.
- **Reddit edge WAF workarounds.** `Content-Type: application/x-www-form-urlencoded` is now set explicitly on the OAuth token POST (Go's `http.NewRequest` doesn't auto-set it), and `?raw_json=1` is scoped to `oauth.reddit.com/*` calls only (it triggers a 403 HTML block when sent to `www.reddit.com/api/v1/access_token`).
- **Dockerized** — `Dockerfile` + `docker-compose.yml` replace the original Render-specific deployment.

The result: the backend boots end-to-end with only Postgres, Redis, an APNs auth key, and a bundle ID. Everything else is opt-in.

## Quickstart with Docker

Requires Docker + an APNs auth key (`.p8`) from a paid Apple Developer account.

```bash
git clone https://github.com/<you>/apollo-backend
cd apollo-backend

# 1. Drop your APNs key
mkdir -p secrets
cp ~/Downloads/AuthKey_XXXXXXXXXX.p8 secrets/apple.p8

# 2. Configure environment
cp .env.docker.example .env.docker
$EDITOR .env.docker   # fill in APPLE_KEY_ID, APPLE_TEAM_ID, APPLE_APNS_TOPIC,
                      # APPLE_APNS_SANDBOX, REDDIT_* fallbacks, REGISTRATION_SECRET

# 3. Bring it up
make docker-up
make docker-logs      # follow output until health check passes
```

Verify the API is reachable:

```bash
curl http://localhost:4000/v1/health
# {"status":"available"}
```

You should now be able to point the tweak at `http://<your-host>:4000` (or your reverse-proxied HTTPS URL) and hit **Test Connection**.

## Required environment variables

| Var | Purpose |
|---|---|
| `DATABASE_CONNECTION_POOL_URL` | Postgres URL (via PgBouncer in transaction mode). **No query string** — `cmdutil.NewDatabasePool` appends `?pool_max_conns=…` and a second `?` makes pgx reject the URL. |
| `REDIS_QUEUE_URL` | Redis backing rmq job queues. Configure `noeviction`. |
| `REDIS_LOCKS_URL` | Redis backing the dedup locks (Lua script in `scheduler.go`). Can be the same instance as the queue Redis. |
| `APPLE_KEY_PATH` | Path to your APNs auth key `.p8` file. |
| `APPLE_KEY_ID` | APNs key ID from developer.apple.com. |
| `APPLE_TEAM_ID` | Your Apple Developer team ID. |
| `APPLE_APNS_TOPIC` | Bundle ID of the sideloaded Apollo build (e.g. `com.you.Leto`). Used as `apns-topic` on every push. Crashes at startup if unset. **Must not be `com.christianselig.Apollo`** — see [Before you start](#before-you-start). |

## Optional environment variables

| Var | Default | Effect |
|---|---|---|
| `APPLE_APNS_SANDBOX` | unset | Set to `true` to override Apollo's `sandbox=false` registrations and route pushes through `api.sandbox.push.apple.com`. Required for sideloaded builds signed under a dev cert. |
| `REDDIT_CLIENT_ID`, `REDDIT_CLIENT_SECRET`, `REDDIT_REDIRECT_URI`, `REDDIT_USER_AGENT` | unset | Fallback OAuth credentials used when the tweak fails to inject them per-account at registration time. Single-tenant deployments can set these and skip per-account configuration entirely. |
| `REGISTRATION_SECRET` | unset | If set, registration endpoints require `X-Registration-Token: <value>`. Off by default for local/private-network use. |
| `STATSD_URL` | unset | If set, emits metrics to the given UDP endpoint. If unset, all metrics no-op. |
| `ENV` | `development` | Tags logs and (when present) the statsd `env:` tag. |
| `PORT` | `4000` | API HTTP port. |
| `HONEYCOMB_API_KEY` / `OTEL_*` | unset | OpenTelemetry tracing via Honeycomb's launcher; no-op when unset. |

> [!TIP]
> Quiet the OTLP exporter's reconnect spam in local dev by exporting `OTEL_TRACES_EXPORTER=none` and `OTEL_METRICS_EXPORTER=none`.

## Pointing the tweak at your instance

In the tweak (Apollo on-device): **Settings > Custom API > Notification Backend**.

| Tweak field | Value |
|---|---|
| **Backend URL** | `https://your-backend.example.com` (or `http://10.0.0.5:4000` for LAN). Leave empty to keep notifications silently dropped. |
| **Registration Token** | Same value as your backend's `REGISTRATION_SECRET`. Leave empty if you didn't set one. |

Tap **Test Connection** to verify the tweak can reach `GET /v1/health`.

Make sure the **Reddit API Key**, **Redirect URI**, and **User Agent** in the tweak's main Custom API screen are filled in for the bundle ID you signed with — Reddit's API rules want a UA shaped like `ios:com.you.Leto:v1.0 (by /u/yourname)`. The tweak attempts to inject these into registration bodies; if injection fails, the backend falls back to the matching `REDDIT_*` env vars (see above). Either path works.

Installed-app Reddit credentials are accepted — just leave the **Reddit API Secret** field blank in the tweak.

What the tweak does once the URL is set: it intercepts any request Apollo makes to the three dead legacy hosts (`apollopushserver.xyz`, `beta.apollonotifications.com`, `apolloreq.com`) and rewrites the scheme/host/port to your backend. The receipt-bypass module also intercepts Apollo's StoreKit receipt read so the per-account inbox-notifications toggle works on sideloaded builds (which have no App Store receipt). Everything else (path, query, method, other headers, payload) passes through unchanged.

## Verifying end-to-end

After the toggle, walk through this checklist:

```bash
# 1. Device row created with sandbox=true
docker compose exec postgres psql -U apollo -d apollo -c \
  "SELECT id, sandbox, apns_token FROM devices ORDER BY id DESC LIMIT 1;"

# 2. Account registered, associated with device, inbox_notifiable=true
docker compose exec postgres psql -U apollo -d apollo -c "
  SELECT a.username, a.check_count, a.last_message_id, da.inbox_notifiable
  FROM accounts a
  JOIN devices_accounts da ON da.account_id = a.id;"

# 3. Test push delivered
curl -X POST http://localhost:4000/v1/device/<apns-token>/test/post_reply
# Expect: 200 and a push on the phone.
```

The first inbox message after registration won't trigger a notification — the worker's warmup logic at `internal/worker/notifications.go:274` silently sets `last_message_id` and `check_count=1` on the first poll. The second message and onward push normally. If you want to skip warmup, run:

```bash
docker compose exec postgres psql -U apollo -d apollo -c \
  "UPDATE accounts SET check_count = 1 WHERE username = '<yours>';"
```

## Architecture

Three cobra subcommands of the single `apollo` binary, each typically run as its own container:

- `apollo api` — Gorilla mux HTTP server. Routes in `internal/api/api.go`. Device + account registration, notification preference toggles, watcher CRUD, test pushes.
- `apollo scheduler` — single-instance ticker. Every 5s claims-and-reschedules due accounts/subreddits/users with `UPDATE … SET next_check_at = $next WHERE id IN (SELECT … FOR UPDATE SKIP LOCKED LIMIT N) RETURNING id` and publishes the IDs onto rmq queues.
- `apollo worker --queue <name> --consumers <n>` — consumes one rmq queue. Queue names: `notifications`, `stuck-notifications`, `subreddits`, `trending`, `users`.

Two Redis instances on purpose: one for rmq queues (`noeviction`), one for short-lived `SET key NX EX` dedup locks consulted by a Lua script the scheduler loads at startup.

Every process serves pprof on `localhost:6060`; the scheduler also serves `:8080` for health.

More detail: [`CLAUDE.md`](CLAUDE.md).

## Database

Schema lives in `migrations/` (`golang-migrate`). The consolidated authoritative schema is [`docs/schema.sql`](docs/schema.sql); the docker-compose `migrate` service loads that file rather than walking the step migrations (000006 and 000008 both create the same index, so a clean `migrate up` fails).

To run repository tests against a real Postgres locally:

```bash
make test-setup    # runs migrations against $DATABASE_URL
make test
```

Tests that need Postgres skip themselves when `DATABASE_URL` is unset.

## Development

```bash
make build         # ./apollo binary
make test          # go test -race -timeout 1s ./...
make lint          # golangci-lint
```

## Troubleshooting

Non-obvious failure modes encountered while bringing this up end-to-end:

| Symptom | Cause | Fix |
|---|---|---|
| `403 "blocked by network security"` HTML on every Reddit call | UA contains `com.christianselig.Apollo` | Re-sign with your own bundle ID |
| `403 "blocked by network security"` on `/api/v1/access_token` only | `?raw_json=1` triggers Fastly WAF on the token endpoint | Already fixed in this fork |
| `failed to refresh tokens: Post …: EOF` from Go's stdlib | Reddit also rejects Go's TLS fingerprint *if* the request shape is wrong. Almost always a downstream symptom of the bundle ID or raw_json issues, not a real TLS-layer block. | Fix the real cause; don't go down the utls / tls-client / curl-shellout rabbit hole. |
| `BadDeviceToken` from APNs | Sandbox/production mismatch | Set `APPLE_APNS_SANDBOX=true` |
| `value too long for type character varying(64)` | DB predates the JWT migration | `migrate up` or apply `migrations/000012_*.up.sql` |
| `failed to fetch user info: oauth revoked` immediately after a successful token refresh | UA missing `(by /u/<name>)` — `oauth.reddit.com` enforces Reddit's UA convention more strictly than `www.reddit.com` does | Use a UA like `ios:com.you.Leto:v1.0 (by /u/yourname)` |

## Credits

- [Christian Selig](https://github.com/christianselig) wrote the original backend and made it open source.
- [JeffreyCA](https://github.com/JeffreyCA) maintains the iOS tweak this fork is designed to pair with, and added the **Notification Backend** field that makes the integration possible.
