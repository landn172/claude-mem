#!/usr/bin/env bash
#
# deploy-sync-stack.sh — provision self-hosted claude-mem cloud sync stacks.
#
# Performs workers/self-host/SELF-HOSTING.md for one or more isolated groups:
# mints every credential in 1Password, creates the D1 database and KV
# namespace, renders the gitignored wrangler configs from the committed
# templates, deploys the projector then the hub, and verifies the wiring.
#
# One group is one hub + one projector + one D1 + one KV + one user id. The
# projector is single-tenant (its D1 tables have no user_id column), so groups
# never share one; see the "Running isolated groups" section of the runbook.
#
# Idempotent: 1Password is the source of truth for a group's identity, so a
# re-run reuses every credential and resource instead of minting new ones. A
# run that dies halfway is finished by running it again.
#
# One vault holds one fleet of groups: the cross-group isolation checks (user
# id, D1 id, KV id) scan the chosen vault, so groups recorded in a different
# vault are not cross-checked against each other.
#
# Secrets are never placed in argv, written to disk, or logged. They stream
# from `op read` into `wrangler secret put` over a pipe, and reach curl through
# a `-K -` config on stdin.
#
#   ./scripts/deploy-sync-stack.sh --groups personal,work-corp-a --vault Private
#   ./scripts/deploy-sync-stack.sh --dry-run --group personal
#   ./scripts/deploy-sync-stack.sh --list
#
# Requires: op (signed in), jq, npx/wrangler (logged in), curl, uuidgen, and
# bun only for the optional canary.

set -euo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

HUB_DIR="$ROOT_DIR/workers/sync-hub"
PROJ_DIR="$ROOT_DIR/workers/self-host"
HUB_TEMPLATE="$HUB_DIR/wrangler.group.jsonc"
PROJ_TEMPLATE="$PROJ_DIR/wrangler.group.jsonc"

OP_BASE_TAGS="claude-mem,sync-hub"
OP_SECTION="stack"
SLUG_MAX=40
SECRET_MIN_LEN=32
PROBE_DEVICE_ID="deploy-sync-stack-probe"

# A workers.dev hostname that THIS run just created answers 404 from the edge
# until its route propagates, so the first probe of a brand-new Worker can lose
# a race that says nothing about the stack. Retry only the two codes a
# not-yet-live route produces — 404 (no route) and 000 (name does not resolve
# yet) — and never 401/403/500/503, which are real misconfigurations that must
# fail on the first look rather than after a wait.
PROBE_RETRIES=6
PROBE_RETRY_WAIT=5

# wrangler's `secret put` wraps its stdin read in trimTrailingWhitespace(), so
# the trailing newline `op read` emits is discarded rather than stored.
export WRANGLER_SEND_METRICS=false

# ---------------------------------------------------------------- output ----

if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
	C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_BLD=$'\033[1m'
	C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_CYN=$'\033[36m'
else
	C_RESET=; C_DIM=; C_BLD=; C_RED=; C_GRN=; C_YEL=; C_CYN=
fi

# local IFS: $* would otherwise join multiple arguments on a newline.
step() { local IFS=' '; printf '\n%s\n' "${C_BLD}${C_CYN}▸ $*${C_RESET}" >&2; }
info() { local IFS=' '; printf '%s\n' "    $*" >&2; }
ok()   { local IFS=' '; printf '%s\n' "    ${C_GRN}✓${C_RESET} $*" >&2; }
warn() { local IFS=' '; printf '%s\n' "    ${C_YEL}!${C_RESET} $*" >&2; }
err()  { local IFS=' '; printf '%s\n' "    ${C_RED}✗${C_RESET} $*" >&2; }
die()  { err "$*"; exit 1; }

shq() { # shell-quote one argument so dry-run output is copy-pasteable
	[ -n "$1" ] || { printf "''"; return 0; }
	case "$1" in
		*[!A-Za-z0-9._/:@=,-]*) printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")" ;;
		*) printf '%s' "$1" ;;
	esac
}

# Never "$*" an array here: it joins on the first character of IFS, a newline.
join_args() {
	local out="" a
	for a in "$@"; do out="$out $(shq "$a")"; done
	printf '%s' "${out# }"
}

would() { printf '%s\n' "    ${C_DIM}would run:${C_RESET} $(join_args "$@")" >&2; }
# For a line that is already a formatted command (a pipeline, a comment), so it
# does not get quoted a second time.
would_raw() { printf '%s\n' "    ${C_DIM}would run:${C_RESET} $1" >&2; }

# One directory per run, removed by the parent's EXIT trap. Tracking
# individual paths cannot work: mktmp is always called inside $( ), so any
# variable it set would die with that subshell, and group subshells do not
# inherit this trap. Removing the whole directory covers files the subshells
# created too.
TMP_DIR=""
cleanup() {
	[ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ] && rm -rf "$TMP_DIR"
	return 0
}
trap cleanup EXIT

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cmem-deploy.XXXXXX")" || {
	printf 'cannot create a temporary directory\n' >&2
	exit 1
}

mktmp() { mktemp "$TMP_DIR/f.XXXXXX"; }

# ------------------------------------------------------------------ flags ----

VAULT=""
CMEM_GROUPS=()
DRY_RUN=0
ASSUME_YES=0
CANARY=ask          # ask | yes | no
VERIFY_ONLY=0
LIST_ONLY=0
SKIP_OP_CHECK=0
HUB_URL_OVERRIDE=""

