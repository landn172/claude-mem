# Workers

Cloud sync runs on two Cloudflare Workers. They are deployed separately and are
not interchangeable.

| Directory | Worker | Job |
|---|---|---|
| `sync-hub/` | the hub | holds the ordered operation log in a Durable Object; devices push and pull against it |
| `self-host/` | the companion | projects that log into D1 with FTS5 search, and serves a remote MCP endpoint over the result |

The hub requires a live projector: pushes answer 503 until the projection
checkpoint covers `head_seq`.

In the self-host configs (`wrangler.personal.jsonc`, `wrangler.group.jsonc`)
the hub reaches the projector through a `PROJECTOR` service binding, so deploy
the companion first — the binding fails to deploy if its target does not exist.
The multi-user hub has no such binding; it fetches `INTERNAL_PROJECTOR_URL`
directly.

Runbooks: `self-host/SELF-HOSTING.md` for a single-group self-host
(https://docs.claude-mem.ai/self-hosted-sync), `sync-hub/DEPLOY.md` for the
multi-user hub.

## Multiple groups in one Cloudflare account

A deployment serves exactly one group of machines. The hub routes each request
to `env.SYNC_HUB.getByName(userId)`: one user id is one Durable Object and one
log. Static auth then binds the token to exactly one user id, so a foreign
`X-User-Id` gets a 403.

To keep two sets of machines from seeing each other's memory, run a second
stack in the same account. **The projector cannot be shared** — its D1 tables
are keyed by `entity_id` with no `user_id` column, and the MCP tools filter by
project and timestamp, never by user. Two hubs pointed at one projector merge
both corpora into one store that either group's `MCP_TOKEN` can read.

Per group:

| Resource | First group | Second group |
|---|---|---|
| Hub worker | `sync-hub-personal` | `sync-hub-personal-2` |
| KV namespace | its own | its own |
| `SYNC_STATIC_USER_ID` | a fresh uuid | a different uuid |
| `SYNC_STATIC_TOKEN` | its own | its own |
| Projector worker | `cmem-self-host` | `cmem-self-host-personal-2` |
| D1 database | `cmem-memory` | `cmem-memory-personal-2` |
| `CMEM_INTERNAL_PROJECTOR_SECRET` | its own | its own |
| `MCP_TOKEN` | its own | its own |
| `MCP_SERVER_NAME` | `cmem-self-host` | `cmem-self-host-personal-2` |

`sync-hub/wrangler.group.jsonc` and `self-host/wrangler.group.jsonc` are the
templates for an additional group; `SELF-HOSTING.md` carries the commands.
`MCP_SERVER_NAME` is the name each projector reports in the MCP handshake, so
a client can tell the servers apart; it defaults to `cmem-self-host`.

Constraints:

- **One account is mandatory.** The service binding above only resolves within
  a single Cloudflare account. Splitting groups across accounts would mean
  replacing it with an authenticated fetch.
- **Quotas are per account, not per group.** Every stack draws on the same
  daily Durable Objects and D1 allowances, so a bulk backfill in one group can
  exhaust the day for both.
- **Slugs become Worker names**, so they take alphanumerics and dashes only —
  `personal-2`, never `personal_2`.
- **A machine belongs to exactly one group.** The three connection settings
  live in `~/.claude-mem/settings.json` and apply to the whole install; there
  is no per-project routing, so a machine's entire corpus goes to whichever hub
  it points at.
