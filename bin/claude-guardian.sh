#!/usr/bin/env bash
#
# claude-guardian — keeps a remotely-attachable Claude Code session alive.
# Copyright (C) 2026 CharlesGool
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See the LICENSE file, or
# <https://www.gnu.org/licenses/>, for the full text.
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
#   purge       full teardown: uninstall + kill session + remove config/binary
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

# Authoritative login check (not a file-existence guess): `claude auth
# status` exits 0 when logged in, 1 when not — verified directly against
# both states, including under an isolated HOME with no credentials at all.
is_logged_in() {
  "$CLAUDE_BIN" auth status >/dev/null 2>&1
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
    local login_resolved
    login_resolved=$(bash -ic "command -v -- '$CLAUDE_BIN'" 2>/dev/null || true)
    if [ -n "$login_resolved" ]; then
      echo "  [warn]    $CLAUDE_BIN not on this shell's PATH, but resolvable via an interactive login shell: $login_resolved"
      echo "            run/install will pick this up automatically; consider setting CLAUDE_BIN to it explicitly"
    else
      echo "  [missing] $CLAUDE_BIN not found on PATH (current shell or interactive login shell)"
      echo "            this tool does not install Claude Code; install it yourself first"
      ok=1
    fi
  fi

  echo "== login state =="
  if ! command -v "$CLAUDE_BIN" >/dev/null 2>&1; then
    echo "  [skip]    can't check — claude CLI not found (see above)"
  elif is_logged_in; then
    echo "  [ok]      $CLAUDE_BIN auth status reports logged in"
  else
    echo "  [missing] $CLAUDE_BIN auth status reports not logged in"
    echo "            'install' refuses to proceed until this is fixed: run '$CLAUDE_BIN auth login' first"
    ok=1
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

  if ! command -v "$CLAUDE_BIN" >/dev/null 2>&1; then
    # systemd's default PATH is minimal and commonly does NOT include where
    # claude actually lives (e.g. ~/.local/bin), even though it resolves
    # fine in an interactive shell. `bash -l` alone doesn't help: Debian's
    # default ~/.bashrc returns immediately for non-interactive shells
    # ([ -z "$PS1" ] && return), before ever reaching the PATH= line — this
    # was verified directly, not assumed. `-i` (interactive) is what
    # actually makes bash set $PS1 and run the rest of ~/.bashrc, so use
    # that combination instead; stderr is discarded since -i prints
    # terminal/job-control noise that doesn't affect the captured stdout.
    # Self-heals configs left with the bare "claude" default. See
    # DECISIONS.md for the deployment failure that surfaced this.
    local login_resolved
    login_resolved=$(bash -ic "command -v -- '$CLAUDE_BIN'" 2>/dev/null || true)
    if [ -n "$login_resolved" ]; then
      log "\$CLAUDE_BIN=$CLAUDE_BIN not on this shell's PATH, but resolved via an interactive login shell: $login_resolved"
      CLAUDE_BIN="$login_resolved"
    else
      die "claude CLI not found (\$CLAUDE_BIN=$CLAUDE_BIN, tried both the current and a login-shell PATH). This tool does not install Claude Code — install it first, then retry, or set CLAUDE_BIN to its absolute path in $CONFIG_FILE."
    fi
  fi

  is_logged_in || log "warning: claude is not logged in ('$CLAUDE_BIN auth status' failed); run '$PROG_NAME attach' to log in interactively (this does not block the running service — only 'install' hard-requires login)"
}

