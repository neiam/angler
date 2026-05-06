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

Runtime config lives in `config/runtime.exs`. Key flags:

| Key | Default | Effect |
| --- | --- | --- |
| `:stories_enabled` | `false` | Enables the `v1.2/stories` namespace + AP story objects |
| `:groups_enabled` | `false` | Enables the `/api/v0/groups/*` namespace |
| `:open_registration` | `true` | Allow `/auth/register` without invite |
| `:registration_approval_required` | `false` | New accounts land in pending state |
| `:in_app_registration_enabled` | `true` | Mobile in-app signup |
| `:account_deletion_enabled` | `true` | `/api/v1/accounts/delete` |
| `:landing_directory_enabled` | `false` | Public profile directory |
| `:landing_explore_enabled` | `true` | Explore feed on landing page |
| `:expo_push_enabled` | `false` | Accept Expo push tokens for mobile |
| `:push_vapid_public_key` | — | Web Push VAPID public key |
| `:media_storage` | `:local` | `:local` or `:s3` |
| `:media_root` | `priv/static/storage` | Local media path |
| `:pixelfed_directory` | `false` | Submit to upstream directory |
| `:instance_title`, `:instance_description`, `:instance_rules`, `:instance_contact_email` | — | Instance metadata surfaced via `/api/v1/instance` |

Operator-facing features (stories, groups, push, directory submission) ship
disabled — opt in per instance.

## Layout

- `lib/angler/` — domain contexts (Accounts, Statuses, Stories, Groups, Federation, …)
- `lib/angler_web/controllers/` — API surface, split by namespace
  - `mastodon_api/` — Mastodon-compatible endpoints
  - `pixelfed_admin/`, `admin/` — admin namespaces
  - `groups_api/` — `/api/v0/groups/*`
  - `federation/` — ActivityPub
- `priv/repo/migrations/` — schema history

## License

AGPL-3.0 (matches Pixelfed).
