#!/usr/bin/env bash
#
# claude-guardian — keeps a remotely-attachable Claude Code session alive.
#
# Two supervision layers:
#   1. Inside a detached tmux session: if the `claude` process exits (Ctrl+C,
#      crash, `exit`), the pane is respawned automatically.
#   2. A systemd unit (Restart=always) supervises this script itself, so a
#      reboot or the loop process dying is also recovered from.
#
# This script is self-contained: `install` embeds the systemd unit and the
# default config as heredocs, so copying this one file is enough to deploy.
#
# Usage: claude-guardian <command>
#   install     preflight checks, then install + enable the systemd service
#   uninstall   stop/disable the systemd service (session/config untouched)
#   start       systemctl start claude-guardian
#   stop        systemctl stop claude-guardian
#   restart     systemctl restart claude-guardian
#   status      systemctl status claude-guardian
#   attach      attach to the live tmux session (remote takeover)
#   logs        follow the service journal
#   check       run preflight checks only, report, make no changes
#   run         (internal) foreground supervision loop; used as ExecStart

set -uo pipefail

PROG_NAME="claude-guardian"
CONFIG_FILE="/etc/claude-guardian/config.env"
UNIT_PATH="/etc/systemd/system/claude-guardian.service"
INSTALL_BIN="/usr/local/bin/claude-guardian"

# ---- defaults (overridden by $CONFIG_FILE if present) ----------------------
SESSION_NAME="claude-code"
TMUX_SOCKET="/run/claude-guardian/tmux.sock"
WORKDIR="/root"
CLAUDE_BIN="claude"
CLAUDE_ARGS="--permission-mode auto --remote-control"
CHECK_INTERVAL_SEC="5"
REQUIRED_APT_PKGS="tmux"
# When nobody is attached (no tmux client) for this many seconds, send a bare
# Enter keystroke to clear any confirmation prompt auto mode fell back to
# after repeated classifier blocks. 0 disables. See DESIGN.md Known limitations.
UNATTENDED_NUDGE_SEC="300"
# When nobody is attached for this many seconds, proactively re-run
# /remote-control to refresh the connection — Anthropic's docs say a Remote
# Control session that can't reach the server for ~30 minutes needs a manual
# /remote-control to reconnect; refreshing well inside that window avoids
# ever hitting it. 0 disables.
REMOTE_CONTROL_REFRESH_SEC="1200"

if [ -r "$CONFIG_FILE" ]; then
  # shellcheck disable=SC1090
  . "$CONFIG_FILE"
fi

log() {
  echo "[$PROG_NAME] $(date '+%F %T') $*"
}

die() {
  log "ERROR: $*"
  exit 1
}

require_root() {
  [ "$(id -u)" -eq 0 ] || die "must be run as root"
}

# ---- preflight ---------------------------------------------------------

