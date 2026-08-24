#!/usr/bin/env bash
#
# teardown-sync-stack.sh — remove self-hosted claude-mem cloud sync stacks.
#
# The counterpart to deploy-sync-stack.sh. Per group it removes the hub Worker,
# the projector Worker, the D1 database, the KV namespace and the two rendered
# wrangler configs, then prints the 1Password commands for you to run by hand.
#
# PREVIEWS BY DEFAULT. Without --delete it lists what it found and exits having
# changed nothing. With --delete it still requires a typed confirmation word,
# which --yes deliberately cannot supply.
#
# Deleting sync-hub-<slug> destroys the Durable Object log for that group's user
# id. That log is the authoritative record of the group's memory: a projector's
# D1 is a rebuildable read model, the DO log is not. Nothing here is recoverable.
#
# Reads no secrets. 1Password is only ever read (item list, and the metadata
# note's non-secret fields) and never written: the commands that remove the now
# worthless credentials are printed on stdout for you to run.
#
#   ./scripts/teardown-sync-stack.sh --group personal              # preview
#   ./scripts/teardown-sync-stack.sh --all                         # preview all
#   ./scripts/teardown-sync-stack.sh --group personal --delete     # for real
#   ./scripts/teardown-sync-stack.sh --delete --group personal > cleanup.sh
#
# Requires: op (signed in, optional), jq, npx/wrangler (logged in), curl, git.

set -euo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

HUB_DIR="$ROOT_DIR/workers/sync-hub"
PROJ_DIR="$ROOT_DIR/workers/self-host"

SLUG_MAX=40
SETTINGS_FILE="$HOME/.claude-mem/settings.json"
STATUS_WAIT=15

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
skip() { local IFS=' '; printf '%s\n' "    ${C_DIM}·${C_RESET} $*" >&2; }
die()  { err "$*"; exit 1; }

# One manifest row, column-aligned. Everything the operator reads goes to
# stderr; stdout carries only the 1Password follow-up commands.
row() { printf '    %-10s %-50s %s\n' "$1" "$2" "$3" >&2; }

shq() { # shell-quote one argument so the printed commands are copy-pasteable
	[ -n "$1" ] || { printf "''"; return 0; }
	case "$1" in
		*[!A-Za-z0-9._/:@=,-]*) printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")" ;;
		*) printf '%s' "$1" ;;
	esac
}

# BSD seq counts DOWN when the end is below the start, so `seq 0 -1` emits
# "0" and "-1" rather than nothing, and an index loop over an empty array would
# read ${arr[0]} — fatal under set -u. Every index loop goes through this.
indices() { # $1 element count
	[ "$1" -gt 0 ] || return 0
	seq 0 $(( $1 - 1 ))
}

# One directory per run, removed by the parent's EXIT trap. mktmp is always
# called inside $( ), so a variable tracking individual paths would die with
# that subshell; removing the whole directory also covers the files the
# per-group subshells created.
TMP_DIR=""
cleanup() {
	[ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ] && rm -rf "$TMP_DIR"
	return 0
}
trap cleanup EXIT

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cmem-teardown.XXXXXX")" || {
	printf 'cannot create a temporary directory\n' >&2
	exit 1
}

mktmp() { mktemp "$TMP_DIR/f.XXXXXX"; }

# ------------------------------------------------------------------ flags ----

VAULT=""
CMEM_GROUPS=()
DISCOVER_ALL=0
ARMED=0
PURGE_OP=0
CLEAR_LOCAL=0
ASSUME_YES=0
SAW_DRY_RUN=0
SKIP_OP_CHECK=0
ALLOW_PARTIAL_SCAN=0
# Set once the typed word has been given, so a second mutating step in the same
# run does not ask again — and so a step reached without it still asks.
CONFIRMED=0

