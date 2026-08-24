#!/usr/bin/env bash
#
# connect-sync-client.sh — point THIS machine at a self-hosted claude-mem
# cloud sync group, reading the group's credentials from 1Password.
#
# deploy-sync-stack.sh provisions a group and only *prints* the three settings
# a machine needs; teardown-sync-stack.sh *removes* them. Nothing wrote them,
# so connecting a machine meant hand-editing ~/.claude-mem/settings.json and
# remembering to restart. This does that edit atomically, then proves it took.
#
# The token never materialises here, because the preview IS the injection
# template: settings.json is rendered as JSON whose secret slots are literal
# op inject references and handed to `op inject`, so the value goes from
# 1Password straight into the 0600 file — never into a shell variable, never
# into argv, never into a log. The pre-write hub probe works the same way,
# through a curl -K config on stdin.
#
# Writes exactly three keys and never touches CLAUDE_MEM_CLOUD_SYNC_DEVICE_ID:
# entity ids are stableDocumentId(kind, deviceId, localId), so preserving the
# device id is what keeps a repoint's automatic re-push idempotent. Clearing it
# would upload every already-landed entity a second time under a new identity.
#
#   ./scripts/connect-sync-client.sh --group personal
#   ./scripts/connect-sync-client.sh --group personal --dry-run
#   ./scripts/connect-sync-client.sh --group personal-2 --repoint
#
# Requires: op (signed in), jq, curl. sqlite3 only for the repoint report and
# the backfill offer; bun only if you accept the backfill offer.

set -euo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# resolveDataDir() (src/shared/paths.ts) always reads settings.json from the
# DEFAULT directory and only then honours a CLAUDE_MEM_DATA_DIR redirect, so
# the settings path is fixed while the database path is not.
SETTINGS_FILE="$HOME/.claude-mem/settings.json"

OP_SECTION="stack"
SLUG_MAX=40
SECRET_MIN_LEN=32
STATUS_WAIT=20
RESTART_WAIT=20
SHUTDOWN_WAIT=15
PROBE_DEVICE_ID="connect-sync-client-probe"

# Connecting right after deploy-sync-stack.sh can reach a hub whose workers.dev
# route has not propagated yet, which the edge reports as 404 (no route) or 000
# (name does not resolve yet). Those two get retried; 401/403/500/503 are the
# hub's own answers and must fail immediately. Every attempt re-runs op inject,
# so the token is fetched fresh from 1Password and never held across a wait —
# the extra reads on this rare path are the point, not a cost to optimise away.
PROBE_RETRIES=6
PROBE_RETRY_WAIT=5
BACKFILL_SCRIPT="$ROOT_DIR/scripts/self-host-backfill.ts"

# ---------------------------------------------------------------- output ----

if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
	C_RESET=$'\033[0m'; C_BLD=$'\033[1m'
	C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_CYN=$'\033[36m'
else
	C_RESET=; C_BLD=; C_RED=; C_GRN=; C_YEL=; C_CYN=
fi

# local IFS: $* would otherwise join multiple arguments on a newline.
step() { local IFS=' '; printf '\n%s\n' "${C_BLD}${C_CYN}▸ $*${C_RESET}" >&2; }
info() { local IFS=' '; printf '%s\n' "    $*" >&2; }
ok()   { local IFS=' '; printf '%s\n' "    ${C_GRN}✓${C_RESET} $*" >&2; }
warn() { local IFS=' '; printf '%s\n' "    ${C_YEL}!${C_RESET} $*" >&2; }
err()  { local IFS=' '; printf '%s\n' "    ${C_RED}✗${C_RESET} $*" >&2; }
die()  { err "$*"; exit 1; }

# One count row of the repoint report, column-aligned.
row() { printf '    %9s  %s\n' "$1" "$2" >&2; }

shq() { # shell-quote one argument so the printed commands are copy-pasteable
	[ -n "$1" ] || { printf "''"; return 0; }
	case "$1" in
		*[!A-Za-z0-9._/:@=,-]*) printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")" ;;
		*) printf '%s' "$1" ;;
	esac
}

# TMP_DIR holds the rendered template and, on the already-connected path, the
# injected candidate used for the comparison — both token-bearing, both 0600
# under the umask above. STAGE_PATH is separate: the install has to be an
# atomic rename, so that one file lives in the target directory and the trap
# must be able to find it by name after a mid-write failure.
TMP_DIR=""
STAGE_PATH=""
cleanup() {
	[ -n "$STAGE_PATH" ] && [ -f "$STAGE_PATH" ] && rm -f "$STAGE_PATH"
	[ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ] && rm -rf "$TMP_DIR"
	return 0
}
trap cleanup EXIT

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cmem-connect.XXXXXX")" || {
	printf 'cannot create a temporary directory\n' >&2
	exit 1
}

# Loud once, for all four call sites: every one of them is a bare command
# substitution, so a failing mktemp (disk full, a tmp reaper removing TMP_DIR
# mid-run) would otherwise abort the run through errexit with no message. The
# die prints from the subshell before errexit kills the parent.
mktmp() { mktemp "$TMP_DIR/f.XXXXXX" || die "cannot create a temporary file under $TMP_DIR"; }

# ------------------------------------------------------------------ flags ----

VAULT=""
SLUG=""
REPOINT=0
DRY_RUN=0
ASSUME_YES=0
SKIP_OP_CHECK=0

