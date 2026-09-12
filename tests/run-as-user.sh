#!/usr/bin/env bash
#
# Isolated checks for the session-account layer (RUN_AS_USER), run against
# bin/claude-guardian.sh without installing anything.
#
#   bash tests/run-as-user.sh
#
# It sources the script with its final `main "$@"` stripped and calls
# individual functions with overridden globals, so nothing here touches
# /etc, /var/lib, systemd, or a live tmux session. Generated files go to a
# mktemp directory that is removed on exit.
#
# Run it as an ordinary (non-root) account: the point of most of these cases
# is the difference between root and everybody else.

# SC2034: the globals set here are read by the sourced script, not by this
#   file — that is the whole point of the harness.
# SC2015: `grep ... && ok ... || bad ...` is safe here because ok/bad always
#   return 0, so the || branch only ever runs when the grep failed.
# SC1091: the config this checks is generated at run time, into a temp dir.
# shellcheck disable=SC2034,SC2015,SC1091

set -uo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SRC="$REPO/bin/claude-guardian.sh"
[ -r "$SRC" ] || { echo "cannot read $SRC"; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
sed '$d' "$SRC" > "$TMP/lib.sh"    # drop the trailing `main "$@"`

ME=$(id -un)
pass=0; fail=0; skip=0
ok()     { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad()    { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }
skipped(){ skip=$((skip+1)); printf '  skip  %s\n' "$1"; }
check()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }

# shellcheck disable=SC1091
. "$TMP/lib.sh"

if [ "$(id -u)" -eq 0 ]; then
  echo "NOTE: running as root — the cases that need an unprivileged account are skipped."
fi

echo "== resolve_run_as reads the account from passwd =="
RUN_AS_USER="$ME"
WORKDIR=""; CLAUDE_SESSIONS_DIR=""; CLAUDE_PROJECTS_DIR=""
unset WORKDIR_FROM_RUN_AS SESSIONS_DIR_FROM_RUN_AS PROJECTS_DIR_FROM_RUN_AS
resolve_run_as
want_home=$(getent passwd "$ME" | cut -d: -f6)
check "home"         "$RUN_AS_HOME"         "$want_home"
check "workdir"      "$WORKDIR"             "$want_home"
check "sessions dir" "$CLAUDE_SESSIONS_DIR" "$want_home/.claude/sessions"
check "projects dir" "$CLAUDE_PROJECTS_DIR" "$want_home/.claude/projects"

echo "== it is re-callable, because install may adopt \$SUDO_USER after the first call =="
RUN_AS_USER="root"; resolve_run_as
check "derived workdir follows the account" "$WORKDIR" "/root"
RUN_AS_USER="$ME"; resolve_run_as
check "and follows it back"                 "$WORKDIR" "$want_home"

echo "== a workdir the operator set is never overwritten =="
WORKDIR="/srv/thing"; unset WORKDIR_FROM_RUN_AS
RUN_AS_USER="$ME"; resolve_run_as
check "explicit workdir survives" "$WORKDIR" "/srv/thing"
WORKDIR=""; unset WORKDIR_FROM_RUN_AS; resolve_run_as

echo "== an account that does not exist is refused =="
out=$(bash -c '. "'"$TMP"'/lib.sh"; RUN_AS_USER=nosuchuser1234 resolve_run_as' 2>&1)
case "$out" in
  *"is not an account on this host"*) ok "the message names the problem" ;;
  *) bad "not refused: $out" ;;
esac

echo "== --dangerously-skip-permissions and root are refused together =="
RUN_AS_USER="root"; resolve_run_as
CLAUDE_ARGS="--dangerously-skip-permissions --remote-control"
out=$( (require_args_match_run_user) 2>&1 ); rc=$?
check "refused for root" "$rc" "1"
case "$out" in
  *"claude refuses to run as root"*) ok "and says why" ;;
  *) bad "wrong message: $out" ;;
esac
if [ "$ME" != root ]; then
  RUN_AS_USER="$ME"; resolve_run_as
  ( require_args_match_run_user ) >/dev/null 2>&1
  check "allowed for a non-root account" "$?" "0"
else
  skipped "allowed for a non-root account (running as root)"
