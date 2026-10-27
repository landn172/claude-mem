# Self-hosting claude-mem cloud sync (personal, ~$0/mo)

Run the sync hub and a companion projection + MCP worker on your own
Cloudflare account (Workers Free plan). Two deploys, then three settings on
each machine. No cmem.ai account involved: auth is one shared token
(`AUTH_MODE=static` in the hub), and the projection endpoint the hub
requires doubles as a remote MCP endpoint any MCP-aware agent can query.

```
machines (claude-mem worker) ──push/pull──▶ sync-hub-personal (Durable Object log)
                                                   │ projection (required)
                                                   ▼
                                            cmem-self-host (D1 + FTS5)
                                                   ▲
                    any MCP-aware agent ──── /u/<MCP_TOKEN>/mcp
```

## 0. Mint the credentials (once)

```sh
uuidgen | tr 'A-Z' 'a-z'      # SYNC_STATIC_USER_ID  (goes into your gitignored wrangler.personal.local.jsonc)
openssl rand -hex 32          # SYNC_STATIC_TOKEN    (sync credential, shared by your machines)
openssl rand -hex 32          # CMEM_INTERNAL_PROJECTOR_SECRET (hub ⇄ projector, also the admin-API credential)
openssl rand -hex 32          # MCP_TOKEN            (remote MCP credential)
```

## 1. Deploy the companion worker (projector + MCP)

```sh
cd workers/self-host
cp wrangler.jsonc wrangler.local.jsonc  # gitignored copy holds your real ids
wrangler d1 create cmem-memory          # paste the id into wrangler.local.jsonc
wrangler secret put CMEM_INTERNAL_PROJECTOR_SECRET -c wrangler.local.jsonc
wrangler secret put MCP_TOKEN                      -c wrangler.local.jsonc
wrangler deploy -c wrangler.local.jsonc # → https://cmem-self-host.<sub>.workers.dev
```

The D1 schema applies itself lazily and idempotently — there is no
`wrangler d1 execute` step.

## 2. Deploy the hub

```sh
cd workers/sync-hub
wrangler kv namespace create sync-hub-personal-AUTH_CACHE
# paste the namespace id + your SYNC_STATIC_USER_ID + the cmem-self-host URL
# into a gitignored copy of the committed template, then:
cp wrangler.personal.jsonc wrangler.personal.local.jsonc   # fill in the REPLACE_WITH_* values
wrangler secret put SYNC_STATIC_TOKEN              -c wrangler.personal.local.jsonc
wrangler secret put CMEM_INTERNAL_PROJECTOR_SECRET -c wrangler.personal.local.jsonc   # same value as step 1
wrangler deploy -c wrangler.personal.local.jsonc   # → https://sync-hub-personal.<sub>.workers.dev
```

Verify the hub ⇄ projector wiring end to end:

```sh
curl -s https://sync-hub-personal.<sub>.workers.dev/v1/sync/status \
  -H "Authorization: Bearer $SYNC_STATIC_TOKEN" \
  -H "X-User-Id: $SYNC_STATIC_USER_ID" -H "X-Device-Id: smoke"
```

## 3. Smoke test with the canary (BEFORE daily use)

The canary writes real ops into the log, so run it before the corpus is
live and reset afterwards:

```sh
bun workers/sync-hub/canary/canary.ts \
  --hub https://sync-hub-personal.<sub>.workers.dev \
  --user $SYNC_STATIC_USER_ID --token $SYNC_STATIC_TOKEN --cycles 3 --interval-ms 1000
# expect "converged":true — then wipe the canary's ops:
curl -s -X POST https://sync-hub-personal.<sub>.workers.dev/internal/v1/sync/reset \
  -H "Authorization: Bearer $CMEM_INTERNAL_PROJECTOR_SECRET" \
  -H "Content-Type: application/json" \
  -d "{\"protocol_version\":1,\"user_id\":\"$SYNC_STATIC_USER_ID\"}"
```

(Reset clears the hub log; the projector's D1 rows are guarded by
entity_rev, so wipe them too if the canary data reached D1:
`wrangler d1 execute cmem-memory --remote --command "DELETE FROM observations; DELETE FROM entities;"`.)

## 4. Configure each machine

Use the `cloud-sync` skill and paste these values, or merge them into
`~/.claude-mem/settings.json` (mode 0600) by hand:

| Setting | Value |
|---|---|
| `CLAUDE_MEM_CLOUD_SYNC_TOKEN` | the `SYNC_STATIC_TOKEN` value |
| `CLAUDE_MEM_CLOUD_SYNC_USER_ID` | the `SYNC_STATIC_USER_ID` uuid |
| `CLAUDE_MEM_CLOUD_SYNC_HUB_URL` | `https://sync-hub-personal.<sub>.workers.dev` |

Leave `CLAUDE_MEM_CLOUD_SYNC_DEVICE_ID` empty — the worker mints one. Then
restart the worker and confirm:

```sh
curl -s -X POST http://127.0.0.1:$PORT/api/admin/restart
curl -s http://127.0.0.1:$PORT/api/sync/status   # configured:true, hub.reachable:true
```

claude-mem 13.37+ also opens a live channel (`POST /v1/sync/realtime-token`,
then a WebSocket on `/v1/sync/realtime`), signed with
`CMEM_INTERNAL_PROJECTOR_SECRET`, so writes reach the other machines in about
a second rather than on the next 30 s / 5 min poll. A worker that saw a hub
without it re-checks hourly, so restart workers after upgrading the hub.

## 5. Point MCP consumers at your memory

```sh
claude mcp add --transport http cmem \
  https://cmem-self-host.<sub>.workers.dev/mcp \
  --header "Authorization: Bearer $MCP_TOKEN"
```

Agents that cannot set headers use the path form:
`https://cmem-self-host.<sub>.workers.dev/u/$MCP_TOKEN/mcp`.

Tools: `search`, `timeline`, `get_observations`, `recent_memories`,
`important_workflow` — same index-first workflow as the local MCP server.

## 6. (Optional) Backfill pre-launch history

Rows created before the sync launch baseline are excluded from sync by
design. To upload them to YOUR hub, run — once, on ONE machine only (the
one with the fullest history), with the worker stopped:

```sh
bun scripts/self-host-backfill.ts
```

Backfilling from a second machine would upload overlapping history as
distinct entities and duplicate it everywhere. A large backfill may span
Workers Free daily caps; the client's backoff resumes it losslessly.

## Notes

- **Token rotation**: `wrangler secret put SYNC_STATIC_TOKEN -c
  wrangler.personal.local.jsonc`, then update the settings file on each machine.
  No cache to wait out — static mode never touches KV.
- **Free-plan caps** (reset midnight UTC) degrade sync to latency, never
  loss: unsynced rows stay queued locally and the drain retries.
- **The projector is on the push path**: if cmem-self-host errors, pushes
  answer 503 and retry; data is safe in the hub log. The repair drain
  (`POST /internal/v1/projection/drain` on the hub, projector secret)
  catches the checkpoint up after an outage.
- **Privacy**: cloud sync uploads observation narratives and full prompt
  text to infrastructure you control — the same caveat as cmem.ai Pro,
  minus the third party.
