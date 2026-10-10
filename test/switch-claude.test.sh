#!/usr/bin/env bash
# Test suite for bin/switch-claude.
#
# Runs entirely inside a throwaway HOME with mocked `security`, `claude` and `curl`,
# so it never touches a real Keychain, real credentials or the network. Every test
# runs once per platform backend (macos = Keychain, linux = credentials file).
#
#   bash test/switch-claude.test.sh                 # both platforms
#   TEST_PLATFORMS=linux bash test/switch-claude.test.sh
#   bash test/switch-claude.test.sh test_add_      # only tests whose name matches
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SC="$ROOT/bin/switch-claude"

TEST_HOME="$(mktemp -d)"
trap 'rm -rf "$TEST_HOME"' EXIT
BIN_DIR="$TEST_HOME/bin"
KEYCHAIN_DIR="$TEST_HOME/keychain"
mkdir -p "$BIN_DIR"

# --- mocks -----------------------------------------------------------------------

cat > "$BIN_DIR/security" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
safe_name() { printf '%s__%s' "$1" "$2" | tr '/ ' '__'; }
cmd="$1"; shift
service=""; account=""; password=""; have_account=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -s) service="$2"; shift 2 ;;
    -a) account="$2"; have_account=1; shift 2 ;;
    -w) if [[ "$cmd" == add-generic-password ]]; then password="$2"; shift 2; else shift; fi ;;
    *) shift ;;
  esac
done
mkdir -p "$KEYCHAIN_DIR"
# Injected failures: a locked Keychain / denied access looks like this.
if [[ "$cmd" == find-generic-password && -n "${MOCK_SECURITY_FAIL_FIND:-}" && "$account" == "$MOCK_SECURITY_FAIL_FIND" ]]; then exit 51; fi
if [[ "$cmd" == add-generic-password && -n "${MOCK_SECURITY_FAIL_ADD:-}" && "$account" == "$MOCK_SECURITY_FAIL_ADD" ]]; then exit 51; fi
case "$cmd" in
  find-generic-password)
    if [[ "$have_account" -eq 1 ]]; then
      file="$KEYCHAIN_DIR/$(safe_name "$service" "$account")"
    else
      file=$(ls "$KEYCHAIN_DIR/$(safe_name "$service" "")"* 2>/dev/null | sort | head -n 1 || true)
    fi
    [[ -n "${file:-}" && -f "$file" ]] || exit 44
    cat "$file"; echo
    ;;
  add-generic-password)
    printf '%s' "$password" > "$KEYCHAIN_DIR/$(safe_name "$service" "$account")"
    ;;
  delete-generic-password)
    file="$KEYCHAIN_DIR/$(safe_name "$service" "$account")"
    [[ -f "$file" ]] || exit 44
    rm -f "$file"
    ;;
  *) exit 2 ;;
esac
SH

# Records every call. With CLAUDE_REFRESH_LABEL set, `claude -p` behaves like a real
# token refresh: it rotates whatever credential is currently active.
cat > "$BIN_DIR/claude" <<'SH'
#!/usr/bin/env bash
{
  printf 'args=%s\n' "$*"
  printf 'BROWSER=%s\n' "${BROWSER:-}"
  printf 'env_token=%s\n' "${CLAUDE_CODE_OAUTH_TOKEN-<unset>}"
} >> "$CLAUDE_CALL_LOG"
if [[ "${1:-}" == "-p" && -n "${CLAUDE_REFRESH_LABEL:-}" ]]; then
  blob=$(python3 - "$CLAUDE_REFRESH_LABEL" <<'PY'
import json, sys, time
label = sys.argv[1]
print(json.dumps({"claudeAiOauth": {
    "accessToken": f"access-refreshed-{label}",
    "refreshToken": f"refresh-refreshed-{label}",
    "expiresAt": int((time.time() + 3600) * 1000),
    "refreshTokenExpiresAt": int((time.time() + 86400 * 7) * 1000),
}}, separators=(",", ":")))
PY
)
  if [[ "$SWITCH_CLAUDE_PLATFORM" == macos ]]; then
    security add-generic-password -U -s "Claude Code-credentials" -a "$USER" -w "$blob"
  else
    mkdir -p "$HOME/.claude"; printf '%s\n' "$blob" > "$HOME/.claude/.credentials.json"
  fi
fi
exit 0
SH

# Probe endpoint mock. The bearer token must arrive through `-K -` (stdin config),
# never through argv; the token text decides the response.
cat > "$BIN_DIR/curl" <<'SH'
#!/usr/bin/env bash
printf 'argv=%s\n' "$*" >> "$CURL_CALL_LOG"
dump=""; read_config=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -D) dump="$2"; shift 2 ;;
    -K) [[ "$2" == "-" ]] && read_config=1; shift 2 ;;
    *) shift ;;
  esac
done
token=""
if [[ "$read_config" -eq 1 ]]; then
  token=$(sed -n 's/.*Authorization: Bearer \([^"]*\)".*/\1/p' | head -n 1)
fi
printf 'token_via_stdin=%s\n' "${token:+yes}" >> "$CURL_CALL_LOG"
case "$token" in
  *dead*) status="401 Unauthorized" ;;
  *ratelimited*) status="429 Too Many Requests" ;;
  "") status="401 Unauthorized" ;;
  *) status="200 OK" ;;
esac
{
  printf 'HTTP/2 %s\r\n' "$status"
  printf 'anthropic-ratelimit-unified-5h-utilization: 0.34\r\n'
  printf 'anthropic-ratelimit-unified-5h-reset: 1791600000\r\n'
  printf 'anthropic-ratelimit-unified-7d-utilization: 0.12\r\n'
} > "${dump:-/dev/null}"
exit 0
SH

