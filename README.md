# apollo-backend (self-hosting fork)

A self-hostable fork of [`christianselig/apollo-backend`](https://github.com/christianselig/apollo-backend), the archived Go service that powered push notifications, inbox checks, and subreddit/user watchers for the original [Apollo for Reddit](https://apolloapp.io/) iOS app.

This fork is meant to be run together with **[JeffreyCA/Apollo-ImprovedCustomApi](https://github.com/JeffreyCA/Apollo-ImprovedCustomApi)** — the iOS tweak that lets sideloaded Apollo builds use the user's own Reddit OAuth credentials. The tweak's **Settings > Custom API > Notification Backend** URL field points at an instance of this fork; with that wired up, push notifications and watchers come back to life for sideloads that have a real APNs entitlement.

Single-tenant by design: one deployment serves one sideloaded Apollo build (one bundle ID, one Apple Developer team), and can be shared with a small group of friends running the same build.

## What changed from upstream

The upstream backend was deeply tied to Christian's App Store deployment. This fork strips or reworks every assumption that depended on it.

- **Stripped entirely**: App Store IAP / Apollo Ultra receipt validation (`/v1/receipt`, the `internal/itunes/` package, the device-deletion side effect on receipt failure), Live Activities (the World Cup-era Dynamic Island worker), the `/v1/contact` endpoint, Bugsnag, Heroku's hmetrics auto-emitter, and `render.yaml`.
- **APNs topic is configurable** via `APPLE_APNS_TOPIC` — formerly hardcoded to `com.christianselig.Apollo`.
- **Reddit OAuth credentials are per-account**, stored in new `reddit_client_id` / `reddit_client_secret` / `reddit_redirect_uri` / `reddit_user_agent` columns on `accounts`. The process-level `reddit.Client` no longer carries any credentials. Installed-app Reddit credentials (empty client_secret) are accepted.
- **Registration endpoints are gated** by the optional `REGISTRATION_SECRET` env var. When set, `POST /v1/device`, `POST /v1/device/{apns}/account`, and `POST /v1/device/{apns}/accounts` require an `X-Registration-Token` header.
- **StatsD is optional** — a `NoOpClient` is wired in when `STATSD_URL` is unset (formerly crashed at startup).
- **Dockerized** — `Dockerfile` + `docker-compose.yml` replace the original Render-specific deployment.

The result: the backend boots end-to-end with only Postgres, Redis, an APNs auth key, and a bundle ID. Everything else is opt-in.

## Quickstart with Docker

Requires Docker + an APNs auth key (`.p8`) from a **paid** Apple Developer account.

```bash
git clone https://github.com/<you>/apollo-backend
cd apollo-backend

# 1. Drop your APNs key
mkdir -p secrets
cp ~/Downloads/AuthKey_XXXXXXXXXX.p8 secrets/apple.p8

# 2. Configure environment
cp .env.docker.example .env.docker   # or edit .env.docker directly
$EDITOR .env.docker                   # fill in APPLE_KEY_ID, APPLE_TEAM_ID,
                                      # APPLE_APNS_TOPIC, REGISTRATION_SECRET

# 3. Bring it up
make docker-up
make docker-logs                      # follow output until health check passes
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
| `REDIS_QUEUE_URL` | Redis backing rmq job queues. `noeviction`. |
| `REDIS_LOCKS_URL` | Redis backing the dedup locks (Lua script in `scheduler.go`). Can be the same instance as the queue Redis. |
| `APPLE_KEY_PATH` | Path to your APNs auth key `.p8` file. |
| `APPLE_KEY_ID` | APNs key ID from developer.apple.com. |
| `APPLE_TEAM_ID` | Your Apple Developer team ID. |
| `APPLE_APNS_TOPIC` | Bundle ID of the sideloaded Apollo build (e.g. `com.foo.Apollo`). Used as the APNs `apns-topic` on every push. Crashes at startup if unset. |

## Optional environment variables

| Var | Default | Effect |
|---|---|---|
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

Make sure the **Reddit API Key**, **Redirect URI**, and **User Agent** in the tweak's main Custom API screen are filled in — the tweak injects all three (and the optional client secret) into the registration body, and the backend rejects registrations that arrive without them. Installed-app Reddit credentials work; just leave the **Reddit API Secret** field blank in the tweak.

What the tweak does once the URL is set: it intercepts any request Apollo makes to the three dead legacy hosts (`apollopushserver.xyz`, `beta.apollonotifications.com`, `apolloreq.com`) and rewrites the scheme/host/port to your backend. For account registration requests it also injects the four Reddit OAuth fields into the JSON body from your saved tweak settings, and attaches the `X-Registration-Token` header if you've set one. Everything else (path, query, method, other headers, payload) passes through unchanged.

## Apple Developer entitlement caveat

APNs delivery requires a real `aps-environment` entitlement, which Apple only grants under a **paid** Apple Developer team. Free-account sideloads can register devices, store watchers, and exercise every endpoint — but the pushes will never actually arrive on the device. There's nothing the backend can do about this.

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

## Credits

- [Christian Selig](https://github.com/christianselig) wrote the original backend and made it open source.
- [JeffreyCA](https://github.com/JeffreyCA) maintains the iOS tweak this fork is designed to pair with, and added the **Notification Backend** field that makes the integration possible.
