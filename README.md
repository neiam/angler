# Angler

A Phoenix/Elixir reimplementation of the [Pixelfed](https://pixelfed.org) backend.
Wire-compatible with the Pixelfed mobile app and federation surface — drop-in for
existing clients that speak Pixelfed's `/api/v1`, `/api/v1.1`, `/api/v1.2`,
`/api/v2`, `/api/admin`, and `/api/v0/groups` namespaces.

Built on Phoenix 1.8, Bandit, Ecto, and Postgres.

## Status

API coverage matches Pixelfed's `routes/api.php` end to end:

- **Mastodon-compatible core** — accounts, statuses, timelines, notifications,
  media, follows, blocks, mutes, lists, filters, bookmarks, favourites,
  conversations, polls, hashtags, trends, search, OAuth.
- **Pixelfed extensions** — `compose`, `discover`, `directory`, `places`,
  `landing`, `pixelfed/v1` legacy mirror, `v1.1` collections, `v1.2` stories.
- **Stories** — drafts, publish, cross-poster, viewers, replies, AP object
  endpoint with bearer-cap token auth.
- **Groups** — full lifecycle (public/private/secret), members, invites,
  blocks, reports, group posts and threaded comments, discovery, search.
- **Admin** — Pixelfed admin shape (`/api/admin/*`) plus the Mastodon admin
  shape (`/api/v1/admin/*`).
- **Federation** — ActivityPub inbox/outbox, signed delivery, story objects.
- **Push** — Web Push (VAPID) and Expo (FCM/APNs) tokens for mobile.

## Getting started

Requires Elixir 1.15+ and Postgres 15+.

```bash
mix setup            # deps, db, assets
mix phx.server       # http://localhost:4000
```

Or with IEx:

```bash
iex -S mix phx.server
```

The repo includes a podman/docker compose recipe for a local Postgres:

```bash
podman compose up -d
```

## Tests

```bash
mix test
mix precommit        # compile --warnings-as-errors, format, deps.unlock --unused, test
```

`mix precommit` is what CI runs and what every change should pass.

## Configuration

Runtime config lives in `config/runtime.exs` and is driven by environment
variables. Operator-facing features (stories, groups, push, directory
submission) ship disabled — opt in per instance.

### Database

| Var | Default | Effect |
| --- | --- | --- |
| `POSTGRES_HOST` | — | When set, prod uses discrete `POSTGRES_*` vars |
| `POSTGRES_PORT` | `5432` | dev / test / prod |
| `POSTGRES_USER` | `postgres` (dev) | Required in prod when `POSTGRES_HOST` is set |
| `POSTGRES_PASSWORD` | `postgres` (dev) | Required in prod when `POSTGRES_HOST` is set |
| `POSTGRES_DB` | `angler_dev` (dev), `angler` (prod) | Database name |
| `DATABASE_URL` | — | Fallback when `POSTGRES_HOST` is unset (`ecto://USER:PASS@HOST/DB`) |
| `POOL_SIZE` | `10` | Ecto pool size (prod) |
| `SKIP_MIGRATIONS` | — | Set to `true` to disable auto-migrate-on-boot (prod). Run `bin/migrate` yourself instead |

### Endpoint

| Var | Default | Effect |
| --- | --- | --- |
| `PHX_SERVER` | unset | Set truthy to start the HTTP server in releases |
| `PORT` | `4000` | HTTP listen port |
| `PHX_HOST` | `example.com` | Public hostname (prod URL generation) |
| `SECRET_KEY_BASE` | — | Required in prod (`mix phx.gen.secret`) |
| `DNS_CLUSTER_QUERY` | — | DNSCluster discovery query |
| `ECTO_IPV6` | `false` | Set truthy for IPv6 DB sockets |

### Feature toggles

| Var | Default | Config key | Effect |
| --- | --- | --- | --- |
| `STORIES_ENABLED` | `false` | `:stories_enabled` | Enables the `v1.2/stories` namespace + AP story objects |
| `GROUPS_ENABLED` | `false` | `:groups_enabled` | Enables the `/api/v0/groups/*` namespace |
| `OPEN_REGISTRATION` | `true` | `:open_registration` | Allow `/auth/register` without invite |
| `REGISTRATION_APPROVAL_REQUIRED` | `false` | `:registration_approval_required` | New accounts land in pending state |
| `IN_APP_REGISTRATION_ENABLED` | `true` | `:in_app_registration_enabled` | Mobile in-app signup |
| `ACCOUNT_DELETION_ENABLED` | `true` | `:account_deletion_enabled` | `/api/v1/accounts/delete` |
| `LANDING_DIRECTORY_ENABLED` | `false` | `:landing_directory_enabled` | Public profile directory |
| `LANDING_EXPLORE_ENABLED` | `true` | `:landing_explore_enabled` | Explore feed on landing page |
| `EXPO_PUSH_ENABLED` | `false` | `:expo_push_enabled` | Accept Expo push tokens for mobile |
| `OAUTH_REFRESH_TOKENS` | `true` | `:oauth_refresh_tokens` | Issue refresh tokens on `/oauth/token` |

Booleans accept `true`/`1`/`yes` (case-insensitive); anything else takes the default.

### Instance metadata

Surfaced via `/api/v1/instance` and `/nodeinfo`.

| Var | Effect |
| --- | --- |
| `INSTANCE_TITLE` | Display name (default `"Angler"`) |
| `INSTANCE_SHORT_DESCRIPTION` | One-liner |
| `INSTANCE_DESCRIPTION` | Long description / about |
| `INSTANCE_BANNER_URL` | Banner image URL |
| `INSTANCE_CONTACT_EMAIL` | Admin contact email |
| `INSTANCE_CONTACT_USERNAME` | Admin contact handle |
| `INSTANCE_RULES` | Pipe- or newline-separated list (`"No spam\|Be kind"`) |

### Media storage

| Var | Default | Effect |
| --- | --- | --- |
| `MEDIA_STORAGE` | `local` | `local` or `s3` |
| `MEDIA_ROOT` | `priv/static/storage` | Local media path |

### Push (Web Push / VAPID)

Set both keys to enable. Without them push delivery is a no-op.

| Var | Effect |
| --- | --- |
| `PUSH_VAPID_PUBLIC_KEY` | Surfaced to FE for subscription |
| `PUSH_VAPID_PRIVATE_KEY` | Used for delivery signing |
| `PUSH_VAPID_SUBJECT` | `mailto:` URI (default `mailto:admin@localhost`) |

### Pixelfed directory

| Var | Default | Effect |
| --- | --- | --- |
| `PIXELFED_DIRECTORY_ENABLED` | `false` | Submit to upstream directory |
| `PIXELFED_DIRECTORY_SK` | — | Submission secret key |

### Mail

| Var | Default | Effect |
| --- | --- | --- |
| `MAIL_DRIVER` | `local` | `local` (Swoosh dev mailbox) or `smtp` |
| `SMTP_RELAY` | — | Required when `MAIL_DRIVER=smtp` |
| `SMTP_PORT` | `587` | SMTP port |
| `SMTP_USERNAME` / `SMTP_PASSWORD` | — | Optional auth |
| `SMTP_TLS` | `if_available` | `always` / `if_available` / `never` |
| `SMTP_AUTH` | `always` | `always` / `if_available` / `never` |
| `SMTP_SSL` | `false` | Set truthy for SMTPS port 465 |
| `SMTP_RETRIES` | `2` | Connection retry count |
| `SMTP_NO_MX_LOOKUPS` | `false` | Skip MX lookup |
| `MAIL_FROM` | `noreply@<host>` | From: address |
| `MAIL_FROM_NAME` | `Pixelfed` | From: display name |

## Deployment

Get started in 30 seconds. Angler is easy to run because it ships as a single
container image, published to three registries — pick whichever you mirror:

- `quay.io/neiam/angler`
- `ghcr.io/neiam/angler`
- `docker.io/neiam/angler`

The public [`/about`](lib/angler_web/live/about_live.ex) page has an interactive
"Run your own" generator for the single-container commands below (toggle
runtime/registry, fill in user / password / host). This section is the
canonical reference and also covers the compose and Kubernetes recipes.

All environment variables are documented under [Configuration](#configuration).

### Single host (podman / docker)

Put everything on one network so the app can resolve the database by name, then
start Postgres:

```bash
podman network create angler-net

podman run -d --name angler-db --network angler-net \
  -e POSTGRES_USER=angler \
  -e POSTGRES_PASSWORD=changeme \
  -e POSTGRES_DB=angler \
  -v angler-db:/var/lib/postgresql/data \
  docker.io/postgres:16-alpine
```

Then start the server. `bin/server` runs pending migrations on boot (after the
DB connects, before it serves traffic), so there's no separate migration step:

```bash
podman run -d --name angler --network angler-net \
  -p 4000:4000 \
  -e PHX_HOST=angler.you.com \
  -e SECRET_KEY_BASE="$(openssl rand -base64 48)" \
  -e DATABASE_URL=ecto://angler:changeme@angler-db/angler \
  ghcr.io/neiam/angler:latest
```

Swap `podman` for `docker` throughout; the commands are otherwise identical.

To migrate yourself instead — e.g. a dedicated pre-deploy job — set
`SKIP_MIGRATIONS=true` on the server and run `bin/migrate` separately:

```bash
podman run --rm --network angler-net \
  -e DATABASE_URL=ecto://angler:changeme@angler-db/angler \
  ghcr.io/neiam/angler:latest bin/migrate
```

Auto-migrate-on-boot is safe with **multiple replicas** — Ecto takes a Postgres
advisory lock, so concurrent pods serialize rather than race. A dedicated
migrate step is still worth it at scale, so a slow or failed migration gates one
job instead of every pod's startup.

### Compose

`compose.yml` ships a Postgres service for local development:

```bash
podman compose up -d        # or: docker compose up -d
```

### Kubernetes

`app.yml` is a reference manifest (Deployment + Service + HTTP→HTTPS redirect),
backed by a StackGres Postgres cluster (`pg.yml`). Adjust the image, `PHX_HOST`,
and secrets for your cluster.

## Layout

- `lib/angler/` — domain contexts (Accounts, Statuses, Stories, Groups, Federation, …)
- `lib/angler_web/controllers/` — API surface, split by namespace
  - `mastodon_api/` — Mastodon-compatible endpoints
  - `pixelfed_admin/`, `admin/` — admin namespaces
  - `groups_api/` — `/api/v0/groups/*`
  - `federation/` — ActivityPub
- `priv/repo/migrations/` — schema history

## License

**Angler** is Free Software under the AGPL.