usage() {
	cat <<USAGE
$SCRIPT_NAME — connect this machine to a self-hosted claude-mem sync group.

Usage:
  $SCRIPT_NAME [options]

Options:
  --group SLUG   Group to connect to. Prompted from the vault if omitted.
  --vault NAME   1Password vault holding the group's credentials.
  --repoint      Required to move an already-connected machine to a DIFFERENT
                 hub. Also asks you to type the new slug; --yes does not
                 satisfy that.
  --dry-run      Show the group's credential status and the settings preview,
                 then stop. Nothing is probed, written or restarted.
  --yes          Skip the [y/N] prompts and the vault prompt. It does NOT
                 satisfy the typed confirmations for --repoint or the backfill.
  --skip-op-check
                 Skip the \`op whoami\` preflight. Use when op is authorized by
                 biometric unlock or the desktop app and whoami reports on a
                 different (or deleted) account. The credential check still
                 proves every reference resolves before anything is written.
  -h, --help     This message.

Writes CLAUDE_MEM_CLOUD_SYNC_HUB_URL, _USER_ID and _TOKEN into
~/.claude-mem/settings.json (backed up first, installed by atomic rename,
mode 0600, every other setting proven byte-identical). Leaves
CLAUDE_MEM_CLOUD_SYNC_DEVICE_ID alone. Then restarts the worker and confirms
/api/sync/status reports configured:true AND hub.reachable:true.
USAGE
}

while [ $# -gt 0 ]; do
	case "$1" in
		--group)  [ $# -ge 2 ] || die "--group needs a value"; SLUG="$2";  shift 2 ;;
		--vault)  [ $# -ge 2 ] || die "--vault needs a value"; VAULT="$2"; shift 2 ;;
		--repoint)          REPOINT=1;    shift ;;
		--dry-run)          DRY_RUN=1;    shift ;;
		--skip-op-check)    SKIP_OP_CHECK=1; shift ;;
		--yes|-y)           ASSUME_YES=1; shift ;;
		-h|--help)          usage; exit 0 ;;
		*) usage >&2; die "unknown option: $1" ;;
	esac
done

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
	# Only --yes accepts the default. Merely LACKING a terminal must not: that
	# is how a cron, CI or agent run would otherwise silently pick a vault and
	# a group and then write install-wide settings with no human in the loop.
	if [ "$ASSUME_YES" -eq 1 ]; then
		[ -n "$2" ] || die "cannot answer \"$1\" from a default — pass it as a flag"
		printf '%s' "$2"; return 0
	fi
	[ -t 0 ] || die "no terminal to answer \"$1\" — pass it as a flag instead"
	printf '    %s' "$1" >&2
	[ -n "$2" ] && printf ' [%s]' "$2" >&2
	printf ': ' >&2
	read -r reply || reply=""
	printf '%s' "${reply:-$2}"
}

# No --yes bypass and no non-TTY path: this is the gate in front of the two
# operations that re-running the script cannot undo.
require_typed_word() { # $1 the exact word, $2 what typing it will do
	local reply IFS=$' \t\n'
	[ -t 0 ] || die "no terminal to confirm — refusing to $2 unattended"
	printf '    %s' "${C_BLD}Type \"$1\" to $2: ${C_RESET}" >&2
	read -r reply || reply=""
	[ "$reply" = "$1" ] || die "aborted — nothing was changed"
}

# The same prompt as require_typed_word, but soft: it returns non-zero instead
# of exiting. For a gate in front of an OPTIONAL extra step that follows work
# which already succeeded — where require_typed_word's "nothing was changed"
# would be a lie, and its exit 1 would mark a good run as failed.
ask_typed_word() { # $1 the exact word, $2 what typing it will do
	local reply IFS=$' \t\n'
	[ -t 0 ] || return 1
	printf '    %s' "${C_BLD}Type \"$1\" to $2: ${C_RESET}" >&2
	read -r reply || reply=""
	[ "$reply" = "$1" ]
}

# ------------------------------------------------------------------ names ----

title_sync_token() { printf 'claude-mem sync %s SYNC_STATIC_TOKEN' "$1"; }
title_note()       { printf 'claude-mem sync %s stack' "$1"; }

# The two secret references. Built in one place so the preview, the probe and
# the injected file can never disagree about which item is read.
#
# They address items by ID, not by title, and that is load bearing. `op read`
# and `op inject` resolve a title DIFFERENTLY: given a vault holding an
# archived item whose title matches an active one, op read returns the active
# item's value while op inject fails outright with "deleted or archived".
# Observed on a real vault where a re-provisioned group left archived
# same-titled items behind — the credential check (op read) passed and the
# write (op inject) then failed, after the backup had already been taken. An
# item id is unique and carries no archive ambiguity, and the cached listing
# this script already fetches carries every id, so this costs no extra op call.
ITEM_ID_TOKEN=""
ITEM_ID_NOTE=""

ref_token()   { ref_or_die "$ITEM_ID_TOKEN" "$(title_sync_token "$1")" "password"; }
ref_user_id() { ref_or_die "$ITEM_ID_NOTE"  "$(title_note "$1")" "$OP_SECTION/user_id"; }

# A reference built before check_credentials resolved the ids would read
# op://<vault>//password. This is the inner half of a two-part guard, and only
# the outer half can actually stop a run: every caller reaches these through a
# command substitution, where die exits the SUBSHELL and the caller carries on
# with an empty reference. So main() asserts both ids directly after the
# credential check, and this arm exists to name the cause if one ever slips
# past — render_template's "exactly two references" assertion then catches the
# malformed output in the main shell.
ref_or_die() { # $1 item id, $2 title (for the message), $3 field path
	[ -n "$1" ] \
		|| die "internal: the item id for \"$2\" was not resolved before building its reference"
	printf 'op://%s/%s/%s' "$VAULT" "$1" "$3"
}

is_uuid() {
	local re='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
	[[ $1 =~ $re ]]
}

# The url read back from 1Password reaches curl's -K config, where an embedded
# newline would inject further directives, and it lands in the settings JSON.
is_https_url() {
	local re='^https://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._~%/-]*)?$'
	[[ $1 =~ $re ]]
}

validate_slug() {
	local s="$1" re='^[a-z0-9]([a-z0-9-]*[a-z0-9])?$'
	[ -n "$s" ] || die "empty group slug"
	case "$s" in
		*_*) die "group \"$s\": Cloudflare Worker names take alphanumerics and dashes only — use \"$(printf '%s' "$s" | tr '_' '-')\"" ;;
	esac
	if [ "$s" != "$(printf '%s' "$s" | tr 'A-Z' 'a-z')" ]; then
		die "group \"$s\": use lowercase — \"$(printf '%s' "$s" | tr 'A-Z' 'a-z')\""
	fi
	[ ${#s} -le $SLUG_MAX ] || die "group \"$s\": ${#s} characters exceeds the $SLUG_MAX limit"
	[[ $s =~ $re ]] || die "group \"$s\": must match $re"
}

# The vault name lands inside a reference, which sits inside a curl -K config
# VALUE and inside the injection template. A double quote ends that value
# early; a newline injects a further directive. Every breakout I could build
# also breaks the mustache, so the injection fails closed — but the symptom
# would be a "check hub_url / check the network" diagnosis on every single run
# against that vault, which is reason enough to refuse it up front. The slug,
# the uuid and the hub url all got validators for exactly this reason; the
# vault was the one input that had none.
validate_vault_name() {
	local raw stripped
	[ -n "$1" ] || die "empty vault name"
	case "$1" in
		# The backslash pattern is deliberately UNQUOTED: a quoted '\\' in a case
		# pattern is the literal two-character string, so it would match only a
		# DOUBLE backslash and wave a single one straight through — the exact
		# case this validator exists to catch.
		*'"'*|*'{'*|*'}'*|*\\*|*'`'*|*'$'*)
			die "vault \"$1\" holds a character that cannot go into a secret reference (one of \" { } backslash backtick dollar) — pass the vault's ID with --vault instead, or rename it" ;;
	esac
	# Byte counts on both sides, so a multibyte name is not mistaken for one
	# carrying a newline.
	raw="$(printf '%s' "$1" | wc -c | tr -d ' ')"
	stripped="$(printf '%s' "$1" | tr -d '\n\r' | wc -c | tr -d ' ')"
	[ "$raw" = "$stripped" ] \
		|| die "the vault name holds a newline or carriage return — pass the vault's ID with --vault instead"
}

strip_slash() { printf '%s' "${1%/}"; }

# --------------------------------------------------------------- 1Password ----

select_vault() {
	step "1Password vault"
	local vaults count
	# Listed only when one is actually needed: a service-account token scoped
	# to a single vault's items can fail the listing outright while a direct
	# get on the named vault succeeds, so listing unconditionally would kill
	# runs that pass --vault and need nothing else from it.
	if [ -z "$VAULT" ]; then
		vaults="$(op vault list --format=json | jq -r '.[].name')" \
			|| die "cannot list 1Password vaults — the session may have expired (\`op whoami\`) or the client is rate-limited; pass --vault to skip the listing"
		[ -n "$vaults" ] || die "no 1Password vaults visible to this account — name one with --vault"
		count="$(printf '%s\n' "$vaults" | grep -c . || true)"
		if [ "$count" -eq 1 ]; then
			VAULT="$vaults"
		elif [ "$ASSUME_YES" -eq 1 ] || [ ! -t 0 ]; then
			die "$count vaults are visible — name the one to use with --vault rather than letting an unattended run pick"
		else
			info "available: $(printf '%s' "$vaults" | tr '\n' ' ')"
			VAULT="$(ask_value "vault holding the sync credentials" "$(printf '%s\n' "$vaults" | head -1)")"
		fi
	fi
	validate_vault_name "$VAULT"
	op vault get "$VAULT" >/dev/null 2>&1 || die "no such 1Password vault: \"$VAULT\""
	# Loaded here, at the top level: op_items_load must not run inside a
	# command substitution or the cache it fills would not outlive it.
	op_items_load
	ok "using vault \"$VAULT\" ($(jq 'length' "$OP_ITEMS_FILE") item(s))"
}

# The chosen vault's listing, cached in a FILE rather than a variable. Every
# caller reaches this through a command substitution, and a variable assigned
# inside one dies with that subshell — so a variable cache would silently re-run
# `op item list` on every single call. 1Password rate-limits bursts, so that is
# not merely slow: a handful of checks is enough to earn a "Too many requests"
# that fails the whole run.
OP_ITEMS_FILE=""
op_items_load() {
	OP_ITEMS_FILE="$TMP_DIR/items.json"
	# Not masked to "[]": a rate-limited or expired session would otherwise
	# read as "this vault holds no groups", which sends you looking in the
	# wrong place entirely.
	op item list --vault "$VAULT" --format=json > "$OP_ITEMS_FILE" 2>/dev/null \
		|| die "cannot list the items in vault \"$VAULT\" — the op session may have expired (\`op whoami\`), or the client is rate-limited (\"Too many requests\"), in which case wait a minute and re-run"
	jq -e 'type == "array"' "$OP_ITEMS_FILE" >/dev/null 2>&1 \
		|| die "the 1Password listing for vault \"$VAULT\" is not a JSON array"
}

op_items() { cat "$OP_ITEMS_FILE"; }

op_item_exists() { # $1 title
	local n
	n="$(op_items | jq --arg t "$1" '[.[] | select(.title == $t)] | length')" \
		|| die "cannot read the vault listing while looking for \"$1\""
	case "$n" in
		0) return 1 ;;
		1) return 0 ;;
		*) die "1Password has $n items titled \"$1\" in vault \"$VAULT\" — resolve the duplicate before re-running" ;;
	esac
}