# Hard requirement for `install` only — deliberately not folded into
# preflight_enforce, which stays non-blocking on login state so an
# already-running service that later loses auth keeps retrying instead of
# refusing to start. Installing a guardian that has never once logged in
# would just sit respawning a session nobody can use yet, so that specific
# case is refused outright instead.
require_login() {
  is_logged_in \
    || die "claude is not logged in ('$CLAUDE_BIN auth status' failed). Log in first — run '$CLAUDE_BIN auth login', or 'claude' interactively — then retry install."
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

  # On a genuinely first-ever run, claude can show an onboarding/trust
  # screen that needs Enter to accept the default before it reaches the
  # normal prompt — observed needing two Enters, not one. An extra Enter
  # once claude is already at its normal prompt is a harmless no-op, so
  # send two rather than trying to detect exactly which screen is showing.
  sleep 2
  tmux_cmd send-keys -t "$SESSION_NAME" Enter
  sleep 1
  tmux_cmd send-keys -t "$SESSION_NAME" Enter
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
# Sending Enter accepts whatever is currently highlighted/default. Two
# presses, not one: some prompts (e.g. first-run onboarding) need a second
# Enter to actually clear, and an extra Enter once claude is already at its
# normal prompt is a harmless no-op.
nudge_enter() {
  log "no attached client for ${UNATTENDED_NUDGE_SEC}s+ — sending Enter (x2) in case a prompt is stuck waiting for confirmation"
  tmux_cmd send-keys -t "$SESSION_NAME" Enter
  sleep 1
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

  # Resolve claude to an absolute path using *this installer's* environment
  # (a normal interactive root shell, with a full PATH) rather than leaving
  # a bare command name in the config. systemd services run with a minimal
  # default PATH that commonly does NOT include where `claude` actually
  # lives (e.g. ~/.local/bin) even though it resolves fine interactively —
  # this caused a real deployment failure (service stuck in `failed`,
  # preflight's `command -v claude` unable to find it under systemd's PATH)
  # on a second host during testing. See DECISIONS.md.
  local resolved
  resolved=$(command -v "$CLAUDE_BIN" 2>/dev/null || true)
  if [ -n "$resolved" ]; then
    sed -i "s|^CLAUDE_BIN=.*|CLAUDE_BIN=\"$resolved\"|" "$CONFIG_FILE"
  fi

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
  require_login
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
  log "or run '$PROG_NAME purge' to do all of the above (and remove the installed binary) in one step"
}

# Full teardown: everything `uninstall` deliberately leaves behind, plus the
# live tmux session/socket and the installed binary. Unlike `uninstall`,
# this kills any in-progress claude session — it's the explicit "remove
# everything" command, not the routine-maintenance one.
cmd_purge() {
  require_root

  systemctl disable --now claude-guardian.service 2>/dev/null || true
  rm -f "$UNIT_PATH"
  systemctl daemon-reload
  systemctl reset-failed claude-guardian 2>/dev/null || true
  log "systemd service stopped, disabled, and unit file removed"

  if command -v tmux >/dev/null 2>&1 && [ -S "$TMUX_SOCKET" ]; then
    tmux_cmd kill-server 2>/dev/null || true
    log "killed tmux server on $TMUX_SOCKET (session '$SESSION_NAME' and claude with it)"
  fi
  rm -rf "$(dirname "$TMUX_SOCKET")"

  rm -rf "$(dirname "$CONFIG_FILE")"
  log "removed config directory $(dirname "$CONFIG_FILE")"

  rm -f "$INSTALL_BIN"
  log "removed installed binary $INSTALL_BIN"

  log "purge complete. Not touched: the claude CLI itself, its login credentials, and any git clone of this repo."
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
  # Pattern range instead of fixed line numbers — a fixed range silently
  # went stale (and printed the wrong text) the moment the header comment
  # above it grew, e.g. when the GPL notice was added. Matching on the
  # "Usage:" line itself instead can't drift out of sync with edits above it.
  sed -n '/^# Usage:/,/^#   run /p' "$0" | sed 's/^# \{0,1\}//'
}

main() {
  local cmd="${1:-}"
  shift || true
  case "$cmd" in
    install)   cmd_install "$@" ;;
    uninstall) cmd_uninstall "$@" ;;
    purge)     cmd_purge "$@" ;;
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
