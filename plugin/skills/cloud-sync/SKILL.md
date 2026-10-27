---
name: cloud-sync
description: Set up or check claude-mem cloud sync against a SyncHub deployment. Use when the user says "set up cloud sync", "sync my memories", "cloud backup", "sync status", "self-hosted sync", "SyncHub", or wants their memory database backed up or synced across machines.
allowed-tools:
  - Bash
  - Read
  - AskUserQuestion
---

# Cloud Sync

The installed worker syncs through SyncHub. There is one client, one durable
operation log, and no separate sync daemon. This skill checks status or writes
the three values that connect this machine to a SyncHub deployment.

**Security rule:** never print the sync token, put it in argv, or log it.
Confirm only its length. Preserve every unrelated setting and keep
`~/.claude-mem/settings.json` mode `0600`.

## 1. Check status

Resolve the worker port and query the always-registered status route:

```bash
PORT="${CLAUDE_MEM_WORKER_PORT:-$(node -e "const fs=require('fs'),p=require('path'),os=require('os');const uid=(typeof process.getuid==='function'?process.getuid():77);const fallback=String(37700+(uid%100));try{const s=JSON.parse(fs.readFileSync(p.join(os.homedir(),'.claude-mem','settings.json'),'utf-8'));process.stdout.write(String(s.CLAUDE_MEM_WORKER_PORT||fallback));}catch{process.stdout.write(fallback);}" 2>/dev/null)}"
curl -s "http://127.0.0.1:${PORT}/api/sync/status"
```

- `configured: true` and `hub.reachable: true` → the worker completed an
  authenticated `GET /v1/sync/status` against SyncHub. Report `deviceId`,
  pending counts, `lastFlushAt`, `lastError`, and the Hub head/checkpoint;
  stop unless the user asked to replace the connection.
- `configured: true` and `hub.reachable: false` → report `hub.error` and say
  the SyncHub connection is not verified. A zero pending count or
  `lastError: null` is not success because an empty queue performs no push.
- `configured: false` → continue.
- Connection refused, 404, or 503 immediately after restart → retry every
  three seconds for about 30 seconds before diagnosing the worker.

## 2. Obtain the connection

Ask for all three values from the user's SyncHub deployment:

1. sync token;
2. user id;
3. SyncHub URL.

On static-token hubs these map to `SYNC_STATIC_TOKEN`, `SYNC_STATIC_USER_ID`,
and the hub's public `https://` URL (see
https://github.com/frarredondo/claude-mem/blob/main/docs/public/self-hosted-sync.mdx).

The Hub URL must be an absolute `https://` SyncHub URL. Do not use an
application API URL; the installed client talks only to SyncHub.

## 3. Write installed-client settings

Substitute the collected values inside this quoted stdin script. Do not echo
them before or after running it:

```bash
node - <<'EOF'
const fs = require('fs'), os = require('os'), path = require('path');
const token = 'PASTE_TOKEN_HERE';
const userId = 'PASTE_USER_ID_HERE';
const hubUrl = 'PASTE_HUB_URL_HERE';
if (!token || !userId || !/^https:\/\/[^\s]+$/.test(hubUrl)) {
  console.error('token, user id, and an https SyncHub URL are required');
  process.exit(1);
}
const dir = path.join(os.homedir(), '.claude-mem');
const file = path.join(dir, 'settings.json');
fs.mkdirSync(dir, { recursive: true });
const settings = fs.existsSync(file) ? JSON.parse(fs.readFileSync(file, 'utf8')) : {};
const target = settings.env && typeof settings.env === 'object' ? settings.env : settings;
target.CLAUDE_MEM_CLOUD_SYNC_TOKEN = token;
target.CLAUDE_MEM_CLOUD_SYNC_USER_ID = userId;
target.CLAUDE_MEM_CLOUD_SYNC_HUB_URL = hubUrl.replace(/\/+$/, '');
fs.writeFileSync(file, JSON.stringify(settings, null, 2) + '\n', { mode: 0o600 });
fs.chmodSync(file, 0o600);
console.log(`saved cloud connection: token length ${token.length}, user id length ${userId.length}`);
EOF
```

These are the only required connection keys. The worker mints and persists a
device id on first start and defaults the device name to the hostname.

## 4. Restart and verify

```bash
curl -s -X POST "http://127.0.0.1:${PORT}/api/admin/restart"
```

Poll the status route every five seconds for up to 30 seconds while the
successor starts. Success means `configured: true`, `hub.reachable: true`, and
`lastError: null`. The local route always makes an authenticated, read-only
SyncHub status probe, even when every pending count is zero; it never uses a
legacy status route and never appends or advances sync state.
Pending counts describe only writes made after the SyncHub launch baseline;
setup does not migrate a pre-launch local corpus.

If `hub.reachable` is false, report `hub.error`. If `lastError` is non-null,
report it too. Ask the user to re-check the three values against their SyncHub
deployment. Never include the token.

## 5. Report

Report device id, pending counts, last successful flush, Hub reachability and
checkpoint, and any Hub/flush error. End with this privacy note:

> Cloud sync uploads your observation narratives and full prompt text to the
> sync hub you are connected to.