usage() {
	cat <<USAGE
$SCRIPT_NAME — provision self-hosted claude-mem cloud sync stacks.

Usage:
  $SCRIPT_NAME [options]

Options:
  --group SLUG        Provision this group (repeatable).
  --groups a,b,c      Provision these groups (comma or space separated).
  --vault NAME        1Password vault for the credentials.
  --list              List already-provisioned groups in the vault, then exit.
  --verify-only       Skip provisioning; verify the groups' existing stacks.
  --canary            Run the canary smoke test without asking.
  --no-canary         Skip the canary smoke test without asking.
  --dry-run           Print every mutating command instead of running it.
  --yes               Skip confirmations (the Cloudflare account gate still
                      requires a typed yes unless CLOUDFLARE_ACCOUNT_ID is
                      set and matches).
  --hub-url URL       Record this url as the group's hub instead of the
                      deployed workers.dev hostname — for a custom domain.
                      Needs exactly one --group. Without it a redeploy KEEPS
                      whatever hub_url is already recorded, so a custom domain
                      survives; pass the workers.dev url here to go back.
  --skip-op-check     Skip the \`op whoami\` preflight. Use when op is
                      authorized by biometric unlock or the desktop app and
                      whoami reports on a different (or deleted) account.
                      Every 1Password read still fails loudly on its own.
  -h, --help          This message.

A group slug becomes a Cloudflare Worker name: lowercase alphanumerics and
dashes only, up to $SLUG_MAX characters. Per group the script provisions
sync-hub-<slug>, cmem-self-host-<slug>, cmem-memory-<slug>,
sync-hub-<slug>-AUTH_CACHE, and four 1Password items tagged
$OP_BASE_TAGS,<slug>.
USAGE
}

add_groups() { # accepts comma, space or newline separated slugs
	local raw="$1" item
	raw="$(printf '%s' "$raw" | tr ',' ' ' | tr '\n' ' ' | tr '\t' ' ')"
	for item in $(printf '%s' "$raw" | tr ' ' '\n' | grep -v '^$' || true); do
		CMEM_GROUPS[${#CMEM_GROUPS[@]}]="$item"
	done
}

while [ $# -gt 0 ]; do
	case "$1" in
		--group)   [ $# -ge 2 ] || die "--group needs a value";  add_groups "$2"; shift 2 ;;
		--groups)  [ $# -ge 2 ] || die "--groups needs a value"; add_groups "$2"; shift 2 ;;
		--vault)   [ $# -ge 2 ] || die "--vault needs a value";  VAULT="$2";      shift 2 ;;
		--hub-url) [ $# -ge 2 ] || die "--hub-url needs a value"; HUB_URL_OVERRIDE="$2"; shift 2 ;;
		--list)         LIST_ONLY=1;   shift ;;
		--verify-only)  VERIFY_ONLY=1; shift ;;
		--canary)       CANARY=yes;    shift ;;
		--no-canary)    CANARY=no;     shift ;;
		--dry-run)      DRY_RUN=1;     shift ;;
		--skip-op-check) SKIP_OP_CHECK=1; shift ;;
		--yes|-y)       ASSUME_YES=1;  shift ;;
		-h|--help)      usage; exit 0 ;;
		*) usage >&2; die "unknown option: $1" ;;
	esac
done

[ "$VERIFY_ONLY" -eq 1 ] && [ "$CANARY" = "ask" ] && CANARY=no

# ------------------------------------------------------------------ input ----

confirm() { # $1 prompt — returns 0 on yes
	local reply IFS=$' \t\n'
	[ "$ASSUME_YES" -eq 1 ] && return 0
	[ -t 0 ] || die "no terminal to confirm \"$1\" — pass --yes"
	printf '    %s [y/N] ' "$1" >&2
	read -r reply || reply=""
	case "$reply" in y|Y|yes|YES|Yes) return 0 ;; *) return 1 ;; esac
}

ask_value() { # $1 prompt, $2 default — echoes the answer
	local reply IFS=$' \t\n'
	if [ ! -t 0 ] || [ "$ASSUME_YES" -eq 1 ]; then
		[ -n "$2" ] || die "cannot prompt for \"$1\" without a terminal"
		printf '%s' "$2"; return 0
	fi
	printf '    %s' "$1" >&2
	[ -n "$2" ] && printf ' [%s]' "$2" >&2
	printf ': ' >&2
	read -r reply || reply=""
	printf '%s' "${reply:-$2}"
}

require_typed_yes() { # $1 prompt
	local reply IFS=$' \t\n'
	[ -t 0 ] || die "no terminal to confirm \"$1\""
	printf '    %s (type yes) ' "$1" >&2
	read -r reply || reply=""
	[ "$reply" = "yes" ] || die "aborted"
}

# ------------------------------------------------------------------ names ----

hub_worker()  { printf 'sync-hub-%s' "$1"; }
proj_worker() { printf 'cmem-self-host-%s' "$1"; }
d1_name()     { printf 'cmem-memory-%s' "$1"; }
kv_name()     { printf 'sync-hub-%s-AUTH_CACHE' "$1"; }
mcp_alias()   { printf 'cmem-%s' "$1"; }
hub_config()  { printf '%s/wrangler.%s.local.jsonc' "$HUB_DIR" "$1"; }
proj_config() { printf '%s/wrangler.%s.local.jsonc' "$PROJ_DIR" "$1"; }

title_sync_token()  { printf 'claude-mem sync %s SYNC_STATIC_TOKEN' "$1"; }
title_proj_secret() { printf 'claude-mem sync %s CMEM_INTERNAL_PROJECTOR_SECRET' "$1"; }
title_mcp_token()   { printf 'claude-mem sync %s MCP_TOKEN' "$1"; }
title_note()        { printf 'claude-mem sync %s stack' "$1"; }

validate_slug() {
	local s="$1" re='^[a-z0-9]([a-z0-9-]*[a-z0-9])?$'
	[ -n "$s" ] || die "empty group slug"
	case "$s" in
		*_*) die "group \"$s\": Cloudflare Worker names take alphanumerics and dashes only — use \"$(printf '%s' "$s" | tr '_' '-')\"" ;;
	esac
	if [ "$s" != "$(printf '%s' "$s" | tr 'A-Z' 'a-z')" ]; then
		die "group \"$s\": use lowercase — \"$(printf '%s' "$s" | tr 'A-Z' 'a-z')\""
	fi
	[ ${#s} -le $SLUG_MAX ] || die "group \"$s\": ${#s} characters exceeds the $SLUG_MAX limit (cmem-self-host- is 15 and a workers.dev label caps at 63)"
	[[ $s =~ $re ]] || die "group \"$s\": must match $re"
}

validate_uuid() {
	local v="$1" re='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
	[[ $v =~ $re ]] || die "not a uuid: \"$v\""
}

# A resource id lands in sed replacement text, where a stray & | or \ would
# corrupt the rendered config. Cloudflare only ever returns uuid/32-hex.
validate_d1_id() {
	case "$1" in DRY-RUN-*) return 0 ;; esac
	validate_uuid "$1"
}

validate_kv_id() {
	local re='^[0-9a-f]{32}$'
	case "$1" in DRY-RUN-*) return 0 ;; esac
	[[ $1 =~ $re ]] || die "not a KV namespace id: \"$1\""
}

# A url read back from 1Password reaches curl's -K config, where an embedded
# newline would inject further directives.
validate_https_url() {
	local v="$1" re='^https://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._~%/-]*)?$'
	[[ $v =~ $re ]] || die "not a plain https url: \"$v\""
}

validate_subdomain() {
	local v="$1" re='^[a-z0-9]([a-z0-9-]*[a-z0-9])?$'
	[[ $v =~ $re ]] || die "not a workers.dev subdomain label: \"$v\""
}

new_uuid() {
	if command -v uuidgen >/dev/null 2>&1; then
		uuidgen | tr 'A-Z' 'a-z' | tr -d '\n\r'
	elif [ -r /proc/sys/kernel/random/uuid ]; then
		tr -d '\n\r' < /proc/sys/kernel/random/uuid
	else
		die "no uuid source available — install uuidgen"
	fi
}

# --------------------------------------------------------------- 1Password ----

# `op whoami` answers for the CURRENT auth method only. A service-account token
# in the environment makes it report on that account — and fail outright once
# the account is deleted or rate-limited — even when biometric/desktop-app
# unlock would authorize the reads this script actually performs. So the check
# is a convenience, not a capability test, and --skip-op-check turns it off.
# Nothing is loosened by skipping it: every read is still `|| die`, so a genuine
# auth failure surfaces at the first read with 1Password's own message.
op_signed_in() {
	[ "$SKIP_OP_CHECK" -eq 1 ] && return 0
	op whoami >/dev/null 2>&1
}

# Listings are cached per group: op costs ~1s a call and npx wrangler ~2s, and
# an uncached multi-group run repeats each of them a dozen times. Every function
# that mutates a listing refreshes its cache, and each group runs in its own
# subshell, so a stale cache cannot leak between groups.
OP_ITEMS_JSON=""
op_items_refresh() {
	OP_ITEMS_JSON="$(op item list --vault "$VAULT" --format=json 2>/dev/null || printf '[]')"
	[ -n "$OP_ITEMS_JSON" ] || OP_ITEMS_JSON='[]'
}

op_item_count() { # $1 title — 0, 1, or more (duplicate titles are ambiguous)
	[ -n "$OP_ITEMS_JSON" ] || op_items_refresh
	printf '%s' "$OP_ITEMS_JSON" \
		| jq --arg t "$1" '[.[] | select(.title == $t)] | length'
}

op_item_exists() { # $1 title
	local n
	n="$(op_item_count "$1")"
	case "$n" in
		0) return 1 ;;
		1) return 0 ;;
		*) die "1Password has $n items titled \"$1\" in vault \"$VAULT\" — resolve the duplicate before re-running" ;;
	esac
}

op_ensure_password() { # $1 title, $2 slug
	local title="$1" slug="$2"
	if op_item_exists "$title"; then
		ok "1Password: reusing \"$title\""
		return 0
	fi
	if [ "$DRY_RUN" -eq 1 ]; then
		# Real call with --dry-run: validates the vault, title and recipe
		# without storing anything. Its JSON carries a generated password, so
		# it goes to /dev/null and never reaches the log.
		op item create --category password --title "$title" --vault "$VAULT" \
			--tags "$OP_BASE_TAGS,$slug" --generate-password='letters,digits,64' \
			--dry-run --format=json >/dev/null \
			|| die "op item create would fail for \"$title\""
		would op item create --category password --title "$title" --vault "$VAULT" \
			--tags "$OP_BASE_TAGS,$slug" --generate-password=letters,digits,64
		return 0
	fi
	op item create --category password --title "$title" --vault "$VAULT" \
		--tags "$OP_BASE_TAGS,$slug" --generate-password='letters,digits,64' \
		--format=json >/dev/null \
		|| die "failed to create 1Password item \"$title\""
	op_items_refresh
	ok "1Password: created \"$title\" (64 chars, letters+digits)"
}

op_assert_secret_len() { # $1 title — confirms length only, never the value
	local title="$1" len
	if [ "$DRY_RUN" -eq 1 ] && ! op_item_exists "$title"; then
		info "dry run: \"$title\" does not exist yet, skipping the length check"
		return 0
	fi
	# Explicit || die: without it a failing `op read` (expired session) aborts
	# the group through errexit with only op's own stderr to go on.
	len="$(op read "op://$VAULT/$title/password" | tr -d '\n\r' | wc -c | tr -d ' ')" \
		|| die "cannot read \"$title\" from vault \"$VAULT\" — is the op session still valid? (\`op whoami\`)"
	[ "$len" -ge "$SECRET_MIN_LEN" ] \
		|| die "\"$title\" holds $len characters, expected at least $SECRET_MIN_LEN"
	ok "1Password: \"$title\" readable, $len characters"
}

op_note_field() { # $1 title, $2 label — empty string when absent
	op item get "$1" --vault "$VAULT" --format=json 2>/dev/null \
		| jq -r --arg f "$2" '[.fields[]? | select(.label == $f) | .value] | first // ""'
}

# Metadata values (ids, urls, the user id) are not credentials, so passing them
# as op assignment arguments is fine. No secret is ever assigned this way.
op_note_create() { # $1 slug, then field=value assignments
	local slug="$1"; shift
	if [ "$DRY_RUN" -eq 1 ]; then
		would op item create --category "Secure Note" --title "$(title_note "$slug")" \
			--vault "$VAULT" --tags "$OP_BASE_TAGS,$slug" "$@"
		return 0
	fi
	op item create --category "Secure Note" --title "$(title_note "$slug")" \
		--vault "$VAULT" --tags "$OP_BASE_TAGS,$slug" --format=json "$@" >/dev/null \
		|| die "failed to create the metadata note for \"$slug\""
	op_items_refresh
	ok "1Password: created \"$(title_note "$slug")\""
}

op_note_set() { # $1 slug, then field=value assignments
	local slug="$1"; shift
	if [ "$DRY_RUN" -eq 1 ]; then
		would op item edit "$(title_note "$slug")" --vault "$VAULT" "$@"
		return 0
	fi
	op item edit "$(title_note "$slug")" --vault "$VAULT" --format=json "$@" >/dev/null \
		|| die "failed to update the metadata note for \"$slug\""
}

# Every provisioned group's user id, as "slug<tab>user_id" lines.
op_known_user_ids() {
	local titles t slug uid marker
	titles="$(op item list --vault "$VAULT" --format=json 2>/dev/null \
		| jq -r '[.[] | select(.tags != null)
		          | select((.tags | index("claude-mem")) and (.tags | index("sync-hub")))
		          | select(.title | endswith(" stack"))
		          | .title] | .[]')" || true
	[ -n "$titles" ] || return 0
	local dupes
	dupes="$(printf '%s\n' "$titles" | sort | uniq -d)"
	[ -z "$dupes" ] \
		|| die "vault \"$VAULT\" holds duplicate metadata notes ($(printf '%s' "$dupes" | tr '\n' ' ')) — the user-id collision check cannot run until they are resolved"
	local oldifs="$IFS"
	IFS=$'\n'
	for t in $titles; do
		slug="$(printf '%s' "$t" | sed -n 's/^claude-mem sync \(.*\) stack$/\1/p')"
		[ -n "$slug" ] || continue
		uid="$(op_note_field "$t" user_id)"
		# Still emitted with an empty uid: the id-sharing scan does not need one,
		# and silently dropping the group would narrow two safety nets at once.
		if [ -z "$uid" ]; then
			# op_known_user_ids runs once per vault scan (up to three per group),
			# and the warning is about the vault, not this scan — so say it once.
			marker="$TMP_DIR/nouid.$(printf '%s' "$t" | tr -c 'A-Za-z0-9' '_')"
			if [ ! -f "$marker" ]; then
				warn "\"$t\" has no user_id field — it cannot take part in the user-id collision check"
				: > "$marker"
			fi
		fi
		printf '%s\t%s\n' "$slug" "$uid"
	done
	IFS="$oldifs"
}

# assert_id_unshared only inspects configs rendered on THIS machine, so a
# group provisioned from another laptop would not be caught. The metadata notes
# record the same ids and are vault-wide, so they close that gap.
assert_id_unshared_in_notes() { # $1 slug, $2 note field, $3 id, $4 label
	local slug="$1" field="$2" id="$3" label="$4" other_slug other_uid tmp value
	[ -n "$id" ] || return 0
	case "$id" in DRY-RUN-*) return 0 ;; esac
	tmp="$(mktmp)"
	op_known_user_ids > "$tmp"
	while IFS=$'\t' read -r other_slug other_uid; do
		[ -n "$other_slug" ] || continue
		[ "$other_slug" = "$slug" ] && continue
		value="$(op_note_field "$(title_note "$other_slug")" "$field")"
		if [ "$value" = "$id" ]; then
			die "$label $id is already recorded for group \"$other_slug\" in vault \"$VAULT\" — two groups cannot share it; the projector is single-tenant and both corpora would merge"
		fi
	done < "$tmp"
}

assert_user_id_unique() { # $1 slug, $2 user_id
	local slug="$1" uid="$2" line other_slug other_uid tmp
	tmp="$(mktmp)"
	op_known_user_ids > "$tmp"
	while IFS=$'\t' read -r other_slug other_uid; do
		[ -n "$other_slug" ] || continue
		[ "$other_slug" = "$slug" ] && continue
		[ -n "$other_uid" ] || continue
		if [ "$other_uid" = "$uid" ]; then
			die "group \"$slug\" and group \"$other_slug\" both claim user id $uid — one user id is one Durable Object, so the two groups would share a single log and all isolation would be gone"
		fi
	done < "$tmp"
	ok "user id is unique across the groups recorded in \"$VAULT\""
}

# -------------------------------------------------------------- cloudflare ----

# WRANGLER_BIN overrides the wrangler entrypoint. It must be ONE word — a
# path or a command name, not "npx wrangler".
if [ -n "${WRANGLER_BIN:-}" ]; then
	WRANGLER=("$WRANGLER_BIN")
else
	WRANGLER=(npx --yes wrangler)
fi

# wrangler occasionally prints an update banner alongside --json output.
json_only() { sed -n '/^[[{]/,$p'; }

D1_LIST_JSON=""
d1_list_refresh() {
	local tmp rc=0 out
	tmp="$(mktmp)"
	local errf
	errf="$(mktmp)"
	"${WRANGLER[@]}" d1 list --json > "$tmp" 2>"$errf" || rc=$?
	if [ "$rc" -ne 0 ]; then
		sed 's/^/      /' < "$errf" >&2 || true
		die "\`wrangler d1 list\` failed (exit $rc) — cannot tell which databases exist, and guessing risks creating a duplicate"
	fi
	out="$(json_only < "$tmp")"
	if [ -z "$(printf '%s' "$out" | tr -d '[:space:]')" ]; then
		D1_LIST_JSON='[]'   # an account with no D1 databases yet
	else
		printf '%s' "$out" | jq empty >/dev/null 2>&1 \
			|| die "\`wrangler d1 list --json\` returned output that is not JSON"
		D1_LIST_JSON="$out"
	fi
}

d1_id_for() { # $1 database name — uuid or empty
	[ -n "$D1_LIST_JSON" ] || d1_list_refresh
	printf '%s' "$D1_LIST_JSON" \
		| jq -r --arg n "$1" '[.[] | select(.name == $n) | .uuid] | first // ""'
}

KV_LIST_JSON=""
kv_list_refresh() {
	local tmp rc=0 out
	tmp="$(mktmp)"
	local errf
	errf="$(mktmp)"
	"${WRANGLER[@]}" kv namespace list > "$tmp" 2>"$errf" || rc=$?
	if [ "$rc" -ne 0 ]; then
		sed 's/^/      /' < "$errf" >&2 || true
		die "\`wrangler kv namespace list\` failed (exit $rc) — cannot tell which namespaces exist, and guessing risks creating a duplicate"
	fi
	out="$(json_only < "$tmp")"
	if [ -z "$(printf '%s' "$out" | tr -d '[:space:]')" ]; then
		KV_LIST_JSON='[]'
	else
		printf '%s' "$out" | jq empty >/dev/null 2>&1 \
			|| die "\`wrangler kv namespace list\` returned output that is not JSON"
		KV_LIST_JSON="$out"
	fi
}

kv_id_for() { # $1 namespace title — id or empty
	[ -n "$KV_LIST_JSON" ] || kv_list_refresh
	printf '%s' "$KV_LIST_JSON" \
		| jq -r --arg n "$1" '[.[] | select(.title == $n) | .id] | first // ""'
}

cf_account_gate() {
	local out name id
	step "Cloudflare account"
	out="$("${WRANGLER[@]}" whoami 2>&1)" || die "wrangler whoami failed — run \`npx wrangler login\`"
	local ids n
	ids="$(printf '%s' "$out" | grep -oE '[0-9a-f]{32}' | sort -u || true)"
	[ -n "$ids" ] || { printf '%s\n' "$out" >&2; die "could not read the account id from wrangler whoami"; }
	n="$(printf '%s\n' "$ids" | grep -c . || true)"
	if [ "$n" -gt 1 ] && [ -z "${CLOUDFLARE_ACCOUNT_ID:-}" ]; then
		printf '%s\n' "$out" >&2
		die "this login can reach $n Cloudflare accounts — pin the intended one with CLOUDFLARE_ACCOUNT_ID=<id> so every wrangler call targets it"
	fi
	if [ -n "${CLOUDFLARE_ACCOUNT_ID:-}" ]; then
		printf '%s\n' "$ids" | grep -Fqx "$CLOUDFLARE_ACCOUNT_ID" \
			|| die "CLOUDFLARE_ACCOUNT_ID is $CLOUDFLARE_ACCOUNT_ID but this wrangler login cannot reach it"
		id="$CLOUDFLARE_ACCOUNT_ID"
	else
		id="$ids"
	fi
	name="$(printf '%s' "$out" | grep -F "$id" | sed -e 's/│/|/g' -e 's/^ *| *//' -e 's/ *|.*$//' | head -1)"
	info "account: ${name:-unknown}"
	info "id:      $id"
	if [ -n "${CLOUDFLARE_ACCOUNT_ID:-}" ]; then
		ok "matches the pinned CLOUDFLARE_ACCOUNT_ID"
	else
		require_typed_yes "Deploy into this account?"
	fi
	CF_ACCOUNT_ID="$id"
	# Pin every later wrangler call to the account that was just confirmed.
	export CLOUDFLARE_ACCOUNT_ID="$CF_ACCOUNT_ID"
}

deploy_worker() { # $1 config path, $2 worker name — echoes the workers.dev url
	local cfg="$1" name="$2" out url
	if [ "$DRY_RUN" -eq 1 ]; then
		would "${WRANGLER[@]}" deploy -c "$cfg"
		printf 'https://%s.%s.workers.dev' "$name" "$DRY_SUBDOMAIN"
		return 0
	fi
	out="$("${WRANGLER[@]}" deploy -c "$cfg" 2>&1)" || {
		printf '%s\n' "$out" >&2
		die "wrangler deploy failed for $name"
	}
	printf '%s\n' "$out" | sed 's/^/      /' >&2
	url="$(printf '%s' "$out" | grep -oE "https://${name}\.[a-z0-9-]+\.workers\.dev" | head -1 || true)"
	printf '%s' "$url"
}

put_secret() { # $1 op title, $2 secret name, $3 config path
	local title="$1" name="$2" cfg="$3"
	if [ "$DRY_RUN" -eq 1 ]; then
		would_raw "op read $(shq "op://$VAULT/$title/password") | $(join_args "${WRANGLER[@]}") secret put $name -c $(shq "$cfg")"
		return 0
	fi
	# The value goes straight from op into wrangler over a pipe: never in argv,
	# never in a variable, never on disk. pipefail catches a failing op read.
	op read "op://$VAULT/$title/password" \
		| "${WRANGLER[@]}" secret put "$name" -c "$cfg" >/dev/null \
		|| die "failed to set $name from \"$title\""
	ok "secret $name set from \"$title\""
}

# ------------------------------------------------------------------ render ----

# Drops the /* */ header block and whole-line // comments. Both templates
# reduce to valid JSON this way, which the caller then checks with jq.
strip_jsonc() { # $1 file
	awk '
		{ line = $0 }
		inblock { if (line ~ /\*\//) { inblock = 0 } ; next }
		line ~ /^[[:space:]]*\/\*/ { if (line !~ /\*\//) inblock = 1 ; next }
		line ~ /^[[:space:]]*\/\// { next }
		{ print }
	' "$1"
}

assert_rendered_sane() { # $1 rendered file
	local f="$1" body hit
	body="$(strip_jsonc "$f")"
	hit="$(printf '%s\n' "$body" | grep -nE 'REPLACE_WITH_|<GROUP>|<SUBDOMAIN>' || true)"
	if [ -n "$hit" ]; then
		printf '%s\n' "$hit" >&2
		die "rendered config still holds placeholders: $f"
	fi
	# A botched substitution usually shows up as invalid JSON first.
	printf '%s\n' "$body" | jq empty >/dev/null 2>&1 \
		|| die "rendered config is not valid JSON once comments are stripped: $f"
}

assert_not_tracked() { # $1 destination path
	local dest="$1"
	git -C "$ROOT_DIR" check-ignore -q "$dest" \
		|| die "$dest is not gitignored — refusing to write deployment ids into a tracked file"
	# check-ignore alone would still pass for a file that is both ignored and
	# already tracked, which is exactly the case that would commit the ids.
	if git -C "$ROOT_DIR" ls-files --error-unmatch "$dest" >/dev/null 2>&1; then
		die "$dest is tracked by git — refusing to write deployment ids into it"
	fi
}

install_rendered() { # $1 temp file, $2 destination
	local tmp="$1" dest="$2"
	assert_not_tracked "$dest"
	if [ -f "$dest" ]; then
		if cmp -s "$tmp" "$dest"; then
			ok "$(basename "$dest") already up to date"
			return 0
		fi
		warn "$(basename "$dest") exists and differs:"
		diff -u "$dest" "$tmp" 2>/dev/null | sed 's/^/      /' >&2 || true
		if [ "$DRY_RUN" -eq 1 ]; then
			would_raw "write $dest"
			return 0
		fi
		confirm "Overwrite $(basename "$dest")?" || die "keeping the existing $dest — resolve it by hand and re-run"
	fi
	if [ "$DRY_RUN" -eq 1 ]; then
		would_raw "write $dest"
		return 0
	fi
	# "wrangler.<slug>.tmp.local.jsonc" — deliberately shaped to match the
	# wrangler.*.local.jsonc ignore glob, so a crash between write and rename
	# cannot strand deployment ids in a path git would pick up.
	local staged="${dest%.local.jsonc}.tmp.local.jsonc"
	assert_not_tracked "$staged"
	rm -f "$staged"   # a stranded one would be a half-written earlier attempt
	cat "$tmp" > "$staged" && chmod 600 "$staged" && mv -f "$staged" "$dest" \
		|| { rm -f "$staged"; die "failed to write $dest"; }
	ok "wrote $(basename "$dest")"
}

render_projector_config() { # $1 slug, $2 d1 id
	local slug="$1" d1="$2" tmp dest
	tmp="$(mktmp)"
	dest="$(proj_config "$slug")"
	sed -e "s|<GROUP>|$slug|g" \
		-e "s|REPLACE_WITH_THIS_GROUPS_D1_DATABASE_ID|$d1|g" \
		"$PROJ_TEMPLATE" > "$tmp"
	assert_rendered_sane "$tmp"
	grep -Fq "\"name\": \"$(proj_worker "$slug")\"" "$tmp" \
		|| die "rendered projector config does not name $(proj_worker "$slug")"
	grep -Fq "\"database_name\": \"$(d1_name "$slug")\"" "$tmp" \
		|| die "rendered projector config does not name $(d1_name "$slug")"
	grep -Fq "\"MCP_SERVER_NAME\": \"$(proj_worker "$slug")\"" "$tmp" \
		|| die "rendered projector config does not set MCP_SERVER_NAME for this group"
	assert_id_unshared "$slug" "$d1" "D1 database id"
	install_rendered "$tmp" "$dest"
}

render_hub_config() { # $1 slug, $2 kv id, $3 user id, $4 subdomain
	local slug="$1" kv="$2" uid="$3" sub="$4" tmp dest
	tmp="$(mktmp)"
	dest="$(hub_config "$slug")"
	sed -e "s|<GROUP>|$slug|g" \
		-e "s|<SUBDOMAIN>|$sub|g" \
		-e "s|REPLACE_WITH_YOUR_KV_NAMESPACE_ID|$kv|g" \
		-e "s|REPLACE_WITH_THIS_GROUPS_USER_ID|$uid|g" \
		"$HUB_TEMPLATE" > "$tmp"
	assert_rendered_sane "$tmp"
	grep -Fq "\"name\": \"$(hub_worker "$slug")\"" "$tmp" \
		|| die "rendered hub config does not name $(hub_worker "$slug")"
	# The copy-paste hazard: a hub pointed at another group's projector merges
	# both corpora into one D1, readable by either group's MCP_TOKEN.
	grep -Fq "\"service\": \"$(proj_worker "$slug")\"" "$tmp" \
		|| die "rendered hub config does not bind PROJECTOR to $(proj_worker "$slug")"
	grep -Fq "https://$(proj_worker "$slug").$sub.workers.dev/internal/project" "$tmp" \
		|| die "rendered hub config's INTERNAL_PROJECTOR_URL does not point at $(proj_worker "$slug")"
	grep -Fq "\"SYNC_STATIC_USER_ID\": \"$uid\"" "$tmp" \
		|| die "rendered hub config does not carry this group's user id"
	assert_id_unshared "$slug" "$kv" "KV namespace id"
	install_rendered "$tmp" "$dest"
}

# A resource id must never appear in another group's rendered config.
assert_id_unshared() { # $1 slug, $2 id, $3 label
	local slug="$1" id="$2" label="$3" f base
	[ -n "$id" ] || return 0
	case "$id" in DRY-RUN-*) return 0 ;; esac
	for f in "$HUB_DIR"/wrangler.*.local.jsonc "$PROJ_DIR"/wrangler.*.local.jsonc; do
		[ -f "$f" ] || continue
		base="$(basename "$f")"
		[ "$base" = "wrangler.$slug.local.jsonc" ] && continue
		# This group's own staged write-in-progress file (see install_rendered);
		# a crash can strand one, and it is not another group's config.
		[ "$base" = "wrangler.$slug.tmp.local.jsonc" ] && continue
		if grep -Fq "$id" "$f"; then
			die "$label $id already appears in $base — two groups cannot share it"
		fi
	done
}

# hub_url is RECORDED and probed; nothing on the Worker derives from it (no
# binding, no var), so choosing a value other than the deployed hostname is
# safe and changes only the note, the summary and the verify target.
#
# Precedence: --hub-url, then whatever is already recorded, then the hostname
# wrangler deployed to. The middle rule is the point — wrangler reports the
# workers.dev hostname, so without it a redeploy would overwrite a custom
# domain in the note on every run and quietly send every machine that connects
# afterwards to a host the operator had moved away from.
#
# Progress goes to stderr like every helper here, so the captured url is clean.
resolve_hub_url() { # $1 note title, $2 deployed url, $3 workers.dev default — echoes the url
	local recorded
	if [ -n "$HUB_URL_OVERRIDE" ]; then
		info "hub url from --hub-url (not the deployed hostname)" >&2
		printf '%s' "$HUB_URL_OVERRIDE"
		return 0
	fi
	recorded="$(op_note_field "$1" hub_url)"
	if [ -n "$recorded" ] && [ "$recorded" != "$2" ]; then
		warn "keeping the recorded hub url rather than the deployed hostname:" >&2
		info "    recorded  $recorded" >&2
		info "    deployed  $2" >&2
		info "    pass --hub-url to change it, or --hub-url \"$3\" to go back to workers.dev" >&2
		printf '%s' "$recorded"
		return 0
	fi
	printf '%s' "$2"
}

# ------------------------------------------------------------------ verify ----

# The bearer token reaches curl through a config on stdin, so it never appears
# in argv. printf is a shell builtin, so it spawns no process of its own.
verify_status() { # $1 slug, $2 hub url, $3 user id — echoes the http status
	local slug="$1" hub="$2" uid="$3" token code attempt=1
	while :; do
		# Read from op on EVERY attempt and clear it before the next one: the
		# token is never held across a wait. 1Password stays the only place it
		# lives, so a retry costs a read rather than keeping a secret warm in a
		# variable for half a minute.
		token="$(op read "op://$VAULT/$(title_sync_token "$slug")/password" | tr -d '\n\r')" \
			|| die "cannot read \"$(title_sync_token "$slug")\" from vault \"$VAULT\" — is the op session still valid? (\`op whoami\`)"
		code="$(printf 'url = "%s"\nheader = "Authorization: Bearer %s"\nheader = "X-User-Id: %s"\nheader = "X-Device-Id: %s"\n' \
			"$hub/v1/sync/status" "$token" "$uid" "$PROBE_DEVICE_ID" \
			| curl -sS --max-time 20 -o /dev/null -w '%{http_code}' -K - || true)"
		token=""
		code="$(normalize_http_code "$code")"
		case "$code" in
			404|000) ;;   # may be a route that is not live yet — fall through
			*) break ;;   # anything else is the hub's own answer, retry-proof
		esac
		[ "$attempt" -ge "$PROBE_RETRIES" ] && break
		# stderr, like every output helper, so the captured status stays clean.
		info "status $code — a workers.dev route created moments ago can still be propagating; retrying in ${PROBE_RETRY_WAIT}s (attempt $attempt/$PROBE_RETRIES)"
		sleep "$PROBE_RETRY_WAIT"
		attempt=$(( attempt + 1 ))
	done
	printf '%s' "$code"
}

verify_mcp() { # $1 projector url — echoes the http status of an unauthenticated /mcp
	local code
	code="$(curl -sS --max-time 20 -o /dev/null -w '%{http_code}' -X POST "$1/mcp" \
		-H 'Content-Type: application/json' -d '{}' 2>/dev/null || true)"
	printf '%s' "$(normalize_http_code "$code")"
}

# curl prints %{http_code} even when the transfer fails (as 000), so a
# fallback on the failure branch would concatenate into "000000".
normalize_http_code() { # $1 raw -w output
	case "$1" in
		[1-5][0-9][0-9]) printf '%s' "$1" ;;
		*) printf '000' ;;
	esac
}

explain_status() { # $1 code
	case "$1" in
		200) ok "hub reachable, projector wired, token accepted" ;;
		403) err "403 — the token does not own this user id; SYNC_STATIC_TOKEN and SYNC_STATIC_USER_ID belong to different groups" ;;
		401) err "401 — SYNC_STATIC_TOKEN on the hub differs from the 1Password value" ;;
		404) err "404 — nothing is serving /v1/sync/status after $(( PROBE_RETRIES * PROBE_RETRY_WAIT ))s of retries; the hub Worker did not deploy, or its workers.dev route is taking unusually long to propagate. The stack itself is already provisioned — re-run to re-verify rather than tearing down" ;;
		500) err "500 — the hub cannot reach its projector, or the Durable Objects daily quota is exhausted" ;;
		503) err "503 — the projector is behind; the projection checkpoint has not caught up to head_seq" ;;
		000) err "no response after $(( PROBE_RETRIES * PROBE_RETRY_WAIT ))s of retries — check the hub url and this machine's network access" ;;
		*)   err "unexpected status $1" ;;
	esac
}

# ------------------------------------------------------------------ canary ----

run_canary() { # $1 slug, $2 hub url, $3 user id
	# The caller has already established that bun exists and that the canary
	# was asked for, so a non-zero return from here means "did not converge".
	local slug="$1" hub="$2" uid="$3" token rc=0
	step "canary smoke test — group $slug"
	if [ "$DRY_RUN" -eq 1 ]; then
		would_raw "CANARY_TOKEN=<from op> bun $HUB_DIR/canary/canary.ts --cycles 3 --interval-ms 1000"
		return 1
	fi
	token="$(op read "op://$VAULT/$(title_sync_token "$slug")/password" | tr -d '\n\r')" \
		|| die "cannot read \"$(title_sync_token "$slug")\" from vault \"$VAULT\" — is the op session still valid? (\`op whoami\`)"
	# The token goes in the child's environment, not its argv, so it stays out
	# of `ps`. The canary exits non-zero if any bounded cycle fails to converge.
	set +e
	CANARY_HUB_URL="$hub" CANARY_USER_ID="$uid" CANARY_TOKEN="$token" \
		bun "$HUB_DIR/canary/canary.ts" --cycles 3 --interval-ms 1000 --timeout-ms 15000 2>&1 \
		| sed 's/^/      /' >&2
	rc=${PIPESTATUS[0]}
	set -e
	token=""
	if [ "$rc" -ne 0 ]; then
		err "canary did not converge (exit $rc)"
		return 1
	fi
	ok "canary converged over 3 cycles"
	return 0
}

reset_hub_log() { # $1 slug, $2 hub url, $3 user id, $4 "fresh" if the id is new
	# $4 must describe the IDENTITY, not the D1: the log lives in the Durable
	# Object addressed by the user id, so only a user id minted in this run is
	# guaranteed to have nothing behind it. A recreated D1 says nothing about it.
	local slug="$1" hub="$2" uid="$3" fresh="${4:-}" secret code reply
	# POST /internal/v1/sync/reset clears the ENTIRE ordered log for this user
	# id, not just the canary's ops. That is only safe before daily use.
	if [ "$fresh" != "fresh" ]; then
		warn "group \"$slug\" was not created by this run; resetting its hub log would discard every op every device has pushed"
		reply=""
		if [ -t 0 ]; then
			printf '    Reset the entire hub log for %s? (type RESET) ' "$slug" >&2
			IFS=$' \t\n' read -r reply || reply=""
		fi
		if [ "$reply" != "RESET" ]; then
			warn "left the hub log alone — the canary's ops remain in it"
			return 0
		fi
	fi
	secret="$(op read "op://$VAULT/$(title_proj_secret "$slug")/password" | tr -d '\n\r')" \
		|| die "cannot read \"$(title_proj_secret "$slug")\" from vault \"$VAULT\" — is the op session still valid? (\`op whoami\`)"
	# Body carries only the user id — no credential — so argv is fine here.
	code="$(printf 'header = "Authorization: Bearer %s"\n' "$secret" \
		| curl -sS --max-time 30 -o /dev/null -w '%{http_code}' \
			-X POST "$hub/internal/v1/sync/reset" \
			-H 'Content-Type: application/json' \
			-d "$(printf '{"protocol_version":1,"user_id":"%s"}' "$uid")" \
			-K - || true)"
	secret=""
	code="$(normalize_http_code "$code")"
	case "$code" in
		200|204) ok "hub log reset, canary ops cleared" ;;
		*) warn "hub reset returned $code — clear the canary ops before daily use" ;;
	esac
}

clean_canary_d1() { # $1 slug, $2 "fresh" when the database was created in this run
	local slug="$1" fresh="$2" db
	db="$(d1_name "$slug")"
	if [ "$fresh" != "fresh" ]; then
		warn "$db already existed before this run; its rows are not necessarily canary data"
		# Deliberately not honouring --yes: a blanket yes for prompts must never
		# amount to authorising a wipe of somebody's live corpus.
		local reply=""
		if [ -t 0 ]; then
			printf '    Delete every row from observations and entities in %s? (type DELETE) ' "$db" >&2
			IFS=$' \t\n' read -r reply || reply=""
		fi
		if [ "$reply" != "DELETE" ]; then
			warn "left $db as it is — the projector guards rows by entity_rev, so canary rows may linger"
			return 0
		fi
	fi
	"${WRANGLER[@]}" d1 execute "$db" --remote -y \
		--command "DELETE FROM observations; DELETE FROM entities;" >/dev/null \
		|| { warn "could not clear $db"; return 0; }
	ok "cleared the canary rows from $db"
}

# -------------------------------------------------------------------- list ----

list_groups() {
	local slug uid tmp any=0
	step "groups provisioned in vault \"$VAULT\""
	tmp="$(mktmp)"
	op_known_user_ids > "$tmp"
	while IFS=$'\t' read -r slug uid; do
		[ -n "$slug" ] || continue
		printf '%s\t%s\t%s\n' "$slug" "$uid" "$(op_note_field "$(title_note "$slug")" hub_url)"
		any=1
	done < "$tmp"
	[ "$any" -eq 1 ] || info "none"
}

# --------------------------------------------------------------- provision ----

# Parallel arrays, because bash 3.2 has no associative arrays.
RESULT_SLUGS=()
RESULT_STATES=()
RESULT_NOTES=()
RESULT_HUBS=()
RESULT_MCPS=()

# Each group runs in a subshell so that a fatal step kills only that group.
# A subshell cannot write the parent's arrays, so it reports through this file.
GROUP_RESULT_FILE=""

record_result() { # slug state note hub mcp
	[ -n "$GROUP_RESULT_FILE" ] || return 0
	printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" > "$GROUP_RESULT_FILE"
}

collect_result() { # slug — reads what the subshell recorded
	local slug="$1" line i
	line=""
	[ -s "$GROUP_RESULT_FILE" ] && line="$(head -1 "$GROUP_RESULT_FILE")"
	i=${#RESULT_SLUGS[@]}
	if [ -z "$line" ]; then
		RESULT_SLUGS[$i]="$slug"; RESULT_STATES[$i]="failed"
		RESULT_NOTES[$i]="see the log above"; RESULT_HUBS[$i]=""; RESULT_MCPS[$i]=""
		return 0
	fi
	RESULT_SLUGS[$i]="$(printf '%s' "$line" | cut -f1)"
	RESULT_STATES[$i]="$(printf '%s' "$line" | cut -f2)"
	RESULT_NOTES[$i]="$(printf '%s' "$line" | cut -f3)"
	RESULT_HUBS[$i]="$(printf '%s' "$line" | cut -f4)"
	RESULT_MCPS[$i]="$(printf '%s' "$line" | cut -f5)"
}

provision_group() { # $1 slug
	local slug="$1"
	local note_title d1_id kv_id user_id sub proj_url hub_url mcp_url
	local d1_fresh="" identity_fresh="" existing_uid cfg code state

	note_title="$(title_note "$slug")"
	op_items_refresh

	step "group \"$slug\""
	info "hub        $(hub_worker "$slug")"
	info "projector  $(proj_worker "$slug")"
	info "d1         $(d1_name "$slug")"
	info "kv         $(kv_name "$slug")"

	# --- verify-only is strictly read-only: it must not create the very items
	# --- it is supposed to be checking (a typo'd slug would otherwise mint a
	# --- ghost group, complete with a user id nothing was ever deployed under).
	if [ "$VERIFY_ONLY" -eq 1 ]; then
		op_item_exists "$note_title" \
			|| die "no 1Password record for group \"$slug\" in vault \"$VAULT\" — nothing to verify; run without --verify-only to provision it"
		user_id="$(op_note_field "$note_title" user_id)"
		[ -n "$user_id" ] || die "\"$note_title\" has no user_id field"
		validate_uuid "$user_id"
		hub_url="$(op_note_field "$note_title" hub_url)"
		[ -n "$hub_url" ] || die "no hub_url recorded for \"$slug\" — provision it first"
		validate_https_url "$hub_url"
		step "verifying group \"$slug\""
		code="$(verify_status "$slug" "$hub_url" "$user_id")"
		explain_status "$code"
		[ "$code" = "200" ] || return 1
		mcp_url="$(op_note_field "$note_title" mcp_url)"
		# It ends up in a `claude mcp add` line the summary invites you to paste
		# into a shell, so it gets the same scrutiny as hub_url.
		[ -z "$mcp_url" ] || validate_https_url "$mcp_url"
		record_result "$slug" verified "verify-only" "$hub_url" "$mcp_url"
		return 0
	fi

	# --- credentials, before anything is generated (idempotency hinges here) --
	op_ensure_password "$(title_sync_token "$slug")"  "$slug"
	op_ensure_password "$(title_proj_secret "$slug")" "$slug"
	op_ensure_password "$(title_mcp_token "$slug")"   "$slug"
	op_assert_secret_len "$(title_sync_token "$slug")"
	op_assert_secret_len "$(title_proj_secret "$slug")"
	op_assert_secret_len "$(title_mcp_token "$slug")"

	# --- the group's identity -----------------------------------------------
	# Read what is already deployed FIRST. If the note was lost but a rendered
	# hub config survives, the deployed user id is the truth: minting a fresh
	# one would point the stack at an empty Durable Object and orphan the log.
	cfg="$(hub_config "$slug")"
	existing_uid=""
	if [ -f "$cfg" ]; then
		existing_uid="$(sed -n 's/.*"SYNC_STATIC_USER_ID": "\([^"]*\)".*/\1/p' "$cfg" | head -1)"
		# A template copied by hand and never filled in is not a deployed stack.
		case "$existing_uid" in
			REPLACE_WITH_*|"<GROUP>"*)
				warn "$(basename "$cfg") is an unfilled template copy — ignoring it; this script renders its own"
				existing_uid=""
				;;
		esac
	fi

	if op_item_exists "$note_title"; then
		user_id="$(op_note_field "$note_title" user_id)"
		[ -n "$user_id" ] || die "\"$note_title\" exists but has no user_id field — fix it by hand; generating a new one would orphan the hub log"
		validate_uuid "$user_id"
		# Disagreement means the stack was reconfigured by hand. Guessing which
		# side is right could orphan the log, so stop instead of "correcting".
		if [ -n "$existing_uid" ] && [ "$existing_uid" != "$user_id" ]; then
			die "$(basename "$cfg") deploys user id $existing_uid but 1Password holds $user_id — reconcile them by hand before re-running"
		fi
		ok "reusing user id $user_id"
	elif [ -n "$existing_uid" ]; then
		validate_uuid "$existing_uid"
		user_id="$existing_uid"
		warn "no 1Password record for \"$slug\"; adopting the user id already deployed in $(basename "$cfg")"
		op_note_create "$slug" \
			"$OP_SECTION.user_id[text]=$user_id" \
			"$OP_SECTION.cloudflare_account_id[text]=$CF_ACCOUNT_ID" \
			"$OP_SECTION.worker_names[text]=$(hub_worker "$slug"), $(proj_worker "$slug")" \
			"$OP_SECTION.created_at[text]=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
		ok "adopted user id $user_id"
	else
		user_id="$(new_uuid)"
		validate_uuid "$user_id"
		op_note_create "$slug" \
			"$OP_SECTION.user_id[text]=$user_id" \
			"$OP_SECTION.cloudflare_account_id[text]=$CF_ACCOUNT_ID" \
			"$OP_SECTION.worker_names[text]=$(hub_worker "$slug"), $(proj_worker "$slug")" \
			"$OP_SECTION.created_at[text]=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
		identity_fresh="fresh"   # nothing has ever been pushed under this id
		ok "minted user id $user_id"
	fi
	assert_user_id_unique "$slug" "$user_id"

	# --- D1, then the projector (the hub binds to it by name) ---------------
	# Listed here rather than at the top of the group: --verify-only returns
	# above this point and has no business needing a wrangler login.
	d1_list_refresh
	kv_list_refresh
	d1_id="$(d1_id_for "$(d1_name "$slug")")"
	if [ -n "$d1_id" ]; then
		ok "reusing D1 $(d1_name "$slug") ($d1_id)"
	elif [ "$DRY_RUN" -eq 1 ]; then
		would "${WRANGLER[@]}" d1 create "$(d1_name "$slug")"
		d1_id="DRY-RUN-D1-ID-$slug"
	else
		"${WRANGLER[@]}" d1 create "$(d1_name "$slug")" >/dev/null \
			|| die "failed to create D1 $(d1_name "$slug")"
		d1_list_refresh
		d1_id="$(d1_id_for "$(d1_name "$slug")")"
		[ -n "$d1_id" ] || die "created D1 $(d1_name "$slug") but could not read its id back"
		d1_fresh="fresh"
		ok "created D1 $(d1_name "$slug") ($d1_id)"
	fi

	validate_d1_id "$d1_id"
	assert_id_unshared_in_notes "$slug" d1_database_id "$d1_id" "D1 database id"
	render_projector_config "$slug" "$d1_id"
	put_secret "$(title_proj_secret "$slug")" CMEM_INTERNAL_PROJECTOR_SECRET "$(proj_config "$slug")"
	put_secret "$(title_mcp_token "$slug")"   MCP_TOKEN                      "$(proj_config "$slug")"
	proj_url="$(deploy_worker "$(proj_config "$slug")" "$(proj_worker "$slug")")"
	if [ -z "$proj_url" ]; then
		warn "could not read the deployed url from wrangler's output"
		sub="$(ask_value "workers.dev subdomain for this account" "")"
		validate_subdomain "$sub"
		proj_url="https://$(proj_worker "$slug").$sub.workers.dev"
	else
		sub="$(printf '%s' "$proj_url" | sed -E 's#^https://[^.]+\.([^.]+)\.workers\.dev$#\1#')"
		validate_subdomain "$sub"
	fi
	ok "projector at $proj_url"

	# --- KV, then the hub ---------------------------------------------------
	kv_id="$(kv_id_for "$(kv_name "$slug")")"
	if [ -n "$kv_id" ]; then
		ok "reusing KV $(kv_name "$slug") ($kv_id)"
	elif [ "$DRY_RUN" -eq 1 ]; then
		would "${WRANGLER[@]}" kv namespace create "$(kv_name "$slug")"
		kv_id="DRY-RUN-KV-ID-$slug"
	else
		"${WRANGLER[@]}" kv namespace create "$(kv_name "$slug")" >/dev/null \
			|| die "failed to create KV $(kv_name "$slug")"
		kv_list_refresh
		kv_id="$(kv_id_for "$(kv_name "$slug")")"
		[ -n "$kv_id" ] || die "created KV $(kv_name "$slug") but could not read its id back"
		ok "created KV $(kv_name "$slug") ($kv_id)"
	fi

	validate_kv_id "$kv_id"
	assert_id_unshared_in_notes "$slug" kv_namespace_id "$kv_id" "KV namespace id"
	render_hub_config "$slug" "$kv_id" "$user_id" "$sub"
	put_secret "$(title_sync_token "$slug")"  SYNC_STATIC_TOKEN              "$(hub_config "$slug")"
	put_secret "$(title_proj_secret "$slug")" CMEM_INTERNAL_PROJECTOR_SECRET "$(hub_config "$slug")"
	local hub_default
	hub_url="$(deploy_worker "$(hub_config "$slug")" "$(hub_worker "$slug")")"
	hub_default="https://$(hub_worker "$slug").$sub.workers.dev"
	[ -n "$hub_url" ] || hub_url="$hub_default"
	hub_url="$(resolve_hub_url "$note_title" "$hub_url" "$hub_default")"
	# Validated HERE, not inside resolve_hub_url: a die() in a command
	# substitution kills only the subshell, so the check belongs in the caller
	# where it can actually stop the run. Covers the recorded value too, which
	# never passed through the command line.
	validate_https_url "$hub_url"
	ok "hub at $hub_url"

	mcp_url="$proj_url/mcp"

	op_note_set "$slug" \
		"$OP_SECTION.hub_url[text]=$hub_url" \
		"$OP_SECTION.projector_url[text]=$proj_url" \
		"$OP_SECTION.mcp_url[text]=$mcp_url" \
		"$OP_SECTION.d1_database_id[text]=$d1_id" \
		"$OP_SECTION.kv_namespace_id[text]=$kv_id" \
		"$OP_SECTION.cloudflare_account_id[text]=$CF_ACCOUNT_ID"
	ok "recorded the stack in \"$note_title\""

	# --- verify -------------------------------------------------------------
	if [ "$DRY_RUN" -eq 1 ]; then
		would_raw "curl -K - $hub_url/v1/sync/status   # expect 200"
		record_result "$slug" dry-run "nothing was changed" "$hub_url" "$mcp_url"
		return 0
	fi

	step "verifying group \"$slug\""
	code="$(verify_status "$slug" "$hub_url" "$user_id")"
	explain_status "$code"
	if [ "$code" != "200" ]; then
		record_result "$slug" failed "hub /v1/sync/status returned $code" "$hub_url" "$mcp_url"
		return 1
	fi
	code="$(verify_mcp "$proj_url")"
	case "$code" in
		401|403) ok "MCP endpoint rejects unauthenticated requests ($code)" ;;
		*)       warn "unauthenticated POST $mcp_url returned $code, expected 401" ;;
	esac
	state=verified

	# --- canary (writes real ops, so it runs before daily use) --------------
	local want_canary=0 note=""
	case "$CANARY" in
		yes) want_canary=1 ;;
		no)  want_canary=0 ;;
		ask)
			# Deliberately NOT honouring --yes: the canary writes real ops and the
			# cleanup that follows resets the group's whole log, so an unattended
			# re-run must never opt into it. Ask for it explicitly with --canary.
			if [ "$ASSUME_YES" -eq 1 ]; then
				info "skipping the canary (pass --canary to run it)"
			elif confirm "Run the canary smoke test for \"$slug\"? It writes real ops, then RESETS this group's entire hub log."; then
				want_canary=1
			fi
			;;
	esac
	# A canary needs bun. Missing bun means "not run", which is not a failure.
	if [ "$want_canary" -eq 1 ] && ! command -v bun >/dev/null 2>&1; then
		warn "bun is not installed — skipping the canary"
		want_canary=0
		note="canary skipped: bun not installed"
	fi
	if [ "$want_canary" -eq 1 ]; then
		if run_canary "$slug" "$hub_url" "$user_id"; then
			# The destructive cleanup is reachable only here, straight after a
			# canary run in this same invocation — and each half additionally
			# refuses to touch a stack that was not created by this run.
			reset_hub_log "$slug" "$hub_url" "$user_id" "$identity_fresh"
			clean_canary_d1 "$slug" "$d1_fresh"
		else
			state=canary-failed
			record_result "$slug" "$state" "deployed and verified, but the canary did not converge" "$hub_url" "$mcp_url"
			return 1
		fi
	fi

	record_result "$slug" "$state" "$note" "$hub_url" "$mcp_url"
	return 0
}

# -------------------------------------------------------------------- main ----

preflight() {
	step "preflight"
	local c
	for c in git jq curl sed grep; do
		command -v "$c" >/dev/null 2>&1 || die "missing required command: $c"
	done
	command -v op >/dev/null 2>&1 || die "missing required command: op (1Password CLI)"
	# --verify-only reads 1Password and curls the hub; it never calls wrangler,
	# so it must not require it to be installed either.
	if [ "$VERIFY_ONLY" -eq 0 ] && [ "$LIST_ONLY" -eq 0 ]; then
		command -v npx >/dev/null 2>&1 || die "missing required command: npx (for wrangler)"
	fi
	op_signed_in || die "1Password CLI is not signed in — run \`eval \$(op signin)\`, or pass --skip-op-check if op is authorized another way (biometric unlock, desktop app) and only \`op whoami\` is failing"
	if [ "$VERIFY_ONLY" -eq 0 ] && [ "$LIST_ONLY" -eq 0 ]; then
		command -v uuidgen >/dev/null 2>&1 || [ -r /proc/sys/kernel/random/uuid ] \
			|| die "no uuid source: install uuidgen (or provide /proc/sys/kernel/random/uuid)"
	fi
	[ -f "$HUB_TEMPLATE" ]  || die "missing template: $HUB_TEMPLATE"
	[ -f "$PROJ_TEMPLATE" ] || die "missing template: $PROJ_TEMPLATE"
	git -C "$ROOT_DIR" rev-parse --git-dir >/dev/null 2>&1 \
		|| die "$ROOT_DIR is not a git checkout; the gitignore assertion cannot run"
	if [ "$VERIFY_ONLY" -eq 1 ] || [ "$LIST_ONLY" -eq 1 ]; then
		ok "op $(op --version 2>/dev/null || true), jq $(jq --version 2>/dev/null || true)"
	else
		ok "op $(op --version 2>/dev/null || true), jq $(jq --version 2>/dev/null || true), wrangler $("${WRANGLER[@]}" --version 2>/dev/null | tail -1 || true)"
	fi
	command -v bun >/dev/null 2>&1 || warn "bun not found — the canary smoke test will be unavailable"
	[ "$DRY_RUN" -eq 1 ] && warn "dry run: nothing will be created, deployed or written"
	return 0
}

select_vault() {
	step "1Password vault"
	local vaults count
	vaults="$(op vault list --format=json | jq -r '.[].name')"
	[ -n "$vaults" ] || die "no 1Password vaults visible to this account"
	count="$(printf '%s\n' "$vaults" | grep -c . || true)"
	if [ -z "$VAULT" ]; then
		if [ "$count" -eq 1 ]; then
			VAULT="$vaults"
		elif [ "$ASSUME_YES" -eq 1 ]; then
			die "$count vaults are visible — name the one to use with --vault rather than letting an unattended run pick"
		else
			info "available: $(printf '%s' "$vaults" | tr '\n' ' ')"
			VAULT="$(ask_value "vault for the sync credentials" "$(printf '%s\n' "$vaults" | head -1)")"
		fi
	fi
	op vault get "$VAULT" >/dev/null 2>&1 || die "no such 1Password vault: \"$VAULT\""
	ok "using vault \"$VAULT\""
}

collect_groups() {
	local raw i j
	if [ ${#CMEM_GROUPS[@]} -eq 0 ]; then
		info "example: personal, work-corp-a, work-freelance"
		raw="$(ask_value "group slugs (comma or space separated)" "")"
		[ -n "$raw" ] || die "no groups given"
		add_groups "$raw"
	fi
	[ ${#CMEM_GROUPS[@]} -gt 0 ] || die "no groups given"
	for i in $(seq 0 $(( ${#CMEM_GROUPS[@]} - 1 ))); do
		validate_slug "${CMEM_GROUPS[$i]}"
		for j in $(seq 0 $(( ${#CMEM_GROUPS[@]} - 1 ))); do
			if [ "$i" -ne "$j" ] && [ "${CMEM_GROUPS[$i]}" = "${CMEM_GROUPS[$j]}" ]; then
				die "group \"${CMEM_GROUPS[$i]}\" is listed twice"
			fi
		done
	done
	step "groups"
	for i in $(seq 0 $(( ${#CMEM_GROUPS[@]} - 1 ))); do
		info "${CMEM_GROUPS[$i]}  →  $(hub_worker "${CMEM_GROUPS[$i]}") + $(proj_worker "${CMEM_GROUPS[$i]}")"
	done
	confirm "Provision ${#CMEM_GROUPS[@]} group(s)?" || die "aborted"
}

print_summary() {
	local i slug state note hub mcp failures=0
	printf '\n%s\n' "${C_BLD}Summary${C_RESET}" >&2
	[ ${#RESULT_SLUGS[@]} -gt 0 ] || { info "nothing to report"; return 0; }
	for i in $(seq 0 $(( ${#RESULT_SLUGS[@]} - 1 ))); do
		slug="${RESULT_SLUGS[$i]}"
		state="${RESULT_STATES[$i]}"
		note="${RESULT_NOTES[$i]}"
		hub="${RESULT_HUBS[$i]}"
		mcp="${RESULT_MCPS[$i]}"
		case "$state" in
			verified|dry-run) ok "$slug — $state${note:+ ($note)}" ;;
			*) err "$slug — $state${note:+ ($note)}"; failures=$(( failures + 1 )) ;;
		esac
		if [ -z "$hub" ]; then continue; fi
		cat >&2 <<SUM
        hub        $hub
        mcp        $mcp
        settings   CLAUDE_MEM_CLOUD_SYNC_HUB_URL=$hub
                   CLAUDE_MEM_CLOUD_SYNC_USER_ID=\$(op read "op://$VAULT/$(title_note "$slug")/$OP_SECTION/user_id")
                   CLAUDE_MEM_CLOUD_SYNC_TOKEN=\$(op read "op://$VAULT/$(title_sync_token "$slug")/password")
        mcp add    claude mcp add --transport http $(mcp_alias "$slug") $mcp \\
                     --header "Authorization: Bearer \$(op read 'op://$VAULT/$(title_mcp_token "$slug")/password')"
SUM
	done
	cat >&2 <<'NEXT'

Next, per machine: set the three CLAUDE_MEM_CLOUD_SYNC_* values above in
~/.claude-mem/settings.json (mode 0600, keep every unrelated setting), restart
the worker, and confirm /api/sync/status reports configured:true. Backfilling
pre-launch history is a separate, once-per-group step — see step 6 of
workers/self-host/SELF-HOSTING.md.
NEXT
	[ "$failures" -eq 0 ]
}

main() {
	# Checked here, not beside the flag parser: validate_https_url and die are
	# defined further down the file, so a parse-time call would hit an
	# undefined function instead of the check.
	if [ -n "$HUB_URL_OVERRIDE" ]; then
		validate_https_url "$HUB_URL_OVERRIDE"
		# One url cannot describe several hubs. Demanding exactly one group is
		# what stops --hub-url from stamping a single hostname onto every group
		# of a multi-group run and pointing them all at one another's data. It
		# also rules out the interactive prompt, where the count is not yet
		# known at this point.
		[ "${#CMEM_GROUPS[@]}" -eq 1 ] \
			|| die "--hub-url describes one hub, so it needs exactly one --group (got ${#CMEM_GROUPS[@]})"
	fi
	preflight
	select_vault
	if [ "$LIST_ONLY" -eq 1 ]; then
		list_groups
		return 0
	fi
	collect_groups
	CF_ACCOUNT_ID=""
	# --verify-only touches no Cloudflare resource — it reads 1Password and
	# curls the hub — so it has no business asking which account to deploy into.
	if [ "$VERIFY_ONLY" -eq 1 ]; then
		info "verify-only: skipping the Cloudflare account gate (nothing is deployed)"
	else
		cf_account_gate
	fi
	DRY_SUBDOMAIN="dry-run-subdomain"
	if [ "$DRY_RUN" -eq 1 ]; then
		DRY_SUBDOMAIN="$(ask_value "workers.dev subdomain to use for the dry run" "dry-run-subdomain")"
		validate_subdomain "$DRY_SUBDOMAIN"
	fi

	local i slug rc
	for i in $(seq 0 $(( ${#CMEM_GROUPS[@]} - 1 ))); do
		slug="${CMEM_GROUPS[$i]}"
		GROUP_RESULT_FILE="$(mktmp)"
		# errexit is disabled inside a command that heads a || list, so the
		# status is captured explicitly instead.
		set +e
		# `set -e` INSIDE the parens is load-bearing: a subshell inherits the
		# errexit state of the `set +e` above it, which would leave every `die`
		# fired inside a command substitution silently swallowed. Re-enabling it
		# here keeps each step fatal for the group while the parent loop carries
		# on to the next group.
		( set -e; provision_group "$slug" )
		rc=$?
		set -e
		[ "$rc" -ne 0 ] && err "group \"$slug\" did not complete (exit $rc)"
		collect_result "$slug"
	done

	print_summary
}

main "$@"