fi
RUN_AS_USER="root"; resolve_run_as
CLAUDE_ARGS="--permission-mode auto --remote-control"
( require_args_match_run_user ) >/dev/null 2>&1
check "root with auto mode is fine" "$?" "0"
CLAUDE_ARGS="--append-system-prompt --dangerously-skip-permissions-not-really"
( require_args_match_run_user ) >/dev/null 2>&1
check "a mere substring does not trip it" "$?" "0"

echo "== claude_bin_is_absolute =="
CLAUDE_BIN="claude";        claude_bin_is_absolute; check "a bare name is not resolved" "$?" "1"
CLAUDE_BIN="/bin/sh";       claude_bin_is_absolute; check "an existing path is"         "$?" "0"
CLAUDE_BIN="/nope/claude";  claude_bin_is_absolute; check "a missing path is not"       "$?" "1"

echo "== the session owner's PATH is what gets searched =="
RUN_AS_USER="$ME"; resolve_run_as
check "resolves a binary as that account" "$(run_as_user_which sh)" "$(command -v sh)"
check "and finds nothing for one that does not exist" "$(run_as_user_which definitely-not-a-command-1234)" ""

echo "== the generated systemd unit =="
TMUX_SOCKET="/run/claude-guardian/tmux.sock"
UNIT_TEMPLATE_PATH="$TMP/unit"
write_unit_template >/dev/null
grep -qx "User=$ME" "$TMP/unit"                         && ok "User= is the session account"          || bad "User="
grep -qx 'RuntimeDirectory=claude-guardian' "$TMP/unit" && ok "RuntimeDirectory= for the /run socket" || bad "RuntimeDirectory"
grep -qx 'RuntimeDirectoryPreserve=yes' "$TMP/unit"     && ok "Preserve=yes, so a restart keeps tmux" || bad "RuntimeDirectoryPreserve"
grep -qx 'KillMode=process' "$TMP/unit"                 && ok "KillMode=process is still there"       || bad "KillMode"
TMUX_SOCKET="$TMP/sock/tmux.sock"
write_unit_template >/dev/null
if grep -q 'RuntimeDirectory' "$TMP/unit"; then
  bad "RuntimeDirectory emitted for a socket outside /run"
else
  ok "no RuntimeDirectory for a socket outside /run"
fi

echo "== the generated config =="
TMUX_SOCKET="/run/claude-guardian/tmux.sock"
CLAUDE_BIN="/usr/local/bin/claude"
CLAUDE_ARGS="--dangerously-skip-permissions --remote-control"
CONFIG_FILE="$TMP/config.env"
write_default_config >/dev/null
grep -qx "RUN_AS_USER=\"$ME\"" "$TMP/config.env" && ok "RUN_AS_USER is baked in" || bad "RUN_AS_USER"
grep -qx 'CLAUDE_ARGS="--dangerously-skip-permissions --remote-control"' "$TMP/config.env" \
  && ok "CLAUDE_ARGS is baked in" || bad "CLAUDE_ARGS"
grep -qx "WORKDIR=\"$want_home\"" "$TMP/config.env" && ok "WORKDIR is baked in" || bad "WORKDIR"
grep -q '^#CLAUDE_SESSIONS_DIR' "$TMP/config.env" \
  && ok "the claude dirs are left to the account" || bad "claude dirs"
if ( set -u; . "$TMP/config.env"; [ "$RUN_AS_USER" = "$ME" ] ); then
  ok "it sources cleanly"
else
  bad "it does not source cleanly"
fi
if grep -q '\\\$' "$TMP/config.env"; then
  bad "a stray backslash-dollar survived the heredoc"
else
  ok "no stray escapes"
fi
write_default_config 2>&1 | grep -q "leaving it untouched" \
  && ok "an existing config is left alone" || bad "an existing config was rewritten"

echo "== tmux targets are exact, so one instance cannot reach another's session =="
if grep -q 'tmux_cmd \(has-session\|list-clients\|kill-session\) -t "\$' "$SRC"; then
  bad "a session target is still inexact"
else
  ok "session targets are =name"
fi
if grep -q 'tmux_cmd \(list-panes\|capture-pane\|send-keys\|respawn-pane\|set-option\)[^|]* -t "=\$[A-Za-z0-9_]*"' "$SRC"; then
  bad "a pane or window target is missing its trailing ':'"
else
  ok "pane and window targets are =name:"
fi

echo
echo "$pass passed, $fail failed, $skip skipped"
[ "$fail" -eq 0 ]
