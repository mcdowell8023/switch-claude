#!/usr/bin/env bash
# Example post_switch_hook for Paseo (https://paseo.sh) users.
#
# A daemon's environment is a snapshot taken when it started, so agents it spawns
# keep using the old account until it restarts. This hook restarts it after every
# switch.
#
#   Linux  (systemd user unit "paseo", reading the token env file through
#          EnvironmentFile=): refuses while agents are running unless you confirm,
#          restarts the unit, then checks the daemon really loaded the new token.
#   macOS  (Paseo Desktop): stops the daemon; the desktop app starts it again.
#
# Enable it in ~/.config/switch-claude/config:
#   post_switch_hook = ~/.config/switch-claude/hooks/paseo-restart.sh
#
# switch-claude passes SWITCH_CLAUDE_SLOT, SWITCH_CLAUDE_TYPE (oauth|token) and
# SWITCH_CLAUDE_TOKEN_ENV_FILE. A non-zero exit is reported as a hook failure; the
# switch itself has already happened by then.
set -euo pipefail

command -v paseo >/dev/null 2>&1 || { echo "  paseo not installed; nothing to restart"; exit 0; }

if [[ "$(uname -s)" == Darwin ]]; then
  # Match the daemon by its own command line and never this script's (its path has
  # "paseo" in it too).
  pids=$(pgrep -f "paseo.*daemon" | grep -vx "$$" || true)
  if [[ -n "$pids" ]]; then
    # shellcheck disable=SC2086
    kill $pids 2>/dev/null || true
    echo "  ✓ Paseo daemon stopped; Paseo Desktop starts it again with the new account"
  else
    echo "  Paseo daemon not running"
  fi
  exit 0
fi

unit=paseo
systemctl --user cat "$unit" >/dev/null 2>&1 || { echo "  no systemd user unit '$unit'; nothing to restart"; exit 0; }

running=$(paseo agent ls 2>/dev/null | awk '/running/' | wc -l | tr -d ' ')
if [[ "$running" -gt 0 ]]; then
  echo "  $running Paseo agent(s) running; restarting the daemon interrupts them:"
  paseo agent ls 2>/dev/null | awk 'NR == 1 || /running/' | sed 's/^/    /'
  if [[ -t 0 ]]; then
    read -r -p "  Restart anyway? [y/N] " answer || true
    [[ "$answer" == y || "$answer" == Y ]] || { echo "  Not restarted. Restart later: systemctl --user restart $unit"; exit 1; }
  else
    echo "  Not restarted (no terminal to confirm). Restart later: systemctl --user restart $unit"
    exit 1
  fi
fi

systemctl --user restart "$unit"
sleep 4

# Compare what the daemon actually holds with what the env file says; never print it.
want=""
if [[ -f "${SWITCH_CLAUDE_TOKEN_ENV_FILE:-}" ]]; then
  want=$(sed -n 's/^CLAUDE_CODE_OAUTH_TOKEN=//p' "$SWITCH_CLAUDE_TOKEN_ENV_FILE" | tail -n 1)
fi
pid=$(systemctl --user show "$unit" -p MainPID --value)
have=$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | sed -n 's/^CLAUDE_CODE_OAUTH_TOKEN=//p' | tail -n 1)
if [[ "$have" == "$want" ]]; then
  echo "  ✓ $unit restarted and loaded the $SWITCH_CLAUDE_TYPE login for $SWITCH_CLAUDE_SLOT"
else
  echo "  ✗ $unit restarted but its CLAUDE_CODE_OAUTH_TOKEN does not match $SWITCH_CLAUDE_TOKEN_ENV_FILE." >&2
  echo "    Check that the unit has: EnvironmentFile=-$SWITCH_CLAUDE_TOKEN_ENV_FILE" >&2
  exit 1
fi