# The id of the single active item with this title. op_item_exists has already
# proven there is exactly one, so a miss here means the listing changed under
# us rather than an ambiguity to report.
op_item_id() { # $1 title — echoes the id
	local id
	id="$(op_items | jq -r --arg t "$1" '[.[] | select(.title == $t) | .id] | first // ""')" \
		|| die "cannot read the vault listing while resolving the id of \"$1\""
	[ -n "$id" ] \
		|| die "\"$1\" vanished from the vault listing for \"$VAULT\" between checks — re-run"
	printf '%s' "$id"
}

# The note is fetched ONCE into a file and both fields are read from that. Two
# separate gets would double the traffic against a rate-limited API, but the
# real reason is that a per-field helper HIDES its own failure: `X="$(helper)"`
# is a plain assignment, so under errexit+pipefail a failing get exits the
# whole script printing nothing at all, and the caller's curated "that field is
# missing" branch can never run. Fetching once makes the failure reportable.
op_note_fetch() { # $1 title, $2 destination file — non-zero if it cannot be read
	op item get "$1" --vault "$VAULT" --format=json > "$2" 2>/dev/null
}

note_field() { # $1 note json file, $2 label — empty string when absent
	jq -r --arg f "$2" '[.fields[]? | select(.label == $f) | .value] | first // ""' "$1" 2>/dev/null || true
}

# Every group with a metadata note in this vault, as slugs, one per line. Same
# tag and title shape deploy-sync-stack.sh writes.
op_group_slugs() {
	op_items | jq -r '[.[] | select(.tags != null)
		| select((.tags | index("claude-mem")) and (.tags | index("sync-hub")))
		| select(.title | endswith(" stack"))
		| .title] | .[]' \
		| sed -n 's/^claude-mem sync \(.*\) stack$/\1/p' \
		| sort
}

# The pre-check MUST use the same resolver as the write, or it proves nothing.
# It used `op read`; the write uses `op inject`, and the two disagree about
# titles that also exist on an archived item (see ref_token above). So this
# renders a throwaway template through op inject — the exact mechanism that
# installs the settings file — and reports only what can be shown safely:
# the token's LENGTH and whether the injected user id equals the one read from
# the note.
#
# The secret goes op -> pipe -> jq and is never assigned and never written to
# disk; only the two references reach the template file. Returns non-zero when
# op inject failed (pipefail carries its status through), which is a DIFFERENT
# condition from resolving to an empty value — so call sites must capture the
# status rather than assign it bare. Assigning bare would also abort the whole
# run through errexit, with no message.
op_refs_probe() { # $1 user_id ref, $2 token ref, $3 expected user id
	# echoes "<token length> <yes|no user id matches>"
	local tpl
	tpl="$(mktmp)"
	printf '{"u":"{{ %s }}","t":"{{ %s }}"}\n' "$1" "$2" > "$tpl" \
		|| die "could not write the credential probe template"
	op inject -i "$tpl" 2>/dev/null | jq -r --arg expect "$3" '
		if (.u | type) == "string" and (.t | type) == "string"
		then "\(.t | length) \(if .u == $expect then "yes" else "no" end)"
		else empty end'
}

# -------------------------------------------------------------- settings ----

# The three keys this script owns. DEVICE_ID is deliberately absent: it stays
# whatever it already was. Kept in one place so the rewrite and the
# "nothing else changed" proof cannot disagree about which keys move.
SYNC_KEYS_DEL3='del(.CLAUDE_MEM_CLOUD_SYNC_HUB_URL, .CLAUDE_MEM_CLOUD_SYNC_USER_ID, .CLAUDE_MEM_CLOUD_SYNC_TOKEN)'

SETTINGS_REAL=""      # settings path with every symlink resolved
SETTINGS_WRAPPED=false