usage() {
	cat <<USAGE
$SCRIPT_NAME — remove self-hosted claude-mem cloud sync stacks.

Usage:
  $SCRIPT_NAME [options]

Previews by default: without --delete nothing is changed.

Options:
  --group SLUG            Tear down this group (repeatable).
  --groups a,b,c          Tear down these groups (comma or space separated).
  --all                   Discover every group in the account and the vault.
  --vault NAME            1Password vault to read (for discovery and metadata).
  --delete                Actually delete. Still asks for a typed confirmation.
  --purge-op              Print a hard \`op item delete\` instead of --archive.
  --clear-local-settings  Also clear this machine's CLAUDE_MEM_CLOUD_SYNC_*
                          settings, but only if they point at a group torn
                          down in this run; then restart the worker and
                          confirm /api/sync/status reports configured:false.
  --dry-run               Explicit no-op: the default is already a dry run.
  --yes                   Skip the "tear down N group(s)?" [y/N] prompt and
                          the vault prompt. It does NOT satisfy the typed
                          confirmation word, which has no bypass.
  --allow-partial-scan    With --all, proceed even though 1Password could not
                          be read. The discovered list then covers only the
                          Cloudflare account, so a group recorded solely in the
                          vault will be missed. Ignored without --all.
  --skip-op-check         Skip the \`op whoami\` check. Use when op is
                          authorized by biometric unlock or the desktop app
                          and whoami reports on a different (or deleted)
                          account. Without it a failing whoami silently drops
                          vault discovery and every 1Password item id.
  -h, --help              This message.

Per group this removes sync-hub-<slug>, cmem-self-host-<slug>,
cmem-memory-<slug>, sync-hub-<slug>-AUTH_CACHE and the two gitignored
wrangler.<slug>.local.jsonc configs. The group's four 1Password items are
never touched: the commands to remove them are printed on stdout.
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
		--all)                  DISCOVER_ALL=1; shift ;;
		--allow-partial-scan)   ALLOW_PARTIAL_SCAN=1; shift ;;
		--delete)               ARMED=1;        shift ;;
		--purge-op)             PURGE_OP=1;     shift ;;
		--clear-local-settings) CLEAR_LOCAL=1;  shift ;;
		--dry-run)              SAW_DRY_RUN=1;  shift ;;
		--skip-op-check)        SKIP_OP_CHECK=1; shift ;;
		--yes|-y)               ASSUME_YES=1;   shift ;;
		-h|--help)              usage; exit 0 ;;
		*) usage >&2; die "unknown option: $1" ;;
	esac
done

# Silently ignoring one of these would be the worst possible outcome, so a run
# that asks for both a dry run and a deletion is refused rather than resolved.
[ "$SAW_DRY_RUN" -eq 1 ] && [ "$ARMED" -eq 1 ] \
	&& die "--dry-run and --delete contradict each other — drop one"

[ "$DISCOVER_ALL" -eq 1 ] && [ ${#CMEM_GROUPS[@]} -gt 0 ] \
	&& die "--all discovers the group list; do not also pass --group/--groups"

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

# The last gate. --yes does not reach it and neither does a pipe: without a
# terminal there is no way to type the word, so an unattended run cannot delete.
require_typed_word() { # $1 what typing the word will do
	local reply IFS=$' \t\n'
	[ -t 0 ] || die "no terminal to confirm — refusing to change anything unattended"
	printf '    %s' "${C_BLD}Type \"delete\" (or \"approved\") to $1: ${C_RESET}" >&2
	read -r reply || reply=""
	case "$reply" in
		delete|DELETE|approved|APPROVED) return 0 ;;
		*) die "aborted — nothing was deleted" ;;
	esac
}

# ------------------------------------------------------------------ names ----

hub_worker()  { printf 'sync-hub-%s' "$1"; }
proj_worker() { printf 'cmem-self-host-%s' "$1"; }
d1_name()     { printf 'cmem-memory-%s' "$1"; }
kv_name()     { printf 'sync-hub-%s-AUTH_CACHE' "$1"; }
hub_config()  { printf '%s/wrangler.%s.local.jsonc' "$HUB_DIR" "$1"; }
proj_config() { printf '%s/wrangler.%s.local.jsonc' "$PROJ_DIR" "$1"; }

title_sync_token()  { printf 'claude-mem sync %s SYNC_STATIC_TOKEN' "$1"; }
title_proj_secret() { printf 'claude-mem sync %s CMEM_INTERNAL_PROJECTOR_SECRET' "$1"; }
title_mcp_token()   { printf 'claude-mem sync %s MCP_TOKEN' "$1"; }
title_note()        { printf 'claude-mem sync %s stack' "$1"; }

# Quiet predicate, for names discovered in the account: one unparseable
# resource must not abort a run that is otherwise about to do useful work.
slug_ok() {
	local s="$1" re='^[a-z0-9]([a-z0-9-]*[a-z0-9])?$'
	[ -n "$s" ] || return 1
	[ ${#s} -le $SLUG_MAX ] || return 1
	[[ $s =~ $re ]] || return 1
}

# Fatal, for a slug the operator typed: say exactly what is wrong with it.
validate_slug() {
	local s="$1"
	[ -n "$s" ] || die "empty group slug"
	case "$s" in
		*_*) die "group \"$s\": Cloudflare Worker names take alphanumerics and dashes only — use \"$(printf '%s' "$s" | tr '_' '-')\"" ;;
	esac
	if [ "$s" != "$(printf '%s' "$s" | tr 'A-Z' 'a-z')" ]; then
		die "group \"$s\": use lowercase — \"$(printf '%s' "$s" | tr 'A-Z' 'a-z')\""
	fi
	[ ${#s} -le $SLUG_MAX ] || die "group \"$s\": ${#s} characters exceeds the $SLUG_MAX limit"
	slug_ok "$s" || die "group \"$s\": must match ^[a-z0-9]([a-z0-9-]*[a-z0-9])?\$"
}

# --------------------------------------------------------------- 1Password ----

# op is optional: the Cloudflare side of a teardown does not need it. Without
# it the vault cannot be scanned, so discovery loses one of its three sources
# and the follow-up block prints titles to look for instead of item ids.
OP_OK=0
OP_ITEMS_JSON='[]'

# `op whoami` answers for the CURRENT auth method only. A service-account token
# in the environment makes it report on that account — and fail outright once
# the account is deleted or rate-limited — even when biometric/desktop-app
# unlock would authorize the reads this script actually performs. So the check
# is a convenience, not a capability test, and --skip-op-check turns it off.
op_signed_in() {
	[ "$SKIP_OP_CHECK" -eq 1 ] && return 0
	op whoami >/dev/null 2>&1
}

# A failed listing is NOT an empty vault: substituting '[]' would report every
# item absent and then claim there is nothing left to clean up.
op_items_refresh() {
	[ "$OP_OK" -eq 1 ] || return 0
	local out rc=0
	out="$(op item list --vault "$VAULT" --format=json 2>/dev/null)" || rc=$?
	if [ "$rc" -ne 0 ] || [ -z "$out" ] || ! printf '%s' "$out" | jq empty >/dev/null 2>&1; then
		warn "could not list vault \"$VAULT\" — treating 1Password as unavailable rather than empty"
		OP_OK=0
		OP_ITEMS_JSON='[]'
		return 0
	fi
	OP_ITEMS_JSON="$out"
}

# All ids carrying this exact title, newline separated. Two deploys of one slug
# can leave duplicate titles; every one of them is stale, so every one is
# reported. Ids are metadata, not credentials — the same class as a D1 id.
op_item_ids_for() { # $1 title
	printf '%s' "$OP_ITEMS_JSON" \
		| jq -r --arg t "$1" '.[] | select(.title == $t) | .id'
}

op_note_field() { # $1 item id, $2 label — empty when absent or unreadable
	[ "$OP_OK" -eq 1 ] || return 0
	op item get "$1" --vault "$VAULT" --format=json 2>/dev/null \
		| jq -r --arg f "$2" '[.fields[]? | select(.label == $f) | .value] | first // ""'
}

# ------------------------------------------------------------- cloudflare ----

# WRANGLER_BIN overrides the wrangler entrypoint. It must be ONE word — a path
# or a command name, not "npx wrangler".
if [ -n "${WRANGLER_BIN:-}" ]; then
	WRANGLER=("$WRANGLER_BIN")
else
	WRANGLER=(npx --yes wrangler)
fi

# wrangler occasionally prints an update banner alongside --json output.
json_only() { sed -n '/^[[{]/,$p'; }

# Listings are read once per run. Nothing deleted here changes another
# resource's listing — a Worker is not in the D1 list — so there is no cache to
# invalidate mid-run, and each resource is deleted at most once.
#
# Dies rather than returning empty: guessing which resources exist is not an
# option when the next step deletes them. Because `die` inside a command
# substitution exits only the subshell, every caller must append `|| exit 1`.
list_json() { # $1 label for the error message, then the wrangler subcommand
	local label="$1"; shift
	local tmp errf rc=0 out
	tmp="$(mktmp)"; errf="$(mktmp)"
	"${WRANGLER[@]}" "$@" > "$tmp" 2>"$errf" </dev/null || rc=$?
	if [ "$rc" -ne 0 ]; then
		sed 's/^/      /' < "$errf" >&2 || true
		die "could not list $label (exit $rc) — refusing to guess which of them exist"
	fi
	out="$(json_only < "$tmp")"
	if [ -z "$(printf '%s' "$out" | tr -d '[:space:]')" ]; then
		printf '[]'; return 0
	fi
	printf '%s' "$out" | jq empty >/dev/null 2>&1 \
		|| die "the $label listing was not JSON"
	printf '%s' "$out"
}

D1_LIST_JSON='[]'
KV_LIST_JSON='[]'

d1_id_for() { # $1 database name — uuid or empty
	printf '%s' "$D1_LIST_JSON" \
		| jq -r --arg n "$1" '[.[] | select(.name == $n) | .uuid] | first // ""'
}

kv_id_for() { # $1 namespace title — id or empty
	printf '%s' "$KV_LIST_JSON" \
		| jq -r --arg n "$1" '[.[] | select(.title == $n) | .id] | first // ""'
}

# wrangler has no "list all Workers" command, so existence is probed one name
# at a time. "present", "absent" or "unknown" — a transient API failure must
# never be read as absence, or the run would report a live Worker as already
# gone and skip deleting it.
worker_state() { # $1 worker name
	local out rc=0
	out="$("${WRANGLER[@]}" deployments list --name "$1" 2>&1 </dev/null)" || rc=$?
	if [ "$rc" -eq 0 ]; then printf 'present'; return 0; fi
	case "$out" in
		*"code: 10007"*|*"does not exist"*) printf 'absent'; return 0 ;;
	esac
	printf 'unknown'
}

# Best effort, and labelled as such in the manifest: a free-tier quota breach
# makes remote reads fail while the teardown itself is still perfectly valid.
# Two queries, because one SELECT over a missing table fails as a whole and a
# projector that never ran leaves the database with no tables at all.
d1_counts() { # $1 database name
	local name="$1" tables sel out rc=0
	out="$("${WRANGLER[@]}" d1 execute "$name" --remote --json </dev/null 2>/dev/null \
		--command "SELECT name FROM sqlite_master WHERE type='table' AND name IN ('observations','entities','session_summaries','user_prompts') ORDER BY name;")" || rc=$?
	if [ "$rc" -ne 0 ]; then printf 'row counts unavailable'; return 0; fi
	tables="$(printf '%s' "$out" | json_only | jq -r '[.[0].results[]?.name] | join(" ")' 2>/dev/null || true)"
	if [ -z "$tables" ]; then printf 'no tables — the projector never ran'; return 0; fi
	sel=""
	local t
	for t in $(printf '%s' "$tables" | tr ' ' '\n'); do
		sel="$sel${sel:+, }(SELECT count(*) FROM $t) AS $t"
	done
	rc=0
	out="$("${WRANGLER[@]}" d1 execute "$name" --remote --json </dev/null 2>/dev/null \
		--command "SELECT $sel;")" || rc=$?
	if [ "$rc" -ne 0 ]; then printf 'row counts unavailable'; return 0; fi
	printf '%s' "$out" | json_only \
		| jq -r '.[0].results[0] | to_entries | map("\(.value) \(.key)") | join(", ")' 2>/dev/null \
		|| printf 'row counts unavailable'
}

cf_account_gate() {
	local out name id ids n
	step "Cloudflare account"
	out="$("${WRANGLER[@]}" whoami 2>&1 </dev/null)" || die "wrangler whoami failed — run \`npx wrangler login\`"
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
	# Pin every later wrangler call to the account that was just resolved.
	export CLOUDFLARE_ACCOUNT_ID="$id"
	if [ "$ARMED" -eq 0 ]; then
		info "preview only — nothing in this account will be changed"
	elif [ -n "$CF_PINNED" ]; then
		ok "matches the pinned CLOUDFLARE_ACCOUNT_ID"
	else
		require_typed_yes "Delete resources from this account?"
	fi
}

# -------------------------------------------------------------- discovery ----

# Three sources, unioned, so a group whose vault note was lost is still found
# and a group whose Cloudflare resources are already half gone still resolves.
discover_slugs() {
	local tmp
	tmp="$(mktmp)"
	printf '%s' "$OP_ITEMS_JSON" \
		| jq -r '.[] | select(.title != null) | .title' \
		| sed -n 's/^claude-mem sync \(..*\) stack$/\1/p' >> "$tmp"
	printf '%s' "$D1_LIST_JSON" \
		| jq -r '.[] | select(.name != null) | .name' \
		| sed -n 's/^cmem-memory-\(..*\)$/\1/p' >> "$tmp"
	printf '%s' "$KV_LIST_JSON" \
		| jq -r '.[] | select(.title != null) | .title' \
		| sed -n 's/^sync-hub-\(..*\)-AUTH_CACHE$/\1/p' >> "$tmp"
	sort -u "$tmp" | grep -v '^$' || true
}

# The retired single-group naming carries no slug, so this script has no safe
# way to derive it and reports it for you to remove by hand instead.
report_unmanaged() { # returns 1 when it found nothing, so the caller says "none"
	local n any=0
	for n in cmem-memory; do
		if [ -n "$(d1_id_for "$n")" ]; then
			row "d1" "$n" "unmanaged — legacy name, remove by hand"; any=1
		fi
	done
	for n in sync-hub-AUTH_CACHE; do
		if [ -n "$(kv_id_for "$n")" ]; then
			row "kv" "$n" "unmanaged — legacy name, remove by hand"; any=1
		fi
	done
	for n in cmem-self-host sync-hub; do
		if [ "$(worker_state "$n")" = present ]; then
			row "worker" "$n" "unmanaged — legacy name, remove by hand"; any=1
		fi
	done
	[ "$any" -eq 1 ]
}

# --------------------------------------------------------------- manifest ----

# One tab-separated row per resource: kind, name, state, id, detail. Written
# once, before any gate, and then used as the execution plan — so what you
# confirmed is exactly what gets deleted, in the order it is listed.
mrow() { # $1 file, then kind name state id detail
	local f="$1"; shift
	printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" >> "$f"
}

config_state() { # $1 path — absent, gitignored or tracked
	[ -f "$1" ] || { printf 'absent'; return 0; }
	if ! git -C "$ROOT_DIR" check-ignore -q "$1" 2>/dev/null; then
		printf 'tracked'; return 0
	fi
	# check-ignore alone still passes for a file that is both ignored and
	# already tracked, which is exactly the file that must not be removed.
	if git -C "$ROOT_DIR" ls-files --error-unmatch "$1" >/dev/null 2>&1; then
		printf 'tracked'; return 0
	fi
	printf 'gitignored'
}

build_manifest() { # $1 slug
	local slug="$1" m meta hub proj d1 kv d1_id kv_id d1_state title id note_id
	m="$TMP_DIR/m.$slug"; : > "$m"
	meta="$TMP_DIR/meta.$slug"; : > "$meta"

	hub="$(hub_worker "$slug")"
	proj="$(proj_worker "$slug")"
	d1="$(d1_name "$slug")"
	kv="$(kv_name "$slug")"

	# Order is the execution order: the hub holds a PROJECTOR service binding,
	# so Cloudflare refuses to delete the projector while the hub still names
	# it. Deleting the hub first keeps --force out of this script entirely.
	mrow "$m" hub  "$hub"  "$(worker_state "$hub")"  "" ""
	mrow "$m" proj "$proj" "$(worker_state "$proj")" "" ""

	d1_id="$(d1_id_for "$d1")"
	if [ -n "$d1_id" ]; then
		mrow "$m" d1 "$d1" present "$d1_id" "$(d1_counts "$d1")"
	else
		mrow "$m" d1 "$d1" absent "" ""
	fi

	kv_id="$(kv_id_for "$kv")"
	if [ -n "$kv_id" ]; then
		mrow "$m" kv "$kv" present "$kv_id" ""
	else
		mrow "$m" kv "$kv" absent "" ""
	fi

	mrow "$m" config "$(hub_config "$slug")"  "$(config_state "$(hub_config "$slug")")"  "" ""
	mrow "$m" config "$(proj_config "$slug")" "$(config_state "$(proj_config "$slug")")" "" ""

	# 1Password rows are informational: nothing here deletes them.
	for title in "$(title_sync_token "$slug")" "$(title_proj_secret "$slug")" \
	             "$(title_mcp_token "$slug")" "$(title_note "$slug")"; do
		if [ "$OP_OK" -eq 0 ]; then
			mrow "$m" op "$title" unknown "" ""
			continue
		fi
		id=""
		for id in $(op_item_ids_for "$title"); do
			mrow "$m" op "$title" present "$id" ""
		done
		[ -n "$id" ] || mrow "$m" op "$title" absent "" ""
	done

	# The note's non-secret fields, for the manifest warning and for matching
	# this machine's settings. The hub url falls back to the rendered config,
	# whose INTERNAL_PROJECTOR_URL carries the workers.dev subdomain.
	note_id="$(printf '%s' "$OP_ITEMS_JSON" | jq -r --arg t "$(title_note "$slug")" \
		'[.[] | select(.title == $t) | .id] | first // ""')"
	local user_id="" hub_url=""
	if [ -n "$note_id" ]; then
		user_id="$(op_note_field "$note_id" user_id)"
		hub_url="$(op_note_field "$note_id" hub_url)"
	fi
	if [ -z "$hub_url" ] && [ -f "$(hub_config "$slug")" ]; then
		local sub
		sub="$(sed -n 's|.*"INTERNAL_PROJECTOR_URL"[[:space:]]*:[[:space:]]*"https://[^".]*\.\([a-z0-9-]*\)\.workers\.dev.*|\1|p' \
			"$(hub_config "$slug")" | head -1)"
		[ -n "$sub" ] && hub_url="https://$hub.$sub.workers.dev"
	fi
	printf '%s\t%s\n' "$user_id" "$hub_url" > "$meta"
}

print_manifest() { # $1 slug — returns 1 when the group has nothing at all
	local slug="$1" m kind name state id detail found=0 hub_present=0 user_id shown
	m="$TMP_DIR/m.$slug"
	step "group \"$slug\""
	while IFS=$'\t' read -r kind name state id detail; do
		[ -n "$kind" ] || continue
		# Config rows carry an absolute path so the delete step needs no
		# rebuilding; the manifest shows it relative to the checkout.
		shown="${name#"$ROOT_DIR"/}"
		case "$state" in
			present)
				found=1
				[ "$kind" = hub ] && hub_present=1
				if [ "$kind" = op ]; then
					row "$kind" "$shown" "kept — delete command printed at the end"
				else
					row "$kind" "$shown" "present${id:+  $id}${detail:+  ($detail)}"
				fi
				;;
			gitignored) found=1; row "$kind" "$shown" "present, gitignored" ;;
			tracked)    row "$kind" "$shown" "${C_YEL}present but TRACKED by git — will not be removed${C_RESET}" ;;
			unknown)    found=1; row "$kind" "$shown" "${C_YEL}state unknown${C_RESET}" ;;
			*)          skip "$(printf '%-10s %-50s absent' "$kind" "$shown")" ;;
		esac
	done < "$m"
	if [ "$hub_present" -eq 1 ]; then
		user_id="$(cut -f1 < "$TMP_DIR/meta.$slug")"
		warn "deleting $(hub_worker "$slug") destroys the Durable Object log${user_id:+ for user id $user_id}"
		info "    that log is the authoritative record of this group's memory — it is not recoverable"
	fi
	[ "$found" -eq 1 ] || info "nothing found for this group"
	[ "$found" -eq 1 ]
}

# --------------------------------------------------------------- execution ----

# The single place a deletion actually happens, so the progress line, the
# captured output and the failure accounting cannot drift between resources.
try_delete() { # $1 human label, then the command to run
	local label="$1"; shift
	local errf rc=0
	errf="$(mktmp)"
	"$@" > "$errf" 2>&1 </dev/null || rc=$?
	if [ "$rc" -eq 0 ]; then ok "deleted $label"; return 0; fi
	sed 's/^/      /' < "$errf" >&2 || true
	err "failed to delete $label (exit $rc)"
	return 1
}

delete_config() { # $1 path
	local path="$1"
	# Re-checked rather than trusted: the manifest classified this file a moment
	# ago, and a tracked file must never be removed by this script.
	if [ "$(config_state "$path")" = tracked ]; then
		err "refusing to remove ${path#"$ROOT_DIR"/} — it is tracked by git"
		return 1
	fi
	rm -f "$path" || { err "failed to remove $path"; return 1; }
	ok "removed ${path#"$ROOT_DIR"/}"
	return 0
}

teardown_group() { # $1 slug — runs in a subshell; reports through the result file
	local slug="$1" m kind name state id detail failures=0 acted=0 kept=0
	m="$TMP_DIR/m.$slug"
	step "tearing down \"$slug\""
	while IFS=$'\t' read -r kind name state id detail; do
		[ -n "$kind" ] || continue
		case "$kind" in
			hub|proj)
				case "$state" in
					# `wrangler delete` has no -y; with stdin closed it takes its
					# non-interactive path, so the typed word stays the only prompt.
					present) acted=1
						try_delete "worker $name" "${WRANGLER[@]}" delete "$name" \
							|| failures=$(( failures + 1 )) ;;
					unknown) err "$name: existence unknown, leaving it alone"; failures=$(( failures + 1 )) ;;
					*) skip "$name already gone" ;;
				esac
				;;
			d1)
				if [ "$state" = present ]; then
					acted=1
					try_delete "D1 database $name" "${WRANGLER[@]}" d1 delete "$name" -y \
						|| failures=$(( failures + 1 ))
				else
					skip "$name already gone"
				fi
				;;
			kv)
				if [ "$state" = present ]; then
					acted=1
					try_delete "KV namespace $name" \
						"${WRANGLER[@]}" kv namespace delete --namespace-id "$id" -y \
						|| failures=$(( failures + 1 ))
				else
					skip "$name already gone"
				fi
				;;
			config)
				case "$state" in
					gitignored) acted=1; delete_config "$name" || failures=$(( failures + 1 )) ;;
					# The manifest already said this file would not be removed,
					# so honouring that is not a failed step.
					tracked)
						warn "${name#"$ROOT_DIR"/} is tracked by git — left in place; untrack it and re-run"
						kept=$(( kept + 1 ))
						;;
					*) skip "${name#"$ROOT_DIR"/} already gone" ;;
				esac
				;;
			op) : ;;   # never deleted here; printed for you at the end
		esac
	done < "$m"
	local note=""
	[ "$kept" -gt 0 ] && note="$kept tracked config(s) left in place"
	if [ "$failures" -gt 0 ]; then
		record_result "$slug" partial "$failures step(s) failed${note:+, $note}"
	elif [ "$acted" -eq 1 ]; then
		record_result "$slug" deleted "$note"
	else
		record_result "$slug" nothing-to-do "${note:-already gone}"
	fi
	return 0
}

# ------------------------------------------------------- 1Password follow-up ----

# This script never mutates 1Password. It prints the commands that remove the
# now worthless items and leaves running them to you — which also keeps the
# only credential store out of the destructive path entirely.
#
# The commands are the script's ONLY stdout output, so
#   teardown-sync-stack.sh --delete --group personal > cleanup.sh
# captures exactly them. Everything else goes to stderr.
print_op_followup() {
	local i slug state m kind name s id detail flag lines count=0
	flag="--archive"
	[ "$PURGE_OP" -eq 1 ] && flag=""

	step "1Password follow-up"
	if [ "$OP_OK" -eq 0 ]; then
		warn "1Password was not readable, so the item ids are unknown"
		info "look for these titles by hand and archive them:"
		for i in $(indices ${#CMEM_GROUPS[@]}); do
			slug="${CMEM_GROUPS[$i]}"
			info "  $(title_sync_token "$slug")"
			info "  $(title_proj_secret "$slug")"
			info "  $(title_mcp_token "$slug")"
			info "  $(title_note "$slug")"
		done
		return 0
	fi

	lines="$(mktmp)"
	for i in $(indices ${#RESULT_SLUGS[@]}); do
		slug="${RESULT_SLUGS[$i]}"
		state="${RESULT_STATES[$i]}"
		# A stack that is still partly up still needs its credentials, so its
		# items are not stale and are not offered for deletion.
		case "$state" in
			partial|failed)
				warn "\"$slug\" is not fully removed — leaving its 1Password items out of the list"
				continue
				;;
		esac
		m="$TMP_DIR/m.$slug"
		[ -f "$m" ] || continue
		while IFS=$'\t' read -r kind name s id detail; do
			[ "$kind" = op ] || continue
			[ "$s" = present ] || continue
			# Titles are derived from a validated slug, so they hold nothing
			# that could break out of the trailing comment.
			printf 'op item delete %s --vault %s%s  # %s\n' \
				"$(shq "$id")" "$(shq "$VAULT")" "${flag:+ $flag}" "$name" >> "$lines"
			count=$(( count + 1 ))
		done < "$m"
	done

	if [ "$count" -eq 0 ]; then
		info "no stale 1Password items"
		return 0
	fi

	printf '\n' >&2
	if [ "$ARMED" -eq 1 ]; then
		info "$count item(s) below are now worthless — their Workers are gone."
		info "This script cannot remove them; run these yourself:"
		printf '# stale claude-mem sync credentials in 1Password vault %s\n' "$(vault_comment)"
		cat "$lines"
	else
		info "$count item(s) would be left behind, listed below."
		# Commented out on purpose. A preview describes a LIVE stack, so
		# `teardown-sync-stack.sh --group x > cleanup.sh` must not yield a file
		# that would archive the credentials of a group that still exists.
		info "They are printed inert — nothing has been deleted, so nothing is stale yet."
		printf '# PREVIEW ONLY — these stacks are still live and these credentials\n'
		printf '# are still in use. Re-run with --delete to get runnable commands.\n'
		sed 's|^|# |' "$lines"
	fi
	printf '\n' >&2
	return 0
}

# ---------------------------------------------------------- local settings ----

# Mirrors the port resolution in workers/self-host/SELF-HOSTING.md:
# CLAUDE_MEM_WORKER_PORT, else the value in settings.json (which may sit under
# an "env" object), else the per-uid default.
worker_port() {
	local p=""
	if [ -n "${CLAUDE_MEM_WORKER_PORT:-}" ]; then
		printf '%s' "$CLAUDE_MEM_WORKER_PORT"; return 0
	fi
	if [ -f "$SETTINGS_FILE" ]; then
		p="$(jq -r 'if (.env | type) == "object"
		            then (.env.CLAUDE_MEM_WORKER_PORT // .CLAUDE_MEM_WORKER_PORT)
		            else .CLAUDE_MEM_WORKER_PORT end // empty' "$SETTINGS_FILE" 2>/dev/null || true)"
	fi
	case "$p" in ''|*[!0-9]*) p="" ;; esac
	[ -n "$p" ] || p=$(( 37700 + $(id -u) % 100 ))
	printf '%s' "$p"
}

strip_slash() { printf '%s' "${1%/}"; }

# The vault name goes into a `#` comment on one line; a newline in it would put
# the remainder outside the comment, where a sourced cleanup.sh would run it.
vault_comment() { printf '%s' "$(shq "$VAULT")" | tr -d '\n\r'; }

# The four keys claude-mem's loader reads for cloud sync. Kept in one place so
# the rewrite and its verification cannot disagree about which keys move.
SYNC_KEYS_DEL='del(.CLAUDE_MEM_CLOUD_SYNC_TOKEN, .CLAUDE_MEM_CLOUD_SYNC_USER_ID, .CLAUDE_MEM_CLOUD_SYNC_HUB_URL, .CLAUDE_MEM_CLOUD_SYNC_DEVICE_ID)'

clear_local_settings() {
	local i slug current matched="" hub_url before after removed bak stage port url
	local sf="$SETTINGS_FILE" wrapped=false target
	step "local sync settings"
	if [ ! -f "$sf" ]; then
		info "no $sf — nothing to clear"
		return 0
	fi
	# rename() would replace a symlink with a regular file, leaving the real
	# file (token included) untouched and the two paths silently diverged.
	local hops=0
	while [ -L "$sf" ]; do
		hops=$(( hops + 1 ))
		[ "$hops" -le 8 ] || die "too many symlinks to resolve from $SETTINGS_FILE"
		target="$(readlink "$sf")"
		case "$target" in
			/*) sf="$target" ;;
			*)  sf="$(dirname "$sf")/$target" ;;
		esac
	done
	if [ "$hops" -gt 0 ]; then
		info "settings.json resolves through $hops symlink(s) to $sf"
		[ -f "$sf" ] || die "$SETTINGS_FILE resolves to $sf, which does not exist"
	fi
	# claude-mem's loader flattens a wrapping "env" object
	# (SettingsDefaultsManager.ts), and worker_port already honours that shape,
	# so the keys must be read and removed wherever they actually live.
	if jq -e '(.env | type) == "object"' "$sf" >/dev/null 2>&1; then
		wrapped=true
		info "settings are wrapped in an \"env\" object — editing inside it"
	fi
	current="$(jq -r --argjson w "$wrapped" \
		'(if $w then .env else . end) | .CLAUDE_MEM_CLOUD_SYNC_HUB_URL // ""' "$sf" 2>/dev/null || true)"
	if [ -z "$current" ]; then
		info "this machine is not configured for cloud sync — nothing to clear"
		return 0
	fi
	# Only ever clears settings pointing at a group torn down in THIS run: a
	# machine pointed at a surviving group must be left exactly as it is.
	for i in $(indices ${#RESULT_SLUGS[@]}); do
		case "${RESULT_STATES[$i]}" in partial|failed) continue ;; esac
		slug="${RESULT_SLUGS[$i]}"
		[ -f "$TMP_DIR/meta.$slug" ] || continue
		hub_url="$(cut -f2 < "$TMP_DIR/meta.$slug")"
		[ -n "$hub_url" ] || continue
		if [ "$(strip_slash "$hub_url")" = "$(strip_slash "$current")" ]; then
			matched="$slug"
			break
		fi
	done
	if [ -z "$matched" ]; then
		warn "settings point at $current, which is not a group torn down in this run — left untouched"
		return 0
	fi
	info "settings point at group \"$matched\" ($current)"
	if [ "$ARMED" -eq 0 ]; then
		info "preview: would clear the four CLAUDE_MEM_CLOUD_SYNC_* keys, restart the worker, and confirm configured:false"
		return 0
	fi

	# A mutation, so it answers to the same gates as the deletions. On the
	# "nothing to delete" path require_typed_word has not run yet, and it is
	# also what enforces the terminal requirement.
	[ "$CONFIRMED" -eq 1 ] || require_typed_word "clear this machine's sync settings"

	# jq before 1.7 parses numbers as doubles, so an integer beyond 2^53 comes
	# back rewritten — and the verification below is jq-normalised on both
	# sides, so it could not see that. Rather than guess from the jq version or
	# from where the number sits in the document, check whether THIS jq
	# round-trips THIS file's own long digit runs unchanged.
	if ! diff -q \
		<(grep -Eo '[0-9]{16,}' "$sf" | sort) \
		<(jq -c '.' "$sf" | grep -Eo '[0-9]{16,}' | sort) >/dev/null 2>&1; then
		die "this jq rewrites a large number in $sf and would lose digits — clear the four CLAUDE_MEM_CLOUD_SYNC_* keys by hand"
	fi

	bak="$sf.pre-teardown.$(date -u +%Y%m%dT%H%M%SZ).bak"
	# Not `cp -p`: preserving the source mode would leave a token-bearing
	# backup at 0644 until a later chmod. umask 077 makes it 0600 at creation.
	cp "$sf" "$bak" || die "could not back up $sf"
	chmod 600 "$bak" || die "could not restrict $bak to 0600"
	ok "backed up to $bak"

	before="$(jq --argjson w "$wrapped" '(if $w then .env else . end) | keys | length' "$sf")" \
		|| die "$sf is not valid JSON"
	# Staged in the target directory so the install is an atomic rename.
	stage="$sf.teardown.$$"
	jq --argjson w "$wrapped" "if \$w then (.env |= $SYNC_KEYS_DEL) else $SYNC_KEYS_DEL end" \
		"$sf" > "$stage" || { rm -f "$stage"; die "could not rewrite $sf"; }
	jq empty < "$stage" >/dev/null 2>&1 || { rm -f "$stage"; die "the rewritten settings are not valid JSON"; }
	after="$(jq --argjson w "$wrapped" '(if $w then .env else . end) | keys | length' "$stage")" \
		|| { rm -f "$stage"; die "cannot count keys in the rewritten settings"; }
	removed=$(( before - after ))
	[ "$removed" -ge 1 ] || { rm -f "$stage"; die "the rewrite removed no keys — refusing to install it"; }
	[ "$removed" -le 4 ] || { rm -f "$stage"; die "the rewrite removed $removed keys, expected at most 4"; }
	# Every surviving key must match the backup with the same four keys removed:
	# proof that nothing else changed (modulo jq canonicalisation, which the
	# big-number guard above keeps lossless).
	if ! diff -q \
		<(jq -S --argjson w "$wrapped" "if \$w then (.env |= $SYNC_KEYS_DEL) else $SYNC_KEYS_DEL end" "$bak") \
		<(jq -S '.' "$stage") >/dev/null 2>&1; then
		rm -f "$stage"
		die "the rewrite changed a setting other than the four sync keys — not installing it"
	fi
	chmod 600 "$stage" || { rm -f "$stage"; die "could not restrict the staged settings to 0600"; }
	mv "$stage" "$sf" || { rm -f "$stage"; die "could not install the rewritten settings"; }
	ok "cleared $removed sync key(s); $after settings preserved, mode 0600"

	port="$(worker_port)"
	url="http://127.0.0.1:$port"
	if ! curl -fsS -m 5 -X POST "$url/api/admin/restart" >/dev/null 2>&1; then
		info "the local worker is not answering on $url — nothing to disconnect"
		return 0
	fi
	ok "asked the worker to restart"
	local n cfg=""
	for n in $(seq 1 "$STATUS_WAIT"); do
		# The status endpoint is briefly unreachable during the restart, hence
		# the poll. `.configured` is a boolean, so tostring — `// empty` would
		# swallow false, which is the exact value being waited for.
		cfg="$(curl -fsS -m 5 "$url/api/sync/status" 2>/dev/null | jq -r '.configured | tostring' 2>/dev/null || true)"
		if [ "$cfg" = "false" ]; then
			ok "/api/sync/status reports configured:false — this machine is disconnected"
			return 0
		fi
		sleep 1
	done
	err "after ${STATUS_WAIT}s /api/sync/status still reports configured:${cfg:-unreachable}"
	return 1
}

# ------------------------------------------------------------------- main ----

# Parallel arrays, because bash 3.2 has no associative arrays.
RESULT_SLUGS=()
RESULT_STATES=()
RESULT_NOTES=()

# Each group runs in a subshell so a fatal step kills only that group. A
# subshell cannot write the parent's arrays, so it reports through this file.
GROUP_RESULT_FILE=""

record_result() { # slug state note
	[ -n "$GROUP_RESULT_FILE" ] || return 0
	printf '%s\t%s\t%s\n' "$1" "$2" "$3" > "$GROUP_RESULT_FILE"
}

collect_result() { # $1 slug, $2 fallback state
	local slug="$1" fallback="$2" line i
	line=""
	[ -s "$GROUP_RESULT_FILE" ] && line="$(head -1 "$GROUP_RESULT_FILE")"
	i=${#RESULT_SLUGS[@]}
	if [ -z "$line" ]; then
		RESULT_SLUGS[$i]="$slug"; RESULT_STATES[$i]="$fallback"; RESULT_NOTES[$i]="see the log above"
		return 0
	fi
	RESULT_SLUGS[$i]="$(printf '%s' "$line" | cut -f1)"
	RESULT_STATES[$i]="$(printf '%s' "$line" | cut -f2)"
	RESULT_NOTES[$i]="$(printf '%s' "$line" | cut -f3)"
}

preflight() {
	step "preflight"
	local c
	for c in git jq curl sed grep; do
		command -v "$c" >/dev/null 2>&1 || die "missing required command: $c"
	done
	command -v npx >/dev/null 2>&1 || [ -n "${WRANGLER_BIN:-}" ] \
		|| die "missing required command: npx (for wrangler)"
	git -C "$ROOT_DIR" rev-parse --git-dir >/dev/null 2>&1 \
		|| die "$ROOT_DIR is not a git checkout; the tracked-file check cannot run"
	# Unlike the other two scripts this is a SOFT gate: a failing whoami only
	# degrades discovery. That makes it worse to get wrong, not better — the
	# run silently loses vault discovery and every item id, and a teardown that
	# cannot see the 1Password records is exactly when you want them listed.
	# --skip-op-check therefore forces the capable path here too.
	if command -v op >/dev/null 2>&1 && op_signed_in; then
		OP_OK=1
	else
		warn "1Password is unavailable or not signed in — vault discovery and item ids will be skipped"
		if [ "$SKIP_OP_CHECK" -eq 0 ]; then
			info "    if op works by biometric unlock and only \`op whoami\` fails, pass --skip-op-check"
		fi
	fi
	ok "jq $(jq --version 2>/dev/null || true), wrangler $("${WRANGLER[@]}" --version 2>/dev/null </dev/null | tail -1 || true)"
	if [ "$ARMED" -eq 1 ]; then
		warn "armed with --delete: resources WILL be deleted after you confirm"
	else
		info "preview mode — pass --delete to actually remove anything"
	fi
	return 0
}

select_vault() {
	[ "$OP_OK" -eq 1 ] || return 0
	step "1Password vault"
	local vaults count
	vaults="$(op vault list --format=json 2>/dev/null | jq -r '.[].name')" || true
	if [ -z "$vaults" ]; then
		warn "no 1Password vaults visible — continuing without vault metadata"
		OP_OK=0
		return 0
	fi
	count="$(printf '%s\n' "$vaults" | grep -c . || true)"
	if [ -z "$VAULT" ]; then
		if [ "$count" -eq 1 ]; then
			VAULT="$vaults"
		elif [ "$ASSUME_YES" -eq 1 ] || [ ! -t 0 ]; then
			warn "$count vaults are visible — name one with --vault to include 1Password in this run"
			OP_OK=0
			return 0
		else
			info "available: $(printf '%s' "$vaults" | tr '\n' ' ')"
			VAULT="$(ask_value "vault holding the sync credentials" "$(printf '%s\n' "$vaults" | head -1)")"
		fi
	fi
	op vault get "$VAULT" >/dev/null 2>&1 || die "no such 1Password vault: \"$VAULT\""
	ok "using vault \"$VAULT\""
	op_items_refresh
	return 0
}

validate_given_groups() {
	local i
	[ ${#CMEM_GROUPS[@]} -gt 0 ] || return 0
	for i in $(indices ${#CMEM_GROUPS[@]}); do
		validate_slug "${CMEM_GROUPS[$i]}"
	done
	return 0
}

resolve_groups() {
	local i j found
	if [ "$DISCOVER_ALL" -eq 1 ]; then
		# --all exists to be exhaustive, and the vault is one of three discovery
		# sources. With 1Password unreadable the scan silently omits any group
		# whose Cloudflare resources are already gone — exactly the orphans a
		# cleanup run is looking for — while still presenting its output as
		# "the groups". It errs safe (it under-reports, so nothing unexpected
		# gets deleted) but leaves records behind, so refuse by default rather
		# than hand over a partial inventory that reads as complete.
		if [ "$OP_OK" -eq 0 ] && [ "$ALLOW_PARTIAL_SCAN" -eq 0 ]; then
			err "--all cannot be exhaustive: 1Password is unreadable, so vault discovery is off"
			info "    a group recorded only in the vault — Cloudflare resources already"
			info "    deleted — would not appear in this list"
			info "    fix the op session, or pass --skip-op-check if only \`op whoami\` fails,"
			info "    or pass --allow-partial-scan to accept an account-only scan"
			exit 1
		fi
		step "discovering groups"
		if [ "$OP_OK" -eq 0 ]; then
			warn "partial scan: the vault was not read, so this list may be incomplete"
		fi
		found="$(discover_slugs)"
		local s
		for s in $found; do
			if slug_ok "$s"; then
				CMEM_GROUPS[${#CMEM_GROUPS[@]}]="$s"
			else
				warn "ignoring \"$s\": not a usable group slug"
			fi
		done
		if [ ${#CMEM_GROUPS[@]} -eq 0 ]; then
			info "none"
		else
			info "found: $(IFS=' '; printf '%s' "${CMEM_GROUPS[*]}")"
		fi
	fi
	if [ ${#CMEM_GROUPS[@]} -eq 0 ]; then
		[ "$DISCOVER_ALL" -eq 1 ] && return 1
		info "example: --group personal, or --all to discover"
		local raw
		raw="$(ask_value "group slugs to tear down (comma or space separated)" "")"
		[ -n "$raw" ] || die "no groups given"
		add_groups "$raw"
	fi
	for i in $(indices ${#CMEM_GROUPS[@]}); do
		validate_slug "${CMEM_GROUPS[$i]}"
		for j in $(indices ${#CMEM_GROUPS[@]}); do
			if [ "$i" -ne "$j" ] && [ "${CMEM_GROUPS[$i]}" = "${CMEM_GROUPS[$j]}" ]; then
				die "group \"${CMEM_GROUPS[$i]}\" is listed twice"
			fi
		done
	done
	return 0
}

print_summary() {
	local i failures=0
	printf '\n%s\n' "${C_BLD}Summary${C_RESET}" >&2
	if [ ${#RESULT_SLUGS[@]} -eq 0 ]; then
		info "nothing to report"
		return 0
	fi
	for i in $(indices ${#RESULT_SLUGS[@]}); do
		case "${RESULT_STATES[$i]}" in
			deleted|nothing-to-do|preview)
				ok "${RESULT_SLUGS[$i]} — ${RESULT_STATES[$i]}${RESULT_NOTES[$i]:+ (${RESULT_NOTES[$i]})}" ;;
			*)
				err "${RESULT_SLUGS[$i]} — ${RESULT_STATES[$i]}${RESULT_NOTES[$i]:+ (${RESULT_NOTES[$i]})}"
				failures=$(( failures + 1 )) ;;
		esac
	done
	[ "$failures" -eq 0 ]
}

# Every group not handled by a subshell still needs a result row, or the
# 1Password follow-up would have nothing to iterate and would report "no stale
# items" for a group whose items are sitting right there.
mark_all() { # $1 state
	local i n
	for i in $(indices ${#CMEM_GROUPS[@]}); do
		n=${#RESULT_SLUGS[@]}
		RESULT_SLUGS[$n]="${CMEM_GROUPS[$i]}"
		RESULT_STATES[$n]="$1"
		RESULT_NOTES[$n]=""
	done
}

# One tail for every exit path, so the follow-up block, the settings step and
# the summary cannot drift between them.
EXIT_CODE=0
finish() {
	print_op_followup
	if [ "$CLEAR_LOCAL" -eq 1 ]; then
		clear_local_settings || EXIT_CODE=1
	fi
	print_summary || EXIT_CODE=1
	return 0
}

main() {
	# Rejected before any network call: a typo in --group should cost nothing.
	validate_given_groups
	preflight
	select_vault

	CF_PINNED="${CLOUDFLARE_ACCOUNT_ID:-}"
	cf_account_gate

	D1_LIST_JSON="$(list_json "D1 databases" d1 list --json)" || exit 1
	KV_LIST_JSON="$(list_json "KV namespaces" kv namespace list)" || exit 1

	resolve_groups || { info "nothing to tear down"; return 0; }

	local i slug any=0 rc
	step "what will be removed"
	info "${#CMEM_GROUPS[@]} group(s): $(IFS=' '; printf '%s' "${CMEM_GROUPS[*]}")"
	for i in $(indices ${#CMEM_GROUPS[@]}); do
		slug="${CMEM_GROUPS[$i]}"
		build_manifest "$slug"
		print_manifest "$slug" && any=1
	done
	if [ "$DISCOVER_ALL" -eq 1 ]; then
		step "unmanaged resources"
		report_unmanaged || info "none"
	fi

	if [ "$ARMED" -eq 0 ]; then
		step "preview complete"
		info "nothing was changed — re-run with --delete to remove the resources above"
		mark_all preview
		finish
		return 0
	fi

	if [ "$any" -eq 0 ]; then
		step "nothing to delete"
		info "every Cloudflare resource for the requested group(s) is already gone"
		mark_all nothing-to-do
		finish
		return 0
	fi

	step "confirm"
	# Checked before `confirm`, whose inherited "pass --yes" advice is a dead
	# end here: --yes clears the y/N prompt but never the typed word below.
	[ -t 0 ] || die "deleting requires a terminal — the typed confirmation has no bypass"
	confirm "Tear down ${#CMEM_GROUPS[@]} group(s)?" || die "aborted"
	warn "this permanently destroys the Durable Object log(s) listed above"
	require_typed_word "delete the resources above"
	CONFIRMED=1

	for i in $(indices ${#CMEM_GROUPS[@]}); do
		slug="${CMEM_GROUPS[$i]}"
		GROUP_RESULT_FILE="$(mktmp)"
		# errexit is disabled inside a command that heads a || list, so the
		# status is captured explicitly instead.
		set +e
		# `set -e` INSIDE the parens is load-bearing: a subshell inherits the
		# errexit state of the `set +e` above it, which would leave every die
		# fired inside a command substitution silently swallowed.
		( set -e; teardown_group "$slug" )
		rc=$?
		set -e
		[ "$rc" -ne 0 ] && err "group \"$slug\" did not complete (exit $rc)"
		collect_result "$slug" failed
	done

	finish
	return 0
}

main "$@"
exit "$EXIT_CODE"