REAL_PYTHON3=$(command -v python3)
cat > "$BIN_DIR/python3" <<SH
#!/usr/bin/env bash
if env | grep -q '^CREDS_JSON='; then echo "CREDS_JSON in env" >> "\$PY_ENV_LOG"; fi
exec "$REAL_PYTHON3" "\$@"
SH

for cmd in pkill sleep; do printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN_DIR/$cmd"; done
printf '#!/usr/bin/env bash\nexit 1\n' > "$BIN_DIR/pgrep"
chmod +x "$BIN_DIR"/*

export HOME="$TEST_HOME/home"
export USER="testuser"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_STATE_HOME="$HOME/.local/state"
export KEYCHAIN_DIR
export CLAUDE_CALL_LOG="$TEST_HOME/claude-call.log"
export CURL_CALL_LOG="$TEST_HOME/curl-call.log"
export PY_ENV_LOG="$TEST_HOME/py-env.log"
export PATH="$BIN_DIR:$PATH"
unset CLAUDE_CODE_OAUTH_TOKEN SWITCH_CLAUDE_HOME CLAUDE_REFRESH_LABEL || true

CONF="$XDG_CONFIG_HOME/switch-claude"
CREDS_FILE="$HOME/.claude/.credentials.json"
TOKEN_ENV="$CONF/token.env"
PENDING="$CONF/pending"
A_EMAIL="alice@example.com"; A_UUID="11111111-1111-4111-8111-111111111111"
B_EMAIL="bob@example.com";   B_UUID="22222222-2222-4222-8222-222222222222"
TOKEN_OK="fake-token-healthy-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
TOKEN_DEAD="fake-token-dead-BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
TOKEN_RL="fake-token-ratelimited-CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC"

# --- helpers ---------------------------------------------------------------------

safe_name() { printf '%s__%s' "$1" "$2" | tr '/ ' '__'; }

# First line of a file, whether or not it ends with a newline; empty if missing.
first_line() {
  local l=""
  [[ -f "$1" ]] || return 0
  IFS= read -r l < "$1" || true
  printf '%s' "$l"
}

ms_from_now() {
  python3 -c 'import sys,time; print(int((time.time() + float(sys.argv[1])) * 1000))' "$1"
}

# creds <label> <access-seconds-from-now> [<refresh-seconds-from-now>]
creds() {
  local refresh="${3:-}"
  python3 - "$1" "$(ms_from_now "$2")" "${refresh:+$(ms_from_now "$refresh")}" <<'PY'
import json, sys
label, exp, rexp = sys.argv[1], int(sys.argv[2]), sys.argv[3]
o = {"accessToken": f"access-{label}", "refreshToken": f"refresh-{label}", "expiresAt": exp}
if rexp:
    o["refreshTokenExpiresAt"] = int(rexp)
print(json.dumps({"claudeAiOauth": o}, separators=(",", ":")))
PY
}
fresh() { creds "$1" 3600; }                       # access valid
refreshable() { creds "$1" -3600 604800; }         # access expired, refresh valid
dead() { creds "$1" -3600 -60; }                   # both expired

reset_state() {
  rm -rf "$HOME" "$KEYCHAIN_DIR" "$CLAUDE_CALL_LOG" "$CURL_CALL_LOG"
  unset MOCK_SECURITY_FAIL_FIND MOCK_SECURITY_FAIL_ADD || true
  mkdir -p "$HOME/.claude" "$KEYCHAIN_DIR"
  unset CLAUDE_CODE_OAUTH_TOKEN CLAUDE_REFRESH_LABEL || true
}

set_active() {
  if [[ "$SWITCH_CLAUDE_PLATFORM" == macos ]]; then
    printf '%s' "$1" > "$KEYCHAIN_DIR/$(safe_name "Claude Code-credentials" "$USER")"
  else
    printf '%s\n' "$1" > "$CREDS_FILE"
  fi
}

get_active() {
  if [[ "$SWITCH_CLAUDE_PLATFORM" == macos ]]; then
    first_line "$KEYCHAIN_DIR/$(safe_name "Claude Code-credentials" "$USER")"
  else
    first_line "$CREDS_FILE"
  fi
}

slot_path() {
  if [[ "$SWITCH_CLAUDE_PLATFORM" == macos ]]; then
    printf '%s' "$KEYCHAIN_DIR/$(safe_name "switch-claude" "$1")"
  else
    printf '%s' "$CONF/creds/$1"
  fi
}

set_slot() {
  local p; p=$(slot_path "$1")
  mkdir -p "$(dirname "$p")"
  printf '%s' "$2" > "$p"
}

get_slot() {
  first_line "$(slot_path "$1")"
}

# conf_slots "lw oauth a@x uuid" "sw oauth b@x uuid" ...
conf_slots() {
  mkdir -p "$CONF"
  printf '%s\n' "$@" > "$CONF/slots.conf"
}

conf_set() {
  mkdir -p "$CONF"
  printf '%s=%s\n' "$1" "$2" >> "$CONF/config"
}

set_current_email() {
  python3 - "$HOME/.claude.json" "$1" "${2:-}" <<'PY'
import json, sys
path, email, uuid = sys.argv[1], sys.argv[2], sys.argv[3]
oa = {"emailAddress": email}
if uuid:
    oa["accountUuid"] = uuid
json.dump({"oauthAccount": oa, "unrelated": {"keep": True}}, open(path, "w"))
PY
}

current_field() {
  python3 - "$HOME/.claude.json" "$1" <<'PY'
import json, sys
print(json.load(open(sys.argv[1])).get("oauthAccount", {}).get(sys.argv[2], ""))
PY
}

# Two oauth slots, alice active.
two_slots() {
  local a b
  a=$(fresh alice); b=$(fresh bob)
  conf_slots "lw oauth $A_EMAIL $A_UUID" "sw oauth $B_EMAIL $B_UUID"
  set_slot lw "$a"; set_slot sw "$b"
  set_active "$a"
  set_current_email "$A_EMAIL" "$A_UUID"
}

run_sc() {
  set +e
  out=$("$SC" "$@" 2>&1)
  code=$?
  set -e
  printf '%s' "$out"
  return "$code"
}

expect_fail() {
  local out
  if out=$(run_sc "$@"); then
    printf 'Expected `switch-claude %s` to fail. Output:\n%s\n' "$*" "$out" >&2
    return 1
  fi
  printf '%s' "$out"
}

assert_contains() {
  [[ "$1" == *"$2"* ]] || { printf 'Expected output to contain: %s\nActual:\n%s\n' "$2" "$1" >&2; return 1; }
}

assert_not_contains() {
  [[ "$1" != *"$2"* ]] || { printf 'Expected output NOT to contain: %s\nActual:\n%s\n' "$2" "$1" >&2; return 1; }
}

assert_eq() {
  [[ "$1" == "$2" ]] || { printf 'Expected [%s]\n     got [%s]\n' "$2" "$1" >&2; return 1; }
}

assert_absent() {
  [[ ! -e "$1" ]] || { printf 'Expected absent: %s\n' "$1" >&2; return 1; }
}

assert_mode() {
  local m
  m=$(stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1")
  [[ "$m" == "$2" ]] || { printf 'Expected mode %s on %s, got %s\n' "$2" "$1" "$m" >&2; return 1; }
}

add_token_slot() {  # name token
  set_slot "$1" "$2"
  mkdir -p "$CONF"
  printf '%s token - -\n' "$1" >> "$CONF/slots.conf"
}

# Line of the `status` slot table for one slot.
slot_line() {
  printf '%s\n' "$1" | grep -E "^[* ] $2 " || { printf 'No status line for slot %s in:\n%s\n' "$2" "$1" >&2; return 1; }
}

conf_line() {
  grep -E "^$1[[:space:]]" "$CONF/slots.conf" | tr -s ' \t' ' ' || true
}

# --- A. slot management ------------------------------------------------------------

test_status_without_config() {
  local out
  out=$(run_sc status)
  assert_contains "$out" "No slots configured yet"
  assert_contains "$out" "switch-claude add"
}

test_bare_invocation_is_status_only() {
  two_slots
  local out before
  before=$(get_active)
  out=$(run_sc)
  assert_contains "$out" "Slots:"
  assert_eq "$(get_active)" "$before"
  assert_eq "$(current_field emailAddress)" "$A_EMAIL"
}

test_add_captures_current_login() {
  local a out
  a=$(fresh alice)
  set_active "$a"
  set_current_email "$A_EMAIL" "$A_UUID"
  out=$(run_sc add lw)
  assert_contains "$out" "Added slot lw"
  assert_eq "$(conf_line lw)" "lw oauth $A_EMAIL $A_UUID"
  assert_eq "$(get_slot lw)" "$a"
}

test_add_refuses_duplicate_name() {
  two_slots
  local out
  out=$(expect_fail add lw)
  assert_contains "$out" "already exists"
}

test_add_refuses_email_already_in_other_slot() {
  two_slots
  local out
  out=$(expect_fail add work)
  assert_contains "$out" "lw"
  [[ -z "$(conf_line work)" ]]
}

test_add_refuses_credentials_already_in_other_slot() {
  two_slots
  set_current_email "carol@example.com"
  local out
  out=$(expect_fail add carol)
  assert_contains "$out" "already stored in slot lw"
  [[ -z "$(conf_line carol)" ]]
}

test_add_refuses_bad_names() {
  local a name out
  a=$(fresh alice); set_active "$a"; set_current_email "$A_EMAIL" "$A_UUID"
  for name in status add list help -x "a b" "UPPER" "x!" ""; do
    out=$(expect_fail add "$name")
    [[ -z "$(cat "$CONF/slots.conf" 2>/dev/null)" ]] || { printf 'slot written for bad name [%s]\n' "$name" >&2; return 1; }
  done
}

test_add_refuses_without_login() {
  set_current_email "$A_EMAIL" "$A_UUID"
  local out
  out=$(expect_fail add lw)
  assert_contains "$out" "no active login"
}

test_add_with_email_registers_empty_slot() {
  local out
  out=$(run_sc add sw --email "$B_EMAIL")
  assert_contains "$out" "switch-claude login sw"
  assert_eq "$(conf_line sw)" "sw oauth $B_EMAIL -"
  assert_absent "$(slot_path sw)"
  out=$(run_sc status)
  assert_contains "$(slot_line "$out" sw)" "✗ empty"
}

test_add_token_reads_stdin() {
  local out
  out=$(printf '%s\n' "$TOKEN_OK" | "$SC" add hub --token 2>&1)
  assert_contains "$out" "Added slot hub"
  assert_not_contains "$out" "$TOKEN_OK"
  assert_eq "$(conf_line hub)" "hub token - -"
  assert_eq "$(get_slot hub)" "$TOKEN_OK"
  out=$(printf '%s\n' "$TOKEN_DEAD" | "$SC" add hub2 --token --email "$B_EMAIL" 2>&1)
  assert_eq "$(conf_line hub2)" "hub2 token $B_EMAIL -"
}

test_add_token_rejects_garbage_and_duplicates() {
  local bad out
  for bad in "" "short" "fake-token has spaces in it AAAAAAAAAAAAAAAAAAAAAAAAAA"; do
    if out=$(printf '%s\n' "$bad" | "$SC" add hub --token 2>&1); then
      printf 'accepted bad token [%s]\n' "$bad" >&2; return 1
    fi
  done
  printf '%s\n' "$TOKEN_OK" | "$SC" add hub --token >/dev/null 2>&1
  if out=$(printf '%s\n' "$TOKEN_OK" | "$SC" add hub2 --token 2>&1); then
    printf 'accepted duplicate token\n' >&2; return 1
  fi
  assert_contains "$out" "already stored in slot hub"
}

test_list_prints_slots_without_secrets() {
  two_slots
  set_slot hub "$TOKEN_OK"
  printf 'hub token - -\n' >> "$CONF/slots.conf"
  local out
  out=$(run_sc list)
  assert_contains "$out" "lw"
  assert_contains "$out" "$A_EMAIL"
  assert_contains "$out" "hub"
  assert_contains "$out" "token"
  assert_not_contains "$out" "access-"
  assert_not_contains "$out" "$TOKEN_OK"
}

test_remove_backs_up_then_deletes() {
  two_slots
  local out b snap
  b=$(get_slot sw)
  out=$(run_sc remove sw)
  assert_contains "$out" "Removed slot sw"
  assert_absent "$(slot_path sw)"
  [[ -z "$(conf_line sw)" ]]
  [[ -n "$(conf_line lw)" ]]
  snap=$(ls -d "$XDG_STATE_HOME/switch-claude/backups/"* | head -n 1)
  assert_contains "$out" "$snap"
  assert_eq "$(first_line "$snap/slot-sw.secret")" "$b"
}

test_remove_unknown_slot_fails() {
  two_slots
  local out
  out=$(expect_fail remove nope)
  assert_contains "$out" "unknown slot"
}

test_remove_active_slot_warns() {
  two_slots
  local out
  out=$(run_sc remove lw)
  assert_contains "$out" "no longer in any slot"
}

test_rename_moves_slot() {
  two_slots
  local a out
  a=$(get_slot lw)
  out=$(run_sc rename lw work)
  assert_contains "$out" "Renamed slot lw → work"
  assert_eq "$(get_slot work)" "$a"
  assert_absent "$(slot_path lw)"
  assert_eq "$(conf_line work)" "work oauth $A_EMAIL $A_UUID"
  [[ -z "$(conf_line lw)" ]]
}

test_rename_refusals() {
  two_slots
  local out before
  before=$(get_slot lw)
  out=$(expect_fail rename lw sw);    assert_contains "$out" "already exists"
  out=$(expect_fail rename nope x);   assert_contains "$out" "unknown slot"
  out=$(expect_fail rename lw status)
  assert_eq "$(get_slot lw)" "$before"
  [[ -n "$(conf_line lw)" ]]
}

test_rename_updates_pending_target() {
  two_slots
  run_sc login sw >/dev/null
  run_sc rename sw bob2 >/dev/null
  local out
  out=$(run_sc status)
  assert_contains "$out" "Pending login: bob2"
}

test_config_permissions() {
  local a
  a=$(fresh alice); set_active "$a"; set_current_email "$A_EMAIL" "$A_UUID"
  run_sc add lw >/dev/null
  assert_mode "$CONF" 700
  assert_mode "$CONF/slots.conf" 600
  if [[ "$SWITCH_CLAUDE_PLATFORM" == linux ]]; then
    assert_mode "$CONF/creds" 700
    assert_mode "$CONF/creds/lw" 600
  fi
}

# --- B. switching (oauth) ----------------------------------------------------------

test_switch_installs_credentials_and_metadata() {
  two_slots
  local out
  out=$(run_sc sw)
  assert_contains "$out" "Switched to sw ($B_EMAIL)"
  assert_eq "$(get_active)" "$(get_slot sw)"
  assert_eq "$(current_field emailAddress)" "$B_EMAIL"
  assert_eq "$(current_field accountUuid)" "$B_UUID"
  python3 -c 'import json,os,sys; assert json.load(open(os.path.expanduser("~/.claude.json")))["unrelated"]["keep"]'
}

test_switch_saves_rotated_credentials_back() {
  two_slots
  local rotated
  rotated=$(fresh alice-rotated)
  set_active "$rotated"
  run_sc sw >/dev/null
  assert_eq "$(get_slot lw)" "$rotated"
}

test_switch_to_refreshable_slot_succeeds() {
  two_slots
  set_slot sw "$(refreshable bob)"
  run_sc sw >/dev/null
  assert_eq "$(get_active)" "$(get_slot sw)"
}

test_switch_to_dead_slot_needs_force() {
  two_slots
  set_slot sw "$(dead bob)"
  local out a
  a=$(get_active)
  out=$(expect_fail sw)
  assert_contains "$out" "fully expired"
  assert_contains "$out" "switch-claude login sw"
  assert_eq "$(get_active)" "$a"
  run_sc sw --force >/dev/null
  assert_eq "$(get_active)" "$(get_slot sw)"
}

test_switch_to_empty_slot_refuses() {
  two_slots
  rm -f "$(slot_path sw)"
  local out a
  a=$(get_active)
  out=$(expect_fail sw)
  assert_contains "$out" "switch-claude login sw"
  assert_eq "$(get_active)" "$a"
}

test_switch_unknown_slot_fails() {
  two_slots
  local out
  out=$(expect_fail nope)
  assert_contains "$out" "unknown slot 'nope'"
}

test_unsaved_login_is_never_overwritten() {
  two_slots
  local stranger argv out
  stranger=$(fresh stranger)
  for argv in "sw" "lw" "login sw" "refresh sw" "refresh --all"; do
    set_active "$stranger"
    set_current_email "stranger@example.com"
    set_slot sw "$(refreshable bob)"
    rm -f "$PENDING"
    export CLAUDE_REFRESH_LABEL=x
    # shellcheck disable=SC2086
    out=$(expect_fail $argv)
    unset CLAUDE_REFRESH_LABEL
    assert_contains "$out" "not in any slot"
    assert_eq "$(get_active)" "$stranger"
    assert_eq "$(current_field emailAddress)" "stranger@example.com"
    assert_absent "$PENDING"
  done
}

test_switch_away_from_dead_unknown_login_is_allowed() {
  two_slots
  set_active "$(dead stranger)"
  set_current_email "stranger@example.com"
  run_sc lw >/dev/null
  assert_eq "$(get_active)" "$(get_slot lw)"
}

test_metadata_mismatch_does_not_corrupt_other_slot() {
  two_slots
  # .claude.json says alice, but the active credential is bob's.
  set_active "$(get_slot sw)"
  local a
  a=$(get_slot lw)
  run_sc sw >/dev/null
  assert_eq "$(get_slot lw)" "$a"
}

test_switch_to_oauth_turns_off_token_mode() {
  two_slots
  add_token_slot hub "$TOKEN_OK"
  printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n' "$TOKEN_OK" > "$TOKEN_ENV"
  local out
  out=$(run_sc sw)
  assert_eq "$(cat "$TOKEN_ENV")" "CLAUDE_CODE_OAUTH_TOKEN="
  assert_contains "$out" "Token mode turned off"
}

test_post_switch_hook_runs() {
  two_slots
  local hook="$TEST_HOME/hook.sh" out
  printf '#!/usr/bin/env bash\nenv | grep ^SWITCH_CLAUDE_ > "%s/hook.out"\n' "$TEST_HOME" > "$hook"
  chmod +x "$hook"
  conf_set post_switch_hook "$hook"
  run_sc sw >/dev/null
  assert_contains "$(cat "$TEST_HOME/hook.out")" "SWITCH_CLAUDE_SLOT=sw"
  assert_contains "$(cat "$TEST_HOME/hook.out")" "SWITCH_CLAUDE_TYPE=oauth"
  printf '#!/usr/bin/env bash\nexit 7\n' > "$hook"
  out=$(expect_fail lw)
  assert_contains "$out" "post-switch hook failed"
  assert_eq "$(get_active)" "$(get_slot lw)"
}

# --- C. login / save / sync / refresh -------------------------------------------------

test_login_prepares_pending() {
  two_slots
  local out a
  a=$(get_active)
  out=$(run_sc login sw)
  assert_contains "$out" "Log in as: $B_EMAIL"
  assert_eq "$(get_active)" ""
  assert_mode "$PENDING" 600
  python3 - "$PENDING" <<'PY'
import json, sys
raw = open(sys.argv[1]).read()
d = json.loads(raw)
assert d["target"] == "sw" and len(d["fingerprint"]) == 64
assert "access-" not in raw and "refresh-" not in raw
PY
  assert_eq "$(get_slot lw)" "$a"
}

test_login_no_browser_runs_auth_login() {
  two_slots
  run_sc login sw --no-browser >/dev/null
  assert_contains "$(cat "$CLAUDE_CALL_LOG")" "args=auth login --claudeai --email $B_EMAIL"
  assert_contains "$(cat "$CLAUDE_CALL_LOG")" "BROWSER=true"
  rm -f "$CLAUDE_CALL_LOG" "$PENDING"
  set_active "$(get_slot lw)"
  conf_set login_args "--sso"
  run_sc login sw --no-browser >/dev/null
  assert_contains "$(cat "$CLAUDE_CALL_LOG")" "args=auth login --claudeai --sso --email $B_EMAIL"
}

test_save_completes_pending_login() {
  two_slots
  conf_slots "lw oauth $A_EMAIL $A_UUID" "sw oauth $B_EMAIL -"
  run_sc login sw >/dev/null
  local b2 out
  b2=$(fresh bob-new)
  set_active "$b2"
  set_current_email "$B_EMAIL" "$B_UUID"
  out=$(run_sc save)
  assert_contains "$out" "Saved fresh login into sw"
  assert_eq "$(get_slot sw)" "$b2"
  assert_absent "$PENDING"
  assert_eq "$(conf_line sw)" "sw oauth $B_EMAIL $B_UUID"
}

test_save_pending_refusals() {
  two_slots
  run_sc login sw >/dev/null
  local out before
  before=$(get_slot sw)
  out=$(expect_fail save)
  assert_contains "$out" "Pending login for sw is incomplete"
  # wrong account logged in
  set_active "$(fresh mallory)"
  set_current_email "mallory@example.com"
  out=$(expect_fail save)
  assert_contains "$out" "expected '$B_EMAIL'"
  assert_eq "$(get_slot sw)" "$before"
  [[ -f "$PENDING" ]]
}

test_save_pending_matching_other_slot_restarts_login() {
  two_slots
  run_sc login sw >/dev/null
  set_active "$(get_slot lw)"
  set_current_email "$B_EMAIL"
  local out before
  before=$(get_slot sw)
  out=$(run_sc save)
  assert_contains "$out" "still match lw"
  assert_contains "$out" "Log in as: $B_EMAIL"
  assert_eq "$(get_slot sw)" "$before"
  assert_eq "$(get_active)" ""
}

test_save_named_captures_into_slot() {
  two_slots
  local b2 out
  b2=$(fresh bob-new)
  set_active "$b2"; set_current_email "$B_EMAIL" "$B_UUID"
  run_sc save sw >/dev/null
  assert_eq "$(get_slot sw)" "$b2"
  out=$(expect_fail save lw)
  assert_contains "$out" "expected '$A_EMAIL'"
}

test_sync_stores_rotated_credentials() {
  two_slots
  local rotated out
  rotated=$(fresh alice-rotated)
  set_active "$rotated"
  out=$(run_sc sync)
  assert_contains "$out" "lw"
  assert_eq "$(get_slot lw)" "$rotated"
  out=$(run_sc sync)
  assert_contains "$out" "already current"
}

test_sync_unknown_login_fails() {
  two_slots
  set_active "$(fresh stranger)"; set_current_email "stranger@example.com"
  local out
  out=$(expect_fail sync)
  assert_contains "$out" "not a known slot"
}

test_login_token_slot_refused() {
  two_slots
  set_slot hub "$TOKEN_OK"; printf 'hub token - -\n' >> "$CONF/slots.conf"
  local out
  out=$(expect_fail login hub)
  assert_contains "$out" "token slot"
}

test_login_turns_off_token_mode() {
  two_slots
  add_token_slot hub "$TOKEN_OK"
  printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n' "$TOKEN_OK" > "$TOKEN_ENV"
  local out
  out=$(run_sc login sw)
  assert_eq "$(cat "$TOKEN_ENV")" "CLAUDE_CODE_OAUTH_TOKEN="
  assert_contains "$out" "Token mode turned off"
}

test_refresh_rotates_and_saves() {
  two_slots
  set_slot sw "$(refreshable bob)"
  export CLAUDE_REFRESH_LABEL=bob CLAUDE_CODE_OAUTH_TOKEN="$TOKEN_OK"
  local out
  out=$(run_sc refresh sw)
  unset CLAUDE_REFRESH_LABEL CLAUDE_CODE_OAUTH_TOKEN
  assert_contains "$out" "Refreshed sw"
  assert_contains "$(get_slot sw)" "access-refreshed-bob"
  assert_contains "$(cat "$CLAUDE_CALL_LOG")" "args=-p ok"
  assert_contains "$(cat "$CLAUDE_CALL_LOG")" "env_token=<unset>"
}

test_refresh_skips_what_cannot_or_need_not_refresh() {
  two_slots
  set_slot hub "$TOKEN_OK"; printf 'hub token - -\n' >> "$CONF/slots.conf"
  local out
  out=$(run_sc refresh lw);  assert_contains "$out" "nothing to refresh"
  out=$(run_sc refresh hub); assert_contains "$out" "token slot"
  assert_absent "$CLAUDE_CALL_LOG"
}

test_refresh_without_rotation_fails_and_restores() {
  two_slots
  set_slot sw "$(refreshable bob)"
  local a out
  a=$(get_active)
  out=$(expect_fail refresh sw)
  assert_contains "$out" "byte-identical"
  assert_eq "$(get_active)" "$a"
  assert_eq "$(current_field emailAddress)" "$A_EMAIL"
}

test_cancel_clears_pending() {
  two_slots
  run_sc login sw >/dev/null
  local out
  out=$(run_sc cancel)
  assert_contains "$out" "Cancelled pending login for sw"
  assert_absent "$PENDING"
}

test_pending_for_unknown_slot_is_discarded() {
  two_slots
  mkdir -p "$CONF"
  printf '{"target": "gone", "fingerprint": "%064d"}\n' 0 > "$PENDING"
  local out
  out=$(expect_fail save)
  assert_contains "$out" "unknown pending login target 'gone'"
  assert_absent "$PENDING"
}

# --- D. token mode -----------------------------------------------------------------

test_switch_to_token_slot_writes_env_file() {
  two_slots
  add_token_slot hub "$TOKEN_OK"
  local a out
  a=$(get_active)
  out=$(run_sc hub)
  assert_contains "$out" "Switched to hub (token)"
  assert_eq "$(cat "$TOKEN_ENV")" "CLAUDE_CODE_OAUTH_TOKEN=$TOKEN_OK"
  assert_mode "$TOKEN_ENV" 600
  assert_eq "$(get_active)" "$a"
  assert_not_contains "$(cat "$CURL_CALL_LOG")" "$TOKEN_OK"
  assert_contains "$(cat "$CURL_CALL_LOG")" "token_via_stdin=yes"
  assert_not_contains "$out" "$TOKEN_OK"
  out=$(run_sc status)
  assert_contains "$out" "Mode: token"
  assert_contains "$(slot_line "$out" hub)" "* hub"
}

# A token in the env file that no slot holds would be lost for good if a switch
# overwrote or emptied the file. Same rule as an unsaved oauth login.
test_unsaved_env_token_is_not_discarded() {
  two_slots
  add_token_slot hub "$TOKEN_DEAD"
  mkdir -p "$CONF"
  printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n' "$TOKEN_OK" > "$TOKEN_ENV"
  local argv out
  for argv in "sw" "login sw" "hub --force"; do
    rm -f "$PENDING"
    # shellcheck disable=SC2086
    out=$(expect_fail $argv)
    assert_contains "$out" "not in any slot"
    assert_eq "$(cat "$TOKEN_ENV")" "CLAUDE_CODE_OAUTH_TOKEN=$TOKEN_OK"
    assert_not_contains "$out" "$TOKEN_OK"
  done
  # The hint works: the env file itself can be fed to `add --token`.
  run_sc add keep --token < "$TOKEN_ENV" >/dev/null
  assert_eq "$(get_slot keep)" "$TOKEN_OK"
  run_sc sw >/dev/null
  assert_eq "$(cat "$TOKEN_ENV")" "CLAUDE_CODE_OAUTH_TOKEN="
}

test_switch_to_dead_token_refused_unless_forced() {
  two_slots
  add_token_slot hub "$TOKEN_DEAD"
  local out
  out=$(expect_fail hub)
  assert_contains "$out" "HTTP 401"
  assert_absent "$TOKEN_ENV"
  rm -f "$CURL_CALL_LOG"
  run_sc hub --force >/dev/null
  assert_eq "$(cat "$TOKEN_ENV")" "CLAUDE_CODE_OAUTH_TOKEN=$TOKEN_DEAD"
  assert_absent "$CURL_CALL_LOG"
}

test_switch_to_ratelimited_token_needs_force_when_non_interactive() {
  two_slots
  add_token_slot hub "$TOKEN_RL"
  local out
  out=$(expect_fail hub </dev/null)
  assert_contains "$out" "429"
  assert_contains "$out" "--force"
  assert_absent "$TOKEN_ENV"
}

test_token_env_path_is_configurable() {
  two_slots
  add_token_slot hub "$TOKEN_OK"
  # shellcheck disable=SC2088  # the config file holds a literal "~"
  conf_set token_env_file "~/.config/claude-code/oauth-token"
  run_sc hub >/dev/null
  assert_eq "$(cat "$HOME/.config/claude-code/oauth-token")" "CLAUDE_CODE_OAUTH_TOKEN=$TOKEN_OK"
  assert_absent "$TOKEN_ENV"
}

test_status_warns_about_foreign_env_token() {
  two_slots
  export CLAUDE_CODE_OAUTH_TOKEN="fake-token-from-somewhere-else-DDDDDDDDDDDDDDDDDDDDDDDDDD"
  local out
  out=$(run_sc status)
  unset CLAUDE_CODE_OAUTH_TOKEN
  assert_contains "$out" "WARNING"
  assert_contains "$out" "CLAUDE_CODE_OAUTH_TOKEN"
  assert_not_contains "$out" "from-somewhere-else"
}

test_status_probe_reports_usage() {
  two_slots
  set_slot sw "$(refreshable bob)"
  add_token_slot hub "$TOKEN_OK"
  local out
  out=$(run_sc status --probe)
  assert_contains "$(slot_line "$out" hub)" "HTTP 200"
  assert_contains "$(slot_line "$out" hub)" "5h 0.34"
  assert_contains "$(slot_line "$out" hub)" "7d 0.12"
  assert_contains "$(slot_line "$out" lw)" "HTTP 200"
  assert_contains "$(slot_line "$out" sw)" "not probed"
  assert_not_contains "$(cat "$CURL_CALL_LOG")" "access-"
}

test_status_without_probe_is_offline() {
  two_slots
  add_token_slot hub "$TOKEN_OK"
  run_sc status >/dev/null
  assert_absent "$CURL_CALL_LOG"
}

test_status_shows_active_oauth_slot() {
  two_slots
  local out
  out=$(run_sc status)
  assert_contains "$out" "Mode: oauth"
  assert_contains "$(slot_line "$out" lw)" "* lw"
  assert_contains "$(slot_line "$out" lw)" "✓"
  assert_contains "$(slot_line "$out" sw)" "  sw"
}

# --- E. backup / restore -----------------------------------------------------------

test_backup_snapshot() {
  two_slots
  add_token_slot hub "$TOKEN_OK"
  local out snap
  out=$(run_sc backup)
  snap=$(ls -d "$XDG_STATE_HOME/switch-claude/backups/"* | head -n 1)
  assert_contains "$out" "$snap"
  assert_mode "$snap" 700
  for f in slot-lw.secret slot-sw.secret slot-hub.secret slots.conf MANIFEST.txt; do
    [[ -f "$snap/$f" ]] || { printf 'missing %s\n' "$f" >&2; return 1; }
  done
  assert_mode "$snap/slot-lw.secret" 600
  assert_not_contains "$(cat "$snap/MANIFEST.txt")" "access-"
  assert_not_contains "$(cat "$snap/MANIFEST.txt")" "$TOKEN_OK"
}

test_backup_refuses_git_work_tree() {
  two_slots
  mkdir -p "$HOME/repo/.git"
  conf_set backup_dir "$HOME/repo/backups"
  local out
  out=$(expect_fail backup)
  assert_contains "$out" "git work tree"
}

test_restore_dry_run_then_apply() {
  two_slots
  local b out snap
  b=$(get_slot sw)
  run_sc remove sw >/dev/null
  snap=$(ls -d "$XDG_STATE_HOME/switch-claude/backups/"* | head -n 1)
  out=$(run_sc restore "$snap")
  assert_contains "$out" "DRY RUN"
  assert_contains "$out" "sw"
  assert_absent "$(slot_path sw)"
  out=$(run_sc restore "$snap" --apply sw)
  assert_eq "$(get_slot sw)" "$b"
  assert_eq "$(conf_line sw)" "sw oauth $B_EMAIL $B_UUID"
  assert_eq "$(conf_line lw)" "lw oauth $A_EMAIL $A_UUID"
}


# --- F. review round 1 (2026-10-11) ---------------------------------------------------

# Refreshing the slot that is currently active rotates its token. Putting the
# pre-refresh credential back as the active login would install a voided token, and
# the next switch would store that dead copy over the good one.
test_refresh_of_active_slot_keeps_the_refreshed_login() {
  two_slots
  local a
  a=$(refreshable alice)
  set_slot lw "$a"; set_active "$a"
  export CLAUDE_REFRESH_LABEL=alice
  run_sc refresh lw >/dev/null
  unset CLAUDE_REFRESH_LABEL
  assert_contains "$(get_slot lw)" "access-refreshed-alice"
  assert_eq "$(get_active)" "$(get_slot lw)"
  run_sc sw >/dev/null
  assert_contains "$(get_slot lw)" "access-refreshed-alice"
}

# Rotation only ever moves expiresAt forward, so an active credential that expires
# earlier than the slot's copy is not that slot's latest; storing it would replace
# a newer credential with an older one.
test_older_active_credential_never_overwrites_newer_slot() {
  two_slots
  local newer older out
  newer=$(creds alice-newer 7200 604800)
  older=$(creds alice-older 1800 604800)
  set_slot lw "$newer"; set_active "$older"
  out=$(expect_fail sw)
  assert_contains "$out" "newer"
  assert_eq "$(get_slot lw)" "$newer"
  assert_eq "$(get_active)" "$older"
  out=$(expect_fail sync)
  assert_eq "$(get_slot lw)" "$newer"
}

make_slot_unreadable() {
  if [[ "$SWITCH_CLAUDE_PLATFORM" == macos ]]; then
    export MOCK_SECURITY_FAIL_FIND="$1"
  else
    chmod 000 "$(slot_path "$1")"
  fi
}

test_remove_refuses_when_slot_cannot_be_read() {
  two_slots
  local out
  make_slot_unreadable sw
  out=$(expect_fail remove sw)
  unset MOCK_SECURITY_FAIL_FIND
  chmod 600 "$(slot_path sw)" 2>/dev/null || true
  [[ -n "$(get_slot sw)" ]]
  [[ -n "$(conf_line sw)" ]]
}

test_backup_fails_when_a_slot_cannot_be_read() {
  two_slots
  make_slot_unreadable sw
  local out
  out=$(expect_fail backup)
  assert_contains "$out" "sw"
  # A half-written snapshot would leave plaintext copies behind.
  [[ -z "$(ls -A "$XDG_STATE_HOME/switch-claude/backups/" 2>/dev/null)" ]] || {
    printf 'partial snapshot left behind: %s\n' "$(ls "$XDG_STATE_HOME/switch-claude/backups/")" >&2; return 1; }
}

test_rename_refuses_when_slot_cannot_be_read() {
  two_slots
  make_slot_unreadable sw
  local out
  out=$(expect_fail rename sw bob2)
  unset MOCK_SECURITY_FAIL_FIND
  chmod 600 "$(slot_path sw)" 2>/dev/null || true
  [[ -n "$(conf_line sw)" ]]
  [[ -n "$(get_slot sw)" ]]
}

test_failed_keychain_update_keeps_old_value() {
  [[ "$SWITCH_CLAUDE_PLATFORM" == macos ]] || return 0
  two_slots
  local old rotated out
  old=$(get_slot lw)
  rotated=$(creds alice-rotated 7200 604800)
  set_active "$rotated"
  export MOCK_SECURITY_FAIL_ADD=lw
  out=$(expect_fail sync)
  unset MOCK_SECURITY_FAIL_ADD
  assert_eq "$(get_slot lw)" "$old"
}

# The env file is sourced by shells, so a token is only ever written if it is made
# of characters that cannot do anything there.
test_tokens_with_shell_metacharacters_are_refused() {
  two_slots
  local bad out
  for bad in 'fake-token-$(touch /tmp/pwned)-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA' \
             'fake-token-`id`-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA' \
             'fake-token;id;AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'; do
    if out=$(printf '%s\n' "$bad" | "$SC" add hub --token 2>&1); then
      printf 'accepted unsafe token [%s]\n' "$bad" >&2; return 1
    fi
  done
  # A slot that got an unsafe token some other way is still not written out.
  add_token_slot evil 'fake-token-$(id)-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
  out=$(expect_fail evil --force)
  assert_absent "$TOKEN_ENV"
}

test_restore_backs_up_slots_it_replaces() {
  two_slots
  local snap current out
  run_sc backup >/dev/null
  snap=$(ls -d "$XDG_STATE_HOME/switch-claude/backups/"* | head -n 1)
  current=$(creds alice-current 7200 604800)
  set_slot lw "$current"
  out=$(run_sc restore "$snap" --apply lw)
  assert_contains "$out" "backup"
  [[ "$(ls -d "$XDG_STATE_HOME/switch-claude/backups/"* | wc -l | tr -d ' ')" -eq 2 ]]
  grep -rqF "$current" "$XDG_STATE_HOME/switch-claude/backups/"
}

test_credentials_never_travel_through_the_environment() {
  two_slots
  add_token_slot hub "$TOKEN_OK"
  run_sc status --probe >/dev/null
  run_sc sw >/dev/null
  run_sc backup >/dev/null
  run_sc sync >/dev/null
  assert_absent "$PY_ENV_LOG"
}

# --- runner ------------------------------------------------------------------------

ALL_TESTS=$(declare -F | awk '{print $3}' | grep '^test_')
filter="${1:-}"
failures=0; count=0
for platform in ${TEST_PLATFORMS:-macos linux}; do
  export SWITCH_CLAUDE_PLATFORM="$platform"
  for t in $ALL_TESTS; do
    [[ -z "$filter" || "$t" == *"$filter"* ]] || continue
    count=$((count + 1))
    # Calling a test inside `if` would switch off set -e for its whole body, so only
    # its last command would count. Run it in a subshell outside any condition.
    set +e
    ( set -e; reset_state; "$t" ) > "$TEST_HOME/last.log" 2>&1
    rc=$?
    set -e
    if [[ "$rc" -eq 0 ]]; then
      printf 'PASS [%s] %s\n' "$platform" "$t"
    else
      printf 'FAIL [%s] %s\n' "$platform" "$t"
      sed 's/^/    /' "$TEST_HOME/last.log" | tail -n 15
      failures=$((failures + 1))
    fi
  done
done

printf '\n%d run, %d failed\n' "$count" "$failures"
[[ "$failures" -eq 0 ]]