# Report-only: never mutates the system. Used by `check`.
preflight_report() {
  local ok=0

  echo "== apt dependencies =="
  local missing=()
  for pkg in $REQUIRED_APT_PKGS; do
    if dpkg -s "$pkg" >/dev/null 2>&1; then
      echo "  [ok]      $pkg"
    else
      echo "  [missing] $pkg"
      missing+=("$pkg")
    fi
  done
  [ ${#missing[@]} -eq 0 ] || ok=1

  echo "== claude CLI =="
  if command -v "$CLAUDE_BIN" >/dev/null 2>&1; then
    echo "  [ok]      $CLAUDE_BIN -> $(command -v "$CLAUDE_BIN")"
  else
    echo "  [missing] $CLAUDE_BIN not found on PATH"
    echo "            this tool does not install Claude Code; install it yourself first"
    ok=1
  fi

  echo "== login state (best-effort) =="
  local cred_found=0
  for f in "$HOME/.claude/.credentials.json" "$HOME/.config/claude/credentials.json" "$HOME/.claude.json"; do
    if [ -e "$f" ]; then
      echo "  [ok]      found $f"
      cred_found=1
    fi
  done
  if [ "$cred_found" -eq 0 ]; then
    echo "  [warn]    no known credential file found — claude may not be logged in yet"
    echo "            this does not block startup; run '$PROG_NAME attach' and log in interactively"
  fi

  return "$ok"
}

# Enforcing: auto-installs missing apt packages, hard-fails if claude is
# missing, only warns on login state. Used by `run` and `install`.
preflight_enforce() {
  require_root

  local missing=()
  for pkg in $REQUIRED_APT_PKGS; do
    dpkg -s "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
  done
  if [ ${#missing[@]} -gt 0 ]; then
    log "installing missing apt packages: ${missing[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get update -qq \
      || die "apt-get update failed"
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}" \
      || die "apt-get install failed for: ${missing[*]}"
  fi

  command -v "$CLAUDE_BIN" >/dev/null 2>&1 \
    || die "claude CLI not found (\$CLAUDE_BIN=$CLAUDE_BIN). This tool does not install Claude Code — install it first, then retry."

  local cred_found=0
  for f in "$HOME/.claude/.credentials.json" "$HOME/.config/claude/credentials.json" "$HOME/.claude.json"; do
    [ -e "$f" ] && cred_found=1
  done
  [ "$cred_found" -eq 1 ] || log "warning: no claude login credentials detected yet; run '$PROG_NAME attach' to log in interactively (this does not block the service)"
}

# ---- tmux session management -------------------------------------------

tmux_cmd() {
  tmux -S "$TMUX_SOCKET" "$@"
}

ensure_socket_dir() {
  install -d -m 0700 "$(dirname "$TMUX_SOCKET")"
}

session_exists() {
  tmux_cmd has-session -t "$SESSION_NAME" 2>/dev/null
}

pane_is_dead() {
  local dead
  dead=$(tmux_cmd list-panes -t "$SESSION_NAME" -F '#{pane_dead}' 2>/dev/null | head -n1)
  [ "$dead" = "1" ]
}

create_session() {
  log "creating tmux session '$SESSION_NAME' and starting claude"
  # shellcheck disable=SC2086
  tmux_cmd new-session -d -s "$SESSION_NAME" -n claude -c "$WORKDIR" -- "$CLAUDE_BIN" $CLAUDE_ARGS
  tmux_cmd set-option -t "$SESSION_NAME" remain-on-exit on
}

respawn_pane() {
  log "claude exited (Ctrl+C, crash, or manual exit) — respawning automatically"
  tmux_cmd respawn-pane -k -t "$SESSION_NAME"
}

has_attached_client() {
  [ -n "$(tmux_cmd list-clients -t "$SESSION_NAME" 2>/dev/null)" ]
}

# auto permission mode falls back to an interactive confirmation after
# repeated classifier blocks (3 in a row or 20 total, per Anthropic's docs).
# With nobody attached, that confirmation would otherwise sit forever.
# Sending a bare Enter accepts whatever is currently highlighted/default.
nudge_enter() {
  log "no attached client for ${UNATTENDED_NUDGE_SEC}s+ — sending Enter in case a prompt is stuck waiting for confirmation"
  tmux_cmd send-keys -t "$SESSION_NAME" Enter
}

# Remote Control sessions that can't reach the server for ~30 minutes need a
# manual /remote-control to reconnect (Anthropic docs). Refresh proactively,
# comfortably inside that window, so it's never actually hit.
refresh_remote_control() {
  log "no attached client for ${REMOTE_CONTROL_REFRESH_SEC}s+ — refreshing remote control connection"
  tmux_cmd send-keys -t "$SESSION_NAME" C-u
  tmux_cmd send-keys -t "$SESSION_NAME" "/remote-control" Enter
}

supervise_loop() {
  ensure_socket_dir
  log "supervision loop started: session=$SESSION_NAME socket=$TMUX_SOCKET interval=${CHECK_INTERVAL_SEC}s"

  local stop=0
  trap 'stop=1' TERM INT

  # Start the countdown from loop-start, not epoch 0 — otherwise a session
  # that's already alive and unattended when the loop (re)starts (e.g. a
  # systemd restart, or a reboot) triggers an immediate nudge/refresh
  # instead of waiting out the configured interval first.
  local last_nudge last_refresh
  last_nudge=$(date +%s)
  last_refresh=$(date +%s)

  while [ "$stop" -eq 0 ]; do
    if ! session_exists; then
      create_session
      last_nudge=$(date +%s)
      last_refresh=$(date +%s)
    elif pane_is_dead; then
      respawn_pane
    elif has_attached_client; then
      # someone is live in the session — never nudge/refresh while attended,
      # and reset the timers so a nudge doesn't fire right after they leave
      last_nudge=$(date +%s)
      last_refresh=$(date +%s)
    else
      local now
      now=$(date +%s)
      if [ "$UNATTENDED_NUDGE_SEC" -gt 0 ] && [ $(( now - last_nudge )) -ge "$UNATTENDED_NUDGE_SEC" ]; then
        nudge_enter
        last_nudge=$now
      fi
      if [ "$REMOTE_CONTROL_REFRESH_SEC" -gt 0 ] && [ $(( now - last_refresh )) -ge "$REMOTE_CONTROL_REFRESH_SEC" ]; then
        refresh_remote_control
        last_refresh=$now
      fi
    fi
    sleep "$CHECK_INTERVAL_SEC" &
    wait $! 2>/dev/null
  done

  log "stop signal received — supervision loop exiting (tmux session left running, still attachable)"
}

# ---- systemd unit / config templates -----------------------------------

write_default_config() {
  if [ -e "$CONFIG_FILE" ]; then
    log "config already exists at $CONFIG_FILE, leaving it untouched"
    return
  fi
  install -d -m 0755 "$(dirname "$CONFIG_FILE")"
  cat > "$CONFIG_FILE" <<'EOF'
# claude-guardian runtime configuration.
# Edit values here, then: systemctl restart claude-guardian

# tmux session name that hosts the claude process
SESSION_NAME="claude-code"

# tmux server socket path (kept off the default /tmp socket on purpose)
TMUX_SOCKET="/run/claude-guardian/tmux.sock"

# working directory claude starts in
WORKDIR="/root"

# claude executable; override with an absolute path if it is not on
# systemd's PATH (check with `command -v claude` as root)
CLAUDE_BIN="claude"

# extra arguments passed to claude on every (re)start.
# --permission-mode auto: use the auto-mode classifier instead of manual
#   per-action approval (still safer than --dangerously-skip-permissions).
# --remote-control: prints a claude.ai/code/... URL you can control the
#   session from on the web or phone, independent of SSH.
CLAUDE_ARGS="--permission-mode auto --remote-control"

# seconds between liveness checks
CHECK_INTERVAL_SEC="5"

# space-separated apt package names auto-installed if missing
REQUIRED_APT_PKGS="tmux"

# when nobody is attached (no tmux client) this many seconds, send a bare
# Enter to clear a confirmation prompt auto mode may have fallen back to.
# 0 disables.
UNATTENDED_NUDGE_SEC="300"

# when nobody is attached this many seconds, proactively re-run
# /remote-control to refresh the connection before Anthropic's ~30-minute
# "could not reach the Remote Control server" threshold is ever hit.
# 0 disables.
REMOTE_CONTROL_REFRESH_SEC="1200"
EOF
  log "wrote default config to $CONFIG_FILE"
}

write_unit_file() {
  cat > "$UNIT_PATH" <<EOF
[Unit]
Description=Claude Code guardian (keeps a remotely-attachable claude session alive)
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=60
StartLimitBurst=10

[Service]
Type=simple
ExecStart=$INSTALL_BIN run
Restart=always
RestartSec=5
User=root
# Only signal the tracked loop PID on stop/restart, not the whole cgroup —
# the tmux server (and claude inside it) must survive a supervisor restart.
KillMode=process
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
  log "wrote systemd unit to $UNIT_PATH"
}

# ---- commands -----------------------------------------------------------

cmd_check() {
  if preflight_report; then
    log "all checks passed"
  else
    log "one or more checks need attention (see above)"
  fi
}

cmd_run() {
  preflight_enforce
  supervise_loop
}

cmd_install() {
  preflight_enforce
  write_default_config
  # re-source in case this is a first install and defaults above differ
  # shellcheck disable=SC1090
  [ -r "$CONFIG_FILE" ] && . "$CONFIG_FILE"

  if [ "$(readlink -f "$0" 2>/dev/null || echo "$0")" != "$INSTALL_BIN" ]; then
    install -m 0755 "$0" "$INSTALL_BIN"
    log "installed script to $INSTALL_BIN"
  fi

  write_unit_file
  systemctl daemon-reload
  systemctl enable claude-guardian.service
  log "install complete. Start it with: $PROG_NAME start"
}

cmd_uninstall() {
  require_root
  systemctl disable --now claude-guardian.service 2>/dev/null || true
  rm -f "$UNIT_PATH"
  systemctl daemon-reload
  log "systemd service removed. Config ($CONFIG_FILE) and any running tmux session were left untouched."
  log "to also remove the config: rm -rf $(dirname "$CONFIG_FILE")"
  log "to also kill the live session: tmux -S $TMUX_SOCKET kill-session -t $SESSION_NAME"
}

cmd_attach() {
  command -v tmux >/dev/null 2>&1 || die "tmux not installed"
  session_exists || die "no live session '$SESSION_NAME' on socket $TMUX_SOCKET (is the service running?)"
  log "attaching — detach with the tmux prefix + d (NOT Ctrl+C, which restarts claude instead)"
  exec tmux -S "$TMUX_SOCKET" attach -t "$SESSION_NAME"
}

cmd_logs() {
  exec journalctl -u claude-guardian -f "$@"
}

usage() {
  sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
}

main() {
  local cmd="${1:-}"
  shift || true
  case "$cmd" in
    install)   cmd_install "$@" ;;
    uninstall) cmd_uninstall "$@" ;;
    start)     require_root; systemctl start claude-guardian ;;
    stop)      require_root; systemctl stop claude-guardian ;;
    restart)   require_root; systemctl restart claude-guardian ;;
    status)    systemctl status claude-guardian "$@" ;;
    attach)    cmd_attach ;;
    logs)      cmd_logs "$@" ;;
    check)     cmd_check ;;
    run)       cmd_run ;;
    *)         usage; exit 1 ;;
  esac
}

main "$@"