resolve_settings() {
	local sf="$SETTINGS_FILE" hops=0 target
	[ -f "$sf" ] || die "no $sf — install claude-mem before connecting it to a group"
	# rename() would replace a symlink with a regular file, leaving the real
	# file untouched and the two paths silently diverged.
	while [ -L "$sf" ]; do
		hops=$(( hops + 1 ))
		[ "$hops" -le 8 ] || die "too many symlinks to resolve from $SETTINGS_FILE"
		target="$(readlink "$sf")" || die "cannot resolve the symlink at $sf"
		case "$target" in
			/*) sf="$target" ;;
			*)  sf="$(dirname "$sf")/$target" ;;
		esac
	done
	if [ "$hops" -gt 0 ]; then
		info "settings.json resolves through $hops symlink(s) to $sf"
		[ -f "$sf" ] || die "$SETTINGS_FILE resolves to $sf, which does not exist"
	fi
	jq empty "$sf" >/dev/null 2>&1 || die "$sf is not valid JSON"
	# op inject substitutes every mustache pair in its input, so one that was
	# already in the file would be rewritten, or would abort the injection.
	# Checked here rather than at the write, because the already-connected path
	# injects too.
	if grep -Fq '{{' "$sf"; then
		die "$sf already contains a \"{{\" sequence, which op inject would try to substitute — set the three keys by hand instead"
	fi
	# claude-mem's loader reads a wrapped file by taking .env and rewriting the
	# file as that subtree alone (SettingsDefaultsManager.ts), so keys written
	# at the top level of a wrapped file would be invisible AND then dropped.
	if jq -e '(.env | type) == "object"' "$sf" >/dev/null 2>&1; then
		SETTINGS_WRAPPED=true
	fi
	SETTINGS_REAL="$sf"
}

settings_get() { # $1 key — empty string when absent
	jq -r --argjson w "$SETTINGS_WRAPPED" --arg k "$1" \
		'(if $w then .env else . end) | .[$k] // ""' "$SETTINGS_REAL" 2>/dev/null || true
}

# One place for the "read a key out of a settings-shaped file" jq, so the
# wrapper handling cannot drift between the checks below.
settings_get_from() { # $1 file, $2 key
	jq -r --argjson w "$SETTINGS_WRAPPED" --arg k "$2" \
		'(if $w then .env else . end) | .[$k] // ""' "$1"
}

settings_key_count() { # $1 file
	jq --argjson w "$SETTINGS_WRAPPED" '(if $w then .env else . end) | keys | length' "$1"
}

# Mirrors resolveDataDir() in src/shared/paths.ts: CLAUDE_MEM_DATA_DIR from the
# environment, else from settings.json, else the default. The database is what
# this resolves; the settings path itself is always the default one.
data_dir() {
	local d
	if [ -n "${CLAUDE_MEM_DATA_DIR:-}" ]; then d="$CLAUDE_MEM_DATA_DIR"
	else d="$(settings_get CLAUDE_MEM_DATA_DIR)"; fi
	[ -n "$d" ] || d="$HOME/.claude-mem"
	case "$d" in
		'~')   d="$HOME" ;;
		'~/'*) d="$HOME/${d#\~/}" ;;
	esac
	printf '%s' "$d"
}

# Mirrors the port resolution in workers/self-host/SELF-HOSTING.md:
# CLAUDE_MEM_WORKER_PORT, else the settings value, else the per-uid default.
worker_port() {
	local p=""
	if [ -n "${CLAUDE_MEM_WORKER_PORT:-}" ]; then
		printf '%s' "$CLAUDE_MEM_WORKER_PORT"; return 0
	fi
	p="$(settings_get CLAUDE_MEM_WORKER_PORT)"
	case "$p" in ''|*[!0-9]*) p="" ;; esac
	[ -n "$p" ] || p=$(( 37700 + $(id -u) % 100 ))
	printf '%s' "$p"
}

# --------------------------------------------------------------- template ----

# The settings file rendered with the two secret slots as literal op inject
# references. This exact text is what the preview describes and what op inject
# consumes — there is no second, value-bearing version of it.
render_template() { # $1 slug, $2 hub url, $3 destination path
	jq --arg h "$2" \
	   --arg u "{{ $(ref_user_id "$1") }}" \
	   --arg t "{{ $(ref_token "$1") }}" \
	   --argjson w "$SETTINGS_WRAPPED" '
		def put: .CLAUDE_MEM_CLOUD_SYNC_HUB_URL = $h
		       | .CLAUDE_MEM_CLOUD_SYNC_USER_ID = $u
		       | .CLAUDE_MEM_CLOUD_SYNC_TOKEN   = $t;
		if $w then (.env |= put) else put end
	' "$SETTINGS_REAL" > "$3" || die "could not render the settings template"
	# Two references in, two out: a jq that silently dropped one would
	# otherwise install a file with a literal mustache where a value belongs.
	[ "$(grep -c '{{ op' "$3" || true)" = "2" ] \
		|| die "the rendered template does not carry exactly two references — refusing to inject it"
}

# op inject exits 1 and writes ZERO bytes to stdout when a reference does not
# resolve, so a failure here can never leave a partially substituted file.
#
# `-i` is required, not a style choice: op inject rejects a plain file
# redirected onto stdin ("expected data on stdin but none found") and accepts
# only a pipe, so `op inject < file` fails every time. `-o` is the opposite —
# deliberately never used, because `op inject -o <existing file>` prints an
# error and still exits 0, silently doing nothing.
inject_template() { # $1 template path, $2 destination path
	op inject -i "$1" > "$2" || return 1
	[ -s "$2" ] || return 1
	jq empty "$2" >/dev/null 2>&1 || return 1
	# A leftover mustache means op inject left something unresolved.
	grep -Fq '{{' "$2" && return 1
	return 0
}

# `op whoami` answers for the CURRENT auth method only. A service-account token
# in the environment makes it report on that account — and fail outright once
# the account is deleted or rate-limited — even when biometric/desktop-app
# unlock would authorize the reads this script actually performs. So the check
# is a convenience, not a capability test, and --skip-op-check turns it off.
# Nothing is loosened by skipping it: the credential check still proves every
# reference resolves before a single byte is written.
op_signed_in() {
	[ "$SKIP_OP_CHECK" -eq 1 ] && return 0
	op whoami >/dev/null 2>&1
}

# ------------------------------------------------------------------ probe ----

# The bearer token reaches curl through a config on stdin that op inject
# renders, so it is never in argv and never on disk. printf is a builtin, so
# writing the template spawns no process of its own.
probe_hub() { # $1 slug, $2 hub url, $3 user id — echoes the http status
	local tpl code
	tpl="$(mktmp)"
	printf 'url = "%s"\nheader = "Authorization: Bearer {{ %s }}"\nheader = "X-User-Id: %s"\nheader = "X-Device-Id: %s"\n' \
		"$2/v1/sync/status" "$(ref_token "$1")" "$3" "$PROBE_DEVICE_ID" > "$tpl" \
		|| die "could not write the probe config"
	# check_credentials has already proven this reference resolves, so a failure
	# in the op half shows up as curl seeing no config and reporting 000.
	local attempt=1
	while :; do
		code="$(op inject -i "$tpl" \
			| curl -sS --max-time 20 -o /dev/null -w '%{http_code}' -K - 2>/dev/null || true)"
		code="$(normalize_http_code "$code")"
		case "$code" in
			404|000) ;;   # may be a route that is not live yet — fall through
			*) break ;;   # anything else is the hub's own answer, retry-proof
		esac
		[ "$attempt" -ge "$PROBE_RETRIES" ] && break
		# stderr, like every output helper, so the captured status stays clean.
		info "status $code — a hub deployed moments ago can still be propagating its route; retrying in ${PROBE_RETRY_WAIT}s (attempt $attempt/$PROBE_RETRIES)"
		sleep "$PROBE_RETRY_WAIT"
		attempt=$(( attempt + 1 ))
	done
	printf '%s' "$code"
}

# curl prints %{http_code} even when the transfer fails (as 000), so a
# fallback on the failure branch would concatenate into "000000".
normalize_http_code() { # $1 raw -w output
	case "$1" in
		[1-5][0-9][0-9]) printf '%s' "$1" ;;
		*) printf '000' ;;
	esac
}

explain_probe() { # $1 code, $2 slug
	case "$1" in
		200) ok "hub answered 200 — the token owns this user id and the projector is caught up" ;;
		401) err "401 — the hub's SYNC_STATIC_TOKEN differs from \"$(title_sync_token "$2")\" in vault \"$VAULT\"; re-running deploy-sync-stack.sh --group $2 pushes the vault value" ;;
		403) err "403 — the token is valid but does not own this user id; the note's user_id and the hub's SYNC_STATIC_USER_ID belong to different groups" ;;
		404) err "404 — nothing is serving /v1/sync/status there after $(( PROBE_RETRIES * PROBE_RETRY_WAIT ))s of retries; the hub Worker for \"$2\" is not deployed, hub_url in the note is stale, or the route is taking unusually long to propagate" ;;
		500) err "500 — the hub cannot reach its projector, or the Durable Objects daily quota is exhausted" ;;
		503) err "503 — the projector is behind head_seq: deployed, but not caught up, so pushes would be refused. The credentials are fine; re-run once it catches up" ;;
		000) err "no response — check hub_url in \"$(title_note "$2")\", and that this machine has network access" ;;
		*)   err "unexpected status $1 from the hub" ;;
	esac
}

# ------------------------------------------------------- repoint accounting ----

DB_FILE=""

resolve_db() {
	[ -n "$DB_FILE" ] && return 0
	DB_FILE="$(data_dir)/claude-mem.db"
	return 0
}

count_sql() { # $1 sql returning one integer — 0 when it cannot be read
	local n
	n="$(sqlite3 -readonly "$DB_FILE" "$1" 2>/dev/null || printf '')"
	case "$n" in ''|*[!0-9]*) printf '0'; return 1 ;; esac
	printf '%s' "$n"
}

count_over_tables() { # $1 where clause — total across the three synced tables
	local t n total=0
	for t in observations session_summaries user_prompts; do
		n="$(count_sql "SELECT COUNT(*) FROM $t WHERE $1;")" || true
		total=$(( total + n ))
	done
	printf '%s' "$total"
}

# The eligibility predicate from SyncApply.handleEpoch, as a count. The one-time
# v47 launch baseline is excluded through the exact revision recorded, so a
# later edit (a higher revision) still counts as re-pushable.
count_requeueable() {
	local t kind n total=0
	for t in observations session_summaries user_prompts; do
		case "$t" in
			observations)      kind=observation ;;
			session_summaries) kind=summary ;;
			*)                 kind=prompt ;;
		esac
		n="$(count_sql "SELECT COUNT(*) FROM $t
			WHERE synced_at > 0 AND origin_device_id IS NULL
			  AND NOT EXISTS (SELECT 1 FROM sync_launch_exclusions AS l
			     WHERE l.kind = '$kind'
			       AND l.origin_local_id = CAST($t.id AS TEXT)
			       AND (LENGTH(l.through_rev) > LENGTH(CAST($t.sync_rev AS TEXT))
			         OR (LENGTH(l.through_rev) = LENGTH(CAST($t.sync_rev AS TEXT))
			             AND l.through_rev >= CAST($t.sync_rev AS TEXT))));")" \
			|| warn "cannot count re-pushable rows in $t — the total below is short by that table"
		total=$(( total + n ))
	done
	printf '%s' "$total"
}

# What a repoint costs, read-only. Every number here is a consequence of
# SyncApply.handleEpoch(): a new hub reports a different epoch, the cursor
# resets to 0, and eligible NATIVE rows are re-nulled for a full re-push.
# Replica rows are filtered out by both requeue paths, so they are stranded.
repoint_report() {
	local requeue pending stuck replicas excl outbox tomb dead
	resolve_db
	if ! command -v sqlite3 >/dev/null 2>&1; then
		warn "sqlite3 not found — cannot report what this repoint moves; the numbers would have come from $DB_FILE"
		return 0
	fi
	if [ ! -f "$DB_FILE" ]; then
		warn "no database at $DB_FILE — there is no local history to re-push"
		return 0
	fi
	requeue="$(count_requeueable)"
	pending="$(count_over_tables 'synced_at IS NULL AND origin_device_id IS NULL')"
	stuck="$(count_over_tables 'synced_at IS NOT NULL AND synced_at <= 0 AND origin_device_id IS NULL')"
	replicas="$(count_over_tables 'origin_device_id IS NOT NULL')"
	excl="$(count_sql 'SELECT COUNT(*) FROM sync_launch_exclusions;')" || true
	outbox="$(count_sql 'SELECT COUNT(*) FROM sync_outbox;')" || true
	tomb="$(count_sql 'SELECT COUNT(*) FROM sync_content_outbox WHERE deleted = 1;')" || true
	dead="$(count_sql 'SELECT COUNT(*) FROM sync_dead_letter;')" || true

	info "what moves, from $DB_FILE:"
	row "$requeue" "native rows re-push automatically, once the new hub's epoch differs"
	row "$pending" "rows already pending — they drain to whichever hub is configured"
	row "$outbox" "queued mutations (edits, deletes) — they follow the new hub too"
	row "$tomb" "queued content tombstones — the same"
	row "$replicas" "replica rows from other devices — permanently STRANDED, never re-pushed"
	row "$stuck" "quarantined rows — these will not re-push either"
	row "$excl" "launch exclusions — pre-launch history, held back unless you backfill"
	if [ "$dead" -gt 0 ]; then
		row "$dead" "rows in the dead-letter table"
	fi
	warn "the $replicas replica row(s) are the irreversible part: this device can never"
	info "    push another device's entities, so that history reaches the new group only if"
	info "    the device that owns it also connects there. Nothing is deleted locally."
	return 0
}

# --------------------------------------------------------------- the write ----

write_settings() { # $1 slug, $2 hub url, $3 user id
	local slug="$1" hub="$2" uid="$3" sf="$SETTINGS_REAL" tpl bak before after len got_uid got_hub
	step "writing $sf"

	# jq before 1.7 parses numbers as doubles, so an integer beyond 2^53 comes
	# back rewritten — and the verification below is jq-normalised on both
	# sides, so it could not see that. Rather than guess from the jq version,
	# check whether THIS jq round-trips THIS file's own long digit runs.
	if ! diff -q \
		<(grep -Eo '[0-9]{16,}' "$sf" | sort) \
		<(jq -c '.' "$sf" | grep -Eo '[0-9]{16,}' | sort) >/dev/null 2>&1; then
		die "this jq rewrites a large number in $sf and would lose digits — set the three CLAUDE_MEM_CLOUD_SYNC_* keys by hand"
	fi

	bak="$sf.pre-connect.$(date -u +%Y%m%dT%H%M%SZ).bak"
	# Not `cp -p`: preserving the source mode would leave a token-bearing
	# backup at 0644 until a later chmod. umask 077 makes it 0600 at creation.
	cp "$sf" "$bak" || die "could not back up $sf"
	chmod 600 "$bak" || die "could not restrict $bak to 0600"
	ok "backed up to $bak"

	tpl="$(mktmp)"
	render_template "$slug" "$hub" "$tpl"

	# Staged in the target directory so the install is an atomic rename, and
	# recorded in STAGE_PATH before it is created so no failure below can
	# strand a token-bearing file.
	STAGE_PATH="$sf.connect.$$"
	rm -f "$STAGE_PATH"
	inject_template "$tpl" "$STAGE_PATH" \
		|| die "op inject failed — a reference did not resolve. $sf is unchanged; the backup is at $bak"
	chmod 600 "$STAGE_PATH" || die "could not restrict the staged settings to 0600"

	before="$(settings_key_count "$bak")" || die "cannot count keys in $bak"
	after="$(settings_key_count "$STAGE_PATH")" || die "cannot count keys in the staged settings"
	[ "$after" -ge "$before" ] || die "the rewrite dropped $(( before - after )) key(s) — not installing it"
	[ $(( after - before )) -le 3 ] || die "the rewrite added $(( after - before )) keys, expected at most 3 — not installing it"

	# Length only, never the value: the token is read out of the staged file
	# straight into a pipe, so it is never assigned to anything.
	len="$(settings_get_from "$STAGE_PATH" CLAUDE_MEM_CLOUD_SYNC_TOKEN | tr -d '\n\r' | wc -c | tr -d ' ')" \
		|| die "cannot read the injected token back out of the staged file — not installing it"
	case "$len" in ''|*[!0-9]*) die "cannot measure the injected token — not installing the file" ;; esac
	[ "$len" -ge "$SECRET_MIN_LEN" ] \
		|| die "the injected token is $len characters, expected at least $SECRET_MIN_LEN — not installing the file"
	ok "token injected, $len characters (never printed, never in a variable)"

	# These two are metadata, so they are checked by value. Comparing the
	# injected user id against the note also proves the sectioned reference
	# resolved to the field it names rather than to something else.
	got_uid="$(settings_get_from "$STAGE_PATH" CLAUDE_MEM_CLOUD_SYNC_USER_ID)" \
		|| die "cannot read the injected user id back out of the staged file — not installing it"
	got_hub="$(settings_get_from "$STAGE_PATH" CLAUDE_MEM_CLOUD_SYNC_HUB_URL)" \
		|| die "cannot read the injected hub url back out of the staged file — not installing it"
	[ "$got_uid" = "$uid" ] || die "the injected user id is \"$got_uid\", expected \"$uid\" — not installing the file"
	[ "$got_hub" = "$hub" ] || die "the injected hub url is \"$got_hub\", expected \"$hub\" — not installing the file"
	ok "user id $got_uid, hub $got_hub"

	# Proof that nothing else changed: the backup and the staged file must be
	# identical once the three keys this script owns are removed from both.
	# DEVICE_ID is not in that set, so this is also what proves it untouched.
	if ! diff -q \
		<(jq -S --argjson w "$SETTINGS_WRAPPED" "if \$w then (.env |= $SYNC_KEYS_DEL3) else $SYNC_KEYS_DEL3 end" "$bak") \
		<(jq -S --argjson w "$SETTINGS_WRAPPED" "if \$w then (.env |= $SYNC_KEYS_DEL3) else $SYNC_KEYS_DEL3 end" "$STAGE_PATH") \
		>/dev/null 2>&1; then
		die "the rewrite changed a setting other than the three sync keys — not installing it"
	fi
	ok "every other setting proven identical, DEVICE_ID untouched"

	mv "$STAGE_PATH" "$sf" || die "could not install the rewritten settings"
	STAGE_PATH=""
	ok "wrote $sf, mode 0600, $after key(s)"
	if [ "$SETTINGS_WRAPPED" = true ]; then
		warn "this file wraps its settings in an \"env\" object, so the keys went inside it."
		info "    SettingsDefaultsManager rewrites such a file as the .env subtree alone on the"
		info "    next boot, dropping any non-env top-level key. Check the file afterwards."
	fi
}

# ------------------------------------------------------------ verification ----

WORKER_URL=""

# The pid the worker reported BEFORE the restart was asked for. It can be empty
# even while a worker IS up, so emptiness proves nothing on its own — see
# worker_pid below. RESTART_VIA_POST records which path the restart took, and
# the POST succeeding is itself proof a worker was answering.
WORKER_PID_BEFORE=""
RESTART_VIA_POST=0

worker_up() { curl -fsS -m 5 "$WORKER_URL/api/sync/status" >/dev/null 2>&1; }

# Liveness ONLY, and deliberately not worker_up: /api/sync/status always
# performs an authenticated hub GET, and CloudSync gives that a 30s budget
# (requestTimeoutMs) against this 5s curl cap — so against a merely SLOW hub
# it fails while the worker is perfectly alive. That makes it a flapping
# signal, useless as evidence that a listener went away, and repointing away
# from a slow hub is a classic reason to run this script at all. /api/health
# answers locally and needs no hub, and ANY http status from it (including the
# 503 of a degraded queue) means something is holding the port.
worker_listening() {
	curl -sS -m 5 -o /dev/null -w '%{http_code}' "$WORKER_URL/api/health" 2>/dev/null \
		| grep -qE '^[1-5][0-9][0-9]$'
}

# /api/admin/restart flushes its response BEFORE the graceful shutdown starts
# (Server.ts:291-303), so the OLD process — still holding the OLD group's
# credentials — keeps answering for a moment afterwards. Without a process
# identity to compare, the verification below would happily read that old
# worker's configured:true / hub.reachable:true and report the NEW hub as
# connected, having exercised nothing. CloudSyncStatus carries no hub url, so
# the pid from /api/health is the only thing that can bind the two together.
# No `-f`: /api/health answers 503 — with `pid` still in the body — whenever the
# BullMQ queue's Redis is down (Server.ts:225-234), and -f would throw that body
# away. An empty result here therefore means only that ONE fetch failed to yield
# a pid: a timeout, a worker build predating `pid` in the payload, or no worker
# at all. It is never on its own evidence that the process changed.
worker_pid() {
	curl -sS -m 5 "$WORKER_URL/api/health" 2>/dev/null \
		| jq -r '.pid // empty' 2>/dev/null || true
}

restart_worker() {
	step "restarting the worker"
	RESTART_VIA_POST=0
	WORKER_PID_BEFORE="$(worker_pid)"
	if [ -n "$WORKER_PID_BEFORE" ]; then
		info "current worker is pid $WORKER_PID_BEFORE"
	fi
	local rc=0
	curl -fsS -m 5 -X POST "$WORKER_URL/api/admin/restart" >/dev/null 2>&1 || rc=$?
	if [ "$rc" -eq 0 ]; then
		# The POST answering is proof a worker WAS up, whatever the pid probe
		# managed to read — so the verification must prove a change from here.
		RESTART_VIA_POST=1
		ok "asked the worker to restart"
		return 0
	fi
	# curl 7 is "failed to connect": nothing is listening, and that is the ONLY
	# failure that proves the port was free. A timeout (28) against a wedged but
	# live worker is not the same thing — the request may even be processed
	# late — and `worker start` can exit 0 against a worker that is already
	# running, so treating a timeout as proof would hand the verification an
	# immediate pass for a process that never restarted.
	if [ "$rc" -eq 7 ]; then
		info "no worker answering on $WORKER_URL — starting one"
	else
		RESTART_VIA_POST=1
		warn "the restart request failed (curl exit $rc), which is not proof the port is free —"
		info "    something may still be holding $WORKER_URL, so the restart must be proven below"
		info "trying to start a worker anyway"
	fi
	if ! command -v npx >/dev/null 2>&1; then
		warn "npx not found — the settings are written, but nothing is using them yet. Start it with:"
		info "    npx claude-mem worker start"
		return 1
	fi
	if npx claude-mem worker start >/dev/null 2>&1; then
		ok "started the worker"
		return 0
	fi
	warn "could not start the worker — the settings are written, but nothing is using them yet:"
	info "    npx claude-mem worker start"
	return 1
}

# configured:true means only that three non-empty strings are present
# (DatabaseManager.ts). hub.reachable is what proves the credentials work from
# inside the worker, so both are required before this reports success.
# Two separate windows, deliberately. Waiting out the old worker's graceful
# drain and waiting for the new one to report a healthy hub are different
# waits, and sharing one budget lets a slow restart exhaust it before the new
# pid is ever seen — which would read as "it never restarted".
verify_status() { # $1 expected hub url
	local n json="" cfg="" reach="" pid="" fresh=0 quiet=0 saw_pid=0 saw_listen=0
	step "verifying"
	if [ "$RESTART_VIA_POST" -eq 0 ]; then
		# The POST was REFUSED, which is the evidence that nothing was
		# listening; the worker was then started from scratch, so whatever
		# answers now is necessarily that new process.
		fresh=1
	else
		for n in $(seq 1 "$RESTART_WAIT"); do
			pid="$(worker_pid)"
			[ -n "$pid" ] && saw_pid=1
			if [ -n "$pid" ] && [ "$pid" = "$WORKER_PID_BEFORE" ]; then
				# The OLD process demonstrably still holds the port, so any
				# quiet counted so far was a flap, not a departure — retract it.
				# This is what keeps the downtime fallback from ever overruling
				# live pid evidence.
				saw_listen=1
				quiet=0
			elif [ -n "$pid" ] && [ -n "$WORKER_PID_BEFORE" ]; then
				# A readable pid that differs from the captured one: the
				# strongest evidence available, and it needs no downtime.
				saw_listen=1
				fresh=1
				info "worker restarted: pid $WORKER_PID_BEFORE → $pid"
				break
			elif worker_listening || [ -n "$pid" ]; then
				# Something answers and it is NOT the old process — but there
				# is nothing to compare against either: no pid at all (a build
				# predating the field), or a pid whose pre-restart counterpart
				# could not be read (one timed-out capture, or the 503 of a
				# degraded queue). Observed downtime settles it, and it has to
				# be real: TWO consecutive misses, never a single flap.
				saw_listen=1
				if [ "$quiet" -ge 2 ]; then
					fresh=1
					info "worker restarted: the port went quiet, then answered again${pid:+ — now pid $pid}"
					break
				fi
				quiet=0
			else
				quiet=$(( quiet + 1 ))
			fi
			sleep 1
		done
	fi
	if [ "$fresh" -eq 0 ]; then
		if [ -n "$WORKER_PID_BEFORE" ] && [ "$saw_pid" -eq 1 ]; then
			err "the worker on $WORKER_URL is still process $WORKER_PID_BEFORE — it never restarted,"
			info "    so anything it reports comes from the OLD settings and proves nothing about"
			info "    the ones just written."
		elif [ "$saw_listen" -eq 0 ]; then
			err "nothing answered on $WORKER_URL within ${RESTART_WAIT} polls — the old worker"
			info "    stopped and its successor never bound the port."
		elif [ "$saw_pid" -eq 1 ]; then
			err "$WORKER_URL reports a pid now, but none could be read BEFORE the restart, so there"
			info "    is nothing to compare it against — and the port never went quiet long enough"
			info "    to prove the old process left. Re-running this is the cheapest way out: the"
			info "    settings already match, so it will skip straight to verifying."
		else
			err "$WORKER_URL answers but reports no pid, and the port never went quiet, so this"
			info "    could still be the pre-restart worker. A worker build older than the pid"
			info "    field in /api/health cannot be told apart from its own successor."
		fi
		info "    The settings ARE written. Restart and check by hand:"
		info "    npx claude-mem worker restart && npx claude-mem status"
		return 1
	fi
	for n in $(seq 1 "$STATUS_WAIT"); do
		# The status endpoint is briefly unreachable during a restart, hence
		# the poll. `.configured` is a boolean, so tostring — `// empty` would
		# swallow false, one of the values waited on.
		json="$(curl -fsS -m 5 "$WORKER_URL/api/sync/status" 2>/dev/null || true)"
		if [ -n "$json" ]; then
			cfg="$(printf '%s' "$json" | jq -r '.configured | tostring' 2>/dev/null || true)"
			reach="$(printf '%s' "$json" | jq -r '.hub.reachable | tostring' 2>/dev/null || true)"
			if [ "$cfg" = "true" ] && [ "$reach" = "true" ]; then break; fi
		fi
		sleep 1
	done
	if [ -z "$json" ]; then
		err "the new worker did not answer on $WORKER_URL within the wait window (${STATUS_WAIT} polls)"
		return 1
	fi
	print_status "$json"
	if [ "$cfg" != "true" ]; then
		err "configured:${cfg:-unknown} — the worker did not pick up the three keys."
		[ "$SETTINGS_WRAPPED" = true ] \
			&& info "    This file wraps its settings in an \"env\" object; check they landed inside it."
		return 1
	fi
	if [ "$reach" = "null" ]; then
		err "configured:true but hub.reachable:null — CloudSync never got as far as a hub call."
		info "    That is the fingerprint of a device-id mint failure: resolveDeviceId() could not"
		info "    persist CLAUDE_MEM_CLOUD_SYNC_DEVICE_ID. Check that $SETTINGS_REAL is writable."
		return 1
	fi
	if [ "$reach" != "true" ]; then
		err "configured:true but hub.reachable:false — the worker cannot reach the hub."
		info "    The hub error above is the worker's own; the pre-write probe did get a 200."
		return 1
	fi
	ok "configured:true, hub.reachable:true — this machine is connected to $1"
	return 0
}

# hub.error is token-redacted at CloudSync.ts:635, so it is safe to print.
print_status() { # $1 status json
	local out
	out="$(printf '%s' "$1" | jq -r '
		"    device     \(.deviceId)",
		"    configured \(.configured)",
		"    pending    obs \(.pending.observations)  sum \(.pending.summaries)  prompts \(.pending.prompts)  mutations \(.pending.mutations)  tombstones \(.pending.tombstones)",
		"    quarantine \(.quarantine.count)\(if .quarantine.latestReason then " (\(.quarantine.latestReason))" else "" end)",
		"    lastError  \(.lastError // "none")",
		"    hub        reachable \(.hub.reachable) epoch \(.hub.epoch // "-") head \(.hub.headSeq // "-") projected \(.hub.projectedSeq // "-")",
		(if .hub.error then "    hub error  \(.hub.error)" else empty end)
	' 2>/dev/null)" || { info "could not format the status response"; return 0; }
	printf '%s\n' "$out" >&2
}

# --------------------------------------------------------------- backfill ----

# Pre-launch history is held back by the v47 launch baseline. Clearing it is a
# separate, once-per-fleet decision, so it is offered rather than done.
offer_backfill() { # $1 slug, $2 hub url
	local excl native replicas rc=0 n stopped=0
	command -v sqlite3 >/dev/null 2>&1 || return 0
	resolve_db
	[ -f "$DB_FILE" ] || return 0
	excl="$(count_sql 'SELECT COUNT(*) FROM sync_launch_exclusions;')" || return 0
	[ "$excl" -gt 0 ] || return 0

	# backfill.ts's own predicate, exactly: it re-nulls synced_at on native rows
	# that HAVE been synced. Counting all native rows would overstate it by the
	# already-pending ones, which are going to be pushed anyway.
	native="$(count_over_tables 'origin_device_id IS NULL AND synced_at IS NOT NULL')"
	replicas="$(count_over_tables 'origin_device_id IS NOT NULL')"

	step "pre-launch history"
	info "$excl row(s) are held back by the launch baseline — history that predates this"
	info "    install's sync support. They will never reach group \"$1\" unless the baseline"
	info "    is cleared with scripts/self-host-backfill.ts."
	info ""
	info "This is a ONCE-PER-FLEET decision. That script's header says \"once, on one"
	info "machine only\"; here is the actual condition. Backfill only re-pushes NATIVE"
	info "rows (origin_device_id IS NULL). Entity ids are stableDocumentId(kind, deviceId,"
	info "localId) — device-scoped — so content held natively on two machines uploads as"
	info "two distinct entities and duplicates hub-wide. Machines that only ever shared"
	info "through SyncHub hold each other's history as REPLICA rows, which backfill"
	info "refuses to touch, so their backfills union rather than duplicate. Native overlap"
	info "arises two ways:"
	info "  · a copied claude-mem.db, where the same rows are native on both machines;"
	info "  · past use of scripts/claude-mem-sync, the legacy SSH/sqlite copier — it writes"
	info "    rows without the sync columns, so they land NATIVE on the receiving machine."
	info "Do not count on content-hash dedup as a net: the ON CONFLICT(memory_session_id,"
	info "content_hash) guard sits on the APPLY path, so it protects a pulling device's"
	info "local DB while the hub log and the projector's entity_id-keyed D1 still carry"
	info "both copies — and rows predating migration v29 carry a RANDOM content_hash."
	info ""
	row "$native" "already-synced native rows here — exactly what backfill re-queues"
	row "$replicas" "replica rows here — backfill never touches these"

	if [ ! -t 0 ]; then
		info "no terminal — not offering it. To do it later, with the worker stopped:"
		info "    bun $BACKFILL_SCRIPT"
		return 0
	fi
	confirm "Clear the launch baseline and re-push this machine's pre-launch history?" || {
		info "left alone — run \`bun $BACKFILL_SCRIPT\` later if you change your mind"
		return 0
	}
	if ! command -v bun >/dev/null 2>&1; then
		warn "bun not found — install it, then run: bun $BACKFILL_SCRIPT"
		return 0
	fi
	if [ ! -f "$BACKFILL_SCRIPT" ]; then
		warn "$BACKFILL_SCRIPT not found — skipping. It ships in the claude-mem repo."
		return 0
	fi
	# Deliberately the SOFT gate: the connect above has already written and
	# verified the settings, so require_typed_word's "nothing was changed" would
	# be false here and its exit 1 would report a good run as a failure.
	ask_typed_word backfill "clear the launch baseline on THIS machine" || {
		info "not confirmed — left alone. The connect above stands; run"
		info "    \`bun $BACKFILL_SCRIPT\` later, with the worker stopped."
		return 0
	}

	step "backfill"
	info "stopping the worker so its drain cannot race the requeue"
	curl -fsS -m 5 -X POST "$WORKER_URL/api/admin/shutdown" >/dev/null 2>&1 || true
	for n in $(seq 1 "$SHUTDOWN_WAIT"); do
		worker_up || { stopped=1; break; }
		sleep 1
	done
	# Deliberately before the requeue, not after: a racing drain is exactly what
	# the backfill script's own guard refuses, and forcing past it would let the
	# worker mark rows synced while they are being re-nulled.
	[ "$stopped" -eq 1 ] \
		|| die "the worker is still answering on $WORKER_URL after ${SHUTDOWN_WAIT}s — stop it yourself (npx claude-mem worker stop), then run: bun $BACKFILL_SCRIPT"
	ok "worker stopped"

	# The worker is DOWN from here on, so every path below either brings it
	# back or says loudly that it did not.
	bun "$BACKFILL_SCRIPT" || rc=$?
	if [ "$rc" -ne 0 ]; then
		err "the backfill exited $rc — the launch baseline may be partly cleared"
	else
		ok "launch baseline cleared — the drain will now upload the pre-launch corpus"
	fi
	restart_worker || {
		err "THE WORKER IS STOPPED. Nothing is capturing or syncing on this machine."
		info "    Start it with: npx claude-mem worker start"
		return 1
	}
	verify_status "$2" || return 1
	[ "$rc" -eq 0 ]
}

# ------------------------------------------------------------------- main ----

preflight() {
	step "preflight"
	local c missing=""
	for c in op jq curl; do
		command -v "$c" >/dev/null 2>&1 || missing="$missing $c"
	done
	[ -z "$missing" ] || die "missing required tool(s):$missing"
	op_signed_in || die "the 1Password CLI is not signed in — run \`op signin\`, or pass --skip-op-check if op is authorized another way (biometric unlock, desktop app) and only \`op whoami\` is failing"
	ok "op $(op --version 2>/dev/null || true), jq $(jq --version 2>/dev/null || true)"
	command -v sqlite3 >/dev/null 2>&1 \
		|| warn "sqlite3 not found — the repoint report and the backfill offer will be skipped"
	if [ "$DRY_RUN" -eq 1 ]; then
		warn "dry run: nothing will be probed, written or restarted"
	fi
	return 0
}

choose_group() {
	local slugs count
	if [ -n "$SLUG" ]; then
		validate_slug "$SLUG"
		return 0
	fi
	step "group"
	slugs="$(op_group_slugs)" || die "cannot list the groups in vault \"$VAULT\""
	count="$(printf '%s\n' "$slugs" | grep -c . || true)"
	[ "$count" -gt 0 ] \
		|| die "vault \"$VAULT\" holds no claude-mem sync groups — provision one with \`./scripts/deploy-sync-stack.sh --group <slug> --vault $(shq "$VAULT")\`"
	info "groups in this vault: $(printf '%s' "$slugs" | tr '\n' ' ')"
	# The exact analogue of the vault guard above, and the more important of
	# the two: the group decides where this machine's ENTIRE corpus goes, and
	# the fresh-connect path has no other confirmation in front of the write.
	# Defaulting to the alphabetically-first slug unattended is not acceptable.
	if [ "$ASSUME_YES" -eq 1 ] || [ ! -t 0 ]; then
		die "$count group(s) are in vault \"$VAULT\" — name the one to connect to with --group rather than letting an unattended run pick"
	fi
	SLUG="$(ask_value "group to connect this machine to" "$(printf '%s\n' "$slugs" | head -1)")"
	validate_slug "$SLUG"
}

HUB_URL=""
USER_ID=""

# Reports every missing piece before dying, so one run names everything that
# needs fixing rather than one item per run.
check_credentials() {
	local tok_title note_title problems=0 note_json note_read probe len matches
	tok_title="$(title_sync_token "$SLUG")"
	note_title="$(title_note "$SLUG")"
	step "credentials for group \"$SLUG\""

	# The ids come first: every reference below is built from them, and both
	# items must be located before a single reference can be assembled.
	if op_item_exists "$tok_title"; then
		ITEM_ID_TOKEN="$(op_item_id "$tok_title")"
		ok "\"$tok_title\" present ($ITEM_ID_TOKEN)"
	else
		err "1Password item \"$tok_title\" is missing from vault \"$VAULT\""
		problems=$(( problems + 1 ))
	fi

	note_read=0
	if op_item_exists "$note_title"; then
		ITEM_ID_NOTE="$(op_item_id "$note_title")"
		note_json="$(mktmp)"
		if op_note_fetch "$note_title" "$note_json"; then
			note_read=1
			ok "\"$note_title\" present ($ITEM_ID_NOTE)"
			USER_ID="$(note_field "$note_json" user_id)"
			HUB_URL="$(strip_slash "$(note_field "$note_json" hub_url)")"
		else
			# Distinct from "missing": the cached listing already said this item
			# exists, so a failure here is the session or the rate limit, and
			# reporting "no user_id field" would send you to the wrong place.
			err "\"$note_title\" is in the vault listing but could not be read — an expired session or a rate limit, not a missing item"
			problems=$(( problems + 1 ))
		fi
	else
		err "1Password item \"$note_title\" is missing from vault \"$VAULT\""
		problems=$(( problems + 1 ))
	fi

	# Only meaningful once the note was actually read; an unreadable note has
	# already been reported and must not also be blamed for missing fields.
	if [ "$note_read" -eq 1 ]; then
		if [ -z "$USER_ID" ]; then
			err "\"$note_title\" has no user_id field"
			problems=$(( problems + 1 ))
		elif ! is_uuid "$USER_ID"; then
			err "\"$note_title\" user_id is not a uuid: \"$USER_ID\""
			problems=$(( problems + 1 ))
		else
			ok "user_id $USER_ID"
		fi
		if [ -z "$HUB_URL" ]; then
			err "\"$note_title\" has no hub_url field"
			problems=$(( problems + 1 ))
		elif ! is_https_url "$HUB_URL"; then
			err "\"$note_title\" hub_url is not a plain https url: \"$HUB_URL\""
			problems=$(( problems + 1 ))
		else
			ok "hub_url $HUB_URL"
		fi
	fi

	# Both references, through op inject — the resolver the write itself uses.
	# Deferred to here rather than folded into the branches above because it
	# needs both ids AND the note's user_id to compare against, and because one
	# op inject call proves both references for the price of one.
	if [ "$problems" -eq 0 ]; then
		probe="$(op_refs_probe "$(ref_user_id "$SLUG")" "$(ref_token "$SLUG")" "$USER_ID")" || probe=""
		len="${probe%% *}"
		matches="${probe##* }"
		case "$len" in
			''|*[!0-9]*)
				# op inject exits 1 for an unresolvable reference exactly as it
				# does for a dead session, and the status cannot tell them apart
				# — so name every cause rather than asserting the wrong one.
				err "the references did not resolve through \`op inject\`, which is what the write uses:"
				info "    the op session may have expired, or the client is rate-limited,"
				info "    or \"$tok_title\" has no \"password\" field (wrong category?),"
				info "    or user_id is not in the \"$OP_SECTION\" section of \"$note_title\""
				info "    note: \`op read\` can succeed where \`op inject\` fails — if an ARCHIVED"
				info "    item shares one of these titles, op inject matches the archived one"
				problems=$(( problems + 1 )) ;;
			*)
				if [ "$len" -lt "$SECRET_MIN_LEN" ]; then
					err "the injected token is $len characters, expected at least $SECRET_MIN_LEN"
					problems=$(( problems + 1 ))
				elif [ "$matches" != "yes" ]; then
					# Cannot happen with id-based references, which is the point of
					# asserting it: if it ever fires, the reference is reading an
					# item other than the note this run just validated.
					err "the injected user_id does not match \"$note_title\" — the reference is reading a different item"
					problems=$(( problems + 1 ))
				else
					ok "both references resolve through op inject (token $len chars, user_id matches)"
				fi ;;
		esac
	fi

	[ "$problems" -eq 0 ] \
		|| die "$problems missing or unusable credential(s) for group \"$SLUG\" in vault \"$VAULT\" — run \`./scripts/deploy-sync-stack.sh --group $SLUG --vault $(shq "$VAULT")\` to provision them"
}

# hub_url in the clear; the other two as references. These are BYTE-IDENTICAL
# to what the template carries, so what is shown is what gets resolved — there
# is no second version holding values. That is why the ids appear here rather
# than the friendlier titles: showing a title would describe a lookup this
# script does not perform, and the title/id distinction is exactly what broke
# a run once already. The titles are printed alongside so the ids are legible.
print_preview() {
	step "preview"
	info "these three keys will be set in $SETTINGS_REAL:"
	if [ "$SETTINGS_WRAPPED" = true ]; then
		info "(inside its \"env\" object, where claude-mem's loader reads them)"
	fi
	cat >&2 <<PREVIEW
        CLAUDE_MEM_CLOUD_SYNC_HUB_URL = $HUB_URL
        CLAUDE_MEM_CLOUD_SYNC_USER_ID = \$(op read "$(ref_user_id "$SLUG")")
        CLAUDE_MEM_CLOUD_SYNC_TOKEN   = \$(op read "$(ref_token "$SLUG")")
PREVIEW
	info "referenced by item id, which is what op inject resolves:"
	info "    $ITEM_ID_NOTE  = \"$(title_note "$SLUG")\""
	info "    $ITEM_ID_TOKEN  = \"$(title_sync_token "$SLUG")\""
	if [ -n "$(settings_get CLAUDE_MEM_CLOUD_SYNC_DEVICE_ID)" ]; then
		info "CLAUDE_MEM_CLOUD_SYNC_DEVICE_ID already exists here and is left untouched —"
		info "    entity ids derive from it, so keeping it is what makes a re-push idempotent."
	else
		info "CLAUDE_MEM_CLOUD_SYNC_DEVICE_ID is not set; the worker mints and persists one."
	fi
}

main() {
	# Rejected before any network call: a typo in --group should cost nothing.
	[ -n "$SLUG" ] && validate_slug "$SLUG"
	preflight
	select_vault
	choose_group
	resolve_settings
	check_credentials
	# Asserted HERE, not inside ref_or_die: that check runs in a command
	# substitution's subshell, so its die cannot stop the run. Both ids are set
	# by check_credentials or it has already died.
	{ [ -n "$ITEM_ID_TOKEN" ] && [ -n "$ITEM_ID_NOTE" ]; } \
		|| die "internal: 1Password item ids are unresolved after the credential check"

	WORKER_URL="http://127.0.0.1:$(worker_port)"

	local current mode tpl cand
	current="$(strip_slash "$(settings_get CLAUDE_MEM_CLOUD_SYNC_HUB_URL)")"
	step "current state"
	if [ -z "$current" ]; then
		mode=connect
		info "this machine is not configured for cloud sync"
	elif [ "$current" = "$HUB_URL" ]; then
		mode=same
		info "this machine already points at $current — group \"$SLUG\""
	else
		mode=repoint
		warn "this machine points at a DIFFERENT hub: $current"
		info "    moving it to \"$SLUG\" ($HUB_URL) moves its whole corpus, not one project:"
		info "    the three settings are install-wide and there is no per-project routing."
	fi

	print_preview

	if [ "$DRY_RUN" -eq 1 ]; then
		step "dry run complete"
		info "nothing was probed, written or restarted"
		return 0
	fi

	if [ "$mode" = same ]; then
		# Rendering and injecting is how a ROTATED token is detected without
		# either value being displayed. Both files live in TMP_DIR, not the
		# target directory: nothing on this path is installed.
		tpl="$(mktmp)"; cand="$(mktmp)"
		render_template "$SLUG" "$HUB_URL" "$tpl"
		inject_template "$tpl" "$cand" \
			|| die "op inject failed — a reference did not resolve. $SETTINGS_REAL is unchanged"
		# -q and discarded output: the diff itself would carry the token.
		if diff -q <(jq -S '.' "$SETTINGS_REAL") <(jq -S '.' "$cand") >/dev/null 2>&1; then
			ok "the settings already match the vault exactly — nothing to write"
			mode=verify
		else
			info "the settings differ from the vault — a rotated token, or a hand edit"
			confirm "Rewrite the three keys from 1Password?" || { info "left alone"; return 0; }
		fi
	fi

	if [ "$mode" = repoint ]; then
		[ "$REPOINT" -eq 1 ] \
			|| die "refusing to move this machine from $current to $HUB_URL without --repoint"
		repoint_report
		step "confirm the repoint"
		# Checked before require_typed_word so the advice is about --repoint
		# rather than about a terminal that a flag cannot substitute for.
		[ -t 0 ] || die "a repoint requires a terminal — the typed confirmation has no bypass"
		require_typed_word "$SLUG" "point this machine at group \"$SLUG\""
	fi

	if [ "$mode" != verify ]; then
		step "probing the hub before touching anything"
		local code
		code="$(probe_hub "$SLUG" "$HUB_URL" "$USER_ID")"
		explain_probe "$code" "$SLUG"
		[ "$code" = "200" ] \
			|| die "the hub did not accept these credentials — $SETTINGS_REAL is untouched"
		write_settings "$SLUG" "$HUB_URL" "$USER_ID"
	fi

	restart_worker || return 1
	verify_status "$HUB_URL" || return 1
	offer_backfill "$SLUG" "$HUB_URL" || return 1
	return 0
}

main "$@"
