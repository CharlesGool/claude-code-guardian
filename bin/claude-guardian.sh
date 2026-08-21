#!/usr/bin/env bash
#
# claude-guardian — keeps one or more remotely-attachable Claude Code
# sessions alive, root-managed, on a Debian server.
# Copyright (C) 2026 CharlesGool
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version. See the LICENSE file, or
# <https://www.gnu.org/licenses/>, for the full text.
#
# Each named "instance" gets its own tmux session (all sharing one tmux
# server/socket) and its own systemd unit instance
# (claude-guardian@<name>.service, from a template unit). Two supervision
# layers per instance:
#   1. Inside its detached tmux session: if `claude` exits (Ctrl+C, crash,
#      `exit`), the pane is respawned automatically.
#   2. The systemd instance (Restart=always) supervises the loop script
#      itself, so a reboot or the loop process dying is also recovered from.
#
# This script is self-contained: `install` embeds the systemd unit template
# and the default config as heredocs, so copying this one file is enough to
# deploy.
#
# Usage: claude-guardian <command> [args]
#   install                     one-time setup: preflight, systemd instance
#                               template, default config; migrates a
#                               v0.1.0 single-instance install if found
#   new <name> [--workdir D] [--args "..."] [--claude-bin PATH]
#                               create + enable + start a new instance
#   list                        table of every instance: systemd/tmux state,
#                               attached?, workdir, remote-control URL
#   url <name>                  print the stored claude.ai remote-control URL
#   activate <name>             enable + start an instance (survives reboot)
#   deactivate <name> [--yes]   disable + stop supervision only; the live
#                               tmux session (if any) is left running,
#                               still attachable. Asks first if this is the
#                               last instance that would come up at boot
#   archive <name> [--yes]      deactivate, save scrollback + conversation
#                               id, then kill the tmux session
#   archives [prefix]           list archived instances
#   resume <archive-id> [name]  recreate an instance from an archive and
#                               continue its conversation (claude --resume)
#   rm-archive <id> [--yes]     permanently delete one archive
#   attach [name]               attach to the live tmux session (remote
#                               takeover); name defaults to 'claude-code'
#   logs [name]                 follow one instance's service journal
#   start|stop|restart [name]   systemctl start/stop/restart one instance
#   status [name]               systemctl status for one instance
#   uninstall                   stop/disable every instance + remove the
#                               systemd template (configs/sessions untouched)
#   purge [--yes]               full teardown: uninstall + kill every live
#                               session + remove config/state/binary
#                               (archives are NOT deleted — see rm-archive)
#   check                       preflight checks only, report, no changes
#   run <name>                  (internal) foreground supervision loop for
#                               one instance; used as the unit's ExecStart
#   ensure-floor                (internal) the boot floor: if no instance
#                               would come up at boot, create and enable the
#                               default one. Run at boot by
#                               claude-guardian-floor.service; safe to run by
#                               hand to repair a host left with nothing
# ---- end of usage --------------------------------------------------------

set -uo pipefail

PROG_NAME="claude-guardian"
CONFIG_FILE="/etc/claude-guardian/config.env"
INSTANCES_DIR="/etc/claude-guardian/instances"
STATE_DIR="/var/lib/claude-guardian/state"
ARCHIVE_DIR="/var/lib/claude-guardian/archive"
UNIT_TEMPLATE_PATH="/etc/systemd/system/claude-guardian@.service"
LEGACY_UNIT_PATH="/etc/systemd/system/claude-guardian.service"
FLOOR_UNIT_PATH="/etc/systemd/system/claude-guardian-floor.service"
INSTALL_BIN="/usr/local/bin/claude-guardian"
DEFAULT_INSTANCE="claude-code"

# ---- defaults (overridden by $CONFIG_FILE, then per-instance by
#      $INSTANCES_DIR/<name>.env) ------------------------------------------
TMUX_SOCKET="/run/claude-guardian/tmux.sock"
WORKDIR="/root"
CLAUDE_BIN="claude"
CLAUDE_ARGS="--permission-mode auto --remote-control"
CHECK_INTERVAL_SEC="5"
REQUIRED_APT_PKGS="tmux uuid-runtime"
# When no tmux client is attached and claude has been parked on a
# confirmation dialog for this many seconds, send a bare Enter keystroke to
# clear it. Enter accepts whatever the dialog has highlighted, so this
# answers a permission prompt on the operator's behalf — which is why it is
# off by default since v0.6.0. 0 disables. See DESIGN.md Known limitations.
UNATTENDED_NUDGE_SEC="0"
# How often to check that Remote Control is still connected. The check is
# passive — it reads claude's own session file (see CLAUDE_SESSIONS_DIR) and
# types nothing into the session — so it is cheap enough to run on every
# supervision tick, which is what keeps an instance continuously reachable.
# 0 disables.
REMOTE_CONTROL_CHECK_SEC="5"
# Minimum seconds between two reconnect attempts for the same instance. Only
# the reconnect types into the session (`/remote-control`), so this is what
# stops a session that cannot reconnect from being typed into every few
# seconds.
REMOTE_CONTROL_RECONNECT_BACKOFF_SEC="60"
# Same idea, but for the case where claude writes no usable session file at
# all: nothing will ever confirm that a reconnect worked, so the fast path
# would type /remote-control into the session forever. Deliberately not
# written into the generated config — a host that needs to tune this has a
# bigger problem to fix first.
NO_SESSION_FILE_RETRY_SEC="1200"
# Claude Code writes one JSON file per running session here, named after that
# session's PID, with a "bridgeSessionId" field holding the Remote Control
# session id while connected (null once disconnected). That file is the
# authoritative answer to both "is it still connected?" and "what is the
# claude.ai URL?" — see DECISIONS.md for why it replaced scraping the
# terminal, and DESIGN.md for the fallback when the file is absent.
CLAUDE_SESSIONS_DIR="${CLAUDE_CONFIG_DIR:-${HOME:-/root}/.claude}/sessions"
# Claude Code keeps one transcript per conversation here, in a directory
# named after the working directory that conversation ran in. Read to answer
# "does the conversation this instance had before the restart still exist?"
# — see RESUME_AFTER_RESTART below.
CLAUDE_PROJECTS_DIR="${CLAUDE_CONFIG_DIR:-${HOME:-/root}/.claude}/projects"
# 1: when an instance's tmux session has to be recreated (a reboot takes the
# tmux server with it), continue the conversation that instance had before
# instead of opening an empty one. 0: always start a new conversation.
RESUME_AFTER_RESTART="1"
# `new` refuses once this many instances already exist — each concurrent
# instance is a separate claude process and a separate token cost.
# 0 = no limit.
MAX_SESSIONS="0"
# 1: at boot, if no instance would come up at all, create and enable the
# default one ($DEFAULT_INSTANCE) from the values above. This is the floor
# that makes "at least one session is always available" a property of the
# tool rather than a side effect of nobody having archived the last instance
# — see cmd_ensure_floor and DECISIONS.md (2026-08-21). 0: a host left with
# no enabled instance boots with nothing running.
ENSURE_DEFAULT_INSTANCE="1"

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

validate_name() {
  [[ "$1" =~ ^[A-Za-z0-9_-]+$ ]] \
    || die "instance name must match [A-Za-z0-9_-]+ (tmux/systemd instance names can't contain spaces or slashes): '$1'"
}

confirm_or_die() {
  # $1 = prompt text. Requires an interactive tty; callers pass --yes to
  # skip this entirely (needed for scripted/non-interactive use).
  [ -t 0 ] || die "refusing to proceed without confirmation in a non-interactive shell — pass --yes"
  printf '%s' "$1 [y/N] "
  local reply
  read -r reply
  case "$reply" in
    y|Y|yes|YES) ;;
    *) die "aborted" ;;
  esac
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
    echo "            'install'/'new' refuse to proceed until this is fixed: run '$CLAUDE_BIN auth login' first"
    ok=1
  fi

  return "$ok"
}

# Enforcing: auto-installs missing apt packages, hard-fails if claude is
# missing, only warns on login state. Used by `run`, `install`, and `new`.
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

  is_logged_in || log "warning: claude is not logged in ('$CLAUDE_BIN auth status' failed); run '$PROG_NAME attach <name>' to log in interactively (this does not block a running instance — only 'install'/'new' hard-require login)"
}

# Hard requirement for `install`/`new` only — deliberately not folded into
# preflight_enforce, which stays non-blocking on login state so an
# already-running instance that later loses auth keeps retrying instead of
# refusing to start. Creating a guardian instance that has never once
# logged in would just sit respawning a session nobody can use yet, so that
# specific case is refused outright instead.
require_login() {
  is_logged_in \
    || die "claude is not logged in ('$CLAUDE_BIN auth status' failed). Log in first — run '$CLAUDE_BIN auth login', or 'claude' interactively — then retry."
}

# ---- instance config / state -------------------------------------------

instance_file() { echo "$INSTANCES_DIR/$1.env"; }
instance_exists() { [ -e "$(instance_file "$1")" ]; }
instance_count() {
  find "$INSTANCES_DIR" -maxdepth 1 -name '*.env' 2>/dev/null | grep -c . || true
}

unit_is_enabled() {
  [ "$(systemctl is-enabled "claude-guardian@${1}.service" 2>/dev/null)" = "enabled" ]
}

# How many instances would actually come up at the next boot. Not the same
# as instance_count: `deactivate` leaves the config file in place but
# disables the unit, so counting files alone overstates it, and it is this
# number reaching zero — not the file count — that leaves a host booting
# with no conversation at all.
# $1 (optional): an instance to leave out of the count, i.e. "what would be
# left if I archived/deactivated this one right now".
boot_ready_count() {
  local skip="${1:-}" f name n=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    name=$(basename "$f" .env)
    [ "$name" = "$skip" ] && continue
    unit_is_enabled "$name" && n=$(( n + 1 ))
  done < <(find "$INSTANCES_DIR" -maxdepth 1 -name '*.env' 2>/dev/null)
  echo "$n"
}

# What the operator needs to be told when the action they just asked for
# takes boot_ready_count to zero. Says what happens at the next boot, which
# depends on whether the floor is on — silently dropping to zero is exactly
# the failure this warning exists to stop.
# $1 = instance name, $2 = lower-case gerund ("archiving"/"deactivating").
last_instance_warning() {
  local name="$1" verb="$2"
  if [ "${ENSURE_DEFAULT_INSTANCE:-1}" = "1" ]; then
    printf "'%s' is the last instance that would come up at boot, so %s it leaves this host with nothing running. ENSURE_DEFAULT_INSTANCE=1, so the next boot recreates and starts the default instance '%s' from the global config in %s — a fresh conversation with the global WORKDIR/CLAUDE_ARGS, not this instance's. Set ENSURE_DEFAULT_INSTANCE=0 there if you want this host to boot with nothing." \
      "$name" "$verb" "$DEFAULT_INSTANCE" "$CONFIG_FILE"
  else
    printf "'%s' is the last instance that would come up at boot, so %s it leaves this host with nothing running. ENSURE_DEFAULT_INSTANCE=0, so a reboot will NOT bring anything back — you would have to run '%s new <name>' by hand. Set it to 1 in %s to have the default instance recreated at boot instead." \
      "$name" "$verb" "$PROG_NAME" "$CONFIG_FILE"
  fi
}

# Sources this instance's overrides (WORKDIR/CLAUDE_ARGS/CLAUDE_BIN, and
# RESUME_SESSION_ID if it was created via `resume`) on top of the global
# config already sourced at script start.
load_instance() {
  local name="$1"
  if [ -r "$(instance_file "$name")" ]; then
    # shellcheck disable=SC1090
    . "$(instance_file "$name")"
  fi
}

write_instance_file() {
  local name="$1" workdir="$2" args="$3" bin="$4" resume_id="${5:-}"
  install -d -m 0755 "$INSTANCES_DIR"
  {
    echo "# claude-guardian instance '$name' — overrides for this instance only."
    echo "WORKDIR=\"$workdir\""
    echo "CLAUDE_ARGS=\"$args\""
    echo "CLAUDE_BIN=\"$bin\""
    if [ -n "$resume_id" ]; then
      echo "# set by 'resume' — create_session passes --resume instead of --session-id"
      echo "RESUME_SESSION_ID=\"$resume_id\""
    fi
  } > "$(instance_file "$name")"
  log "wrote instance config to $(instance_file "$name")"
}

state_file() { echo "$STATE_DIR/$1.state"; }

state_set() {
  local name="$1" key="$2" val="$3" f tmp
  install -d -m 0700 "$STATE_DIR"
  f=$(state_file "$name")
  tmp="${f}.tmp.$$"
  { grep -v "^${key}=" "$f" 2>/dev/null; echo "${key}=${val}"; } > "$tmp"
  mv "$tmp" "$f"
}

state_get() {
  local name="$1" key="$2" f
  f=$(state_file "$name")
  [ -r "$f" ] || return 0
  sed -n "s/^${key}=//p" "$f" | tail -n1
}

state_rm() { rm -f "$(state_file "$1")"; }

# ---- tmux session management -------------------------------------------

tmux_cmd() {
  tmux -S "$TMUX_SOCKET" "$@"
}

ensure_socket_dir() {
  install -d -m 0700 "$(dirname "$TMUX_SOCKET")"
}

session_exists() {
  tmux_cmd has-session -t "$1" 2>/dev/null
}

pane_is_dead() {
  local dead
  dead=$(tmux_cmd list-panes -t "$1" -F '#{pane_dead}' 2>/dev/null | head -n1)
  [ "$dead" = "1" ]
}

has_attached_client() {
  [ -n "$(tmux_cmd list-clients -t "$1" 2>/dev/null)" ]
}

# Path to the transcript Claude Code keeps for one conversation, or failure
# if that conversation is not on disk. The directory is named after the
# working directory the conversation ran in, with every character outside
# [A-Za-z0-9] replaced by '-' (verified against Claude Code 2.1.202). Like
# bridgeSessionId this is an internal detail rather than a promised
# interface, so the path is configurable (CLAUDE_PROJECTS_DIR) and a miss
# degrades to starting a new conversation instead of failing.
transcript_path() {
  local id="$1" workdir="$2" slug f
  [ -n "$id" ] || return 1
  slug=$(printf '%s' "$workdir" | sed 's/[^A-Za-z0-9]/-/g')
  f="$CLAUDE_PROJECTS_DIR/$slug/$id.jsonl"
  [ -r "$f" ] || return 1
  echo "$f"
}

# $2=1 forces a brand-new conversation, ignoring both RESUME_SESSION_ID and
# RESUME_AFTER_RESTART. Used by the fallback below, after a --resume that
# claude refused.
create_session() {
  local name="$1" force_new="${2:-0}" extra_args resumed=0 prev
  log "creating tmux session '$name' and starting claude"

  if [ "$force_new" -eq 0 ] && [ -n "${RESUME_SESSION_ID:-}" ]; then
    extra_args="--resume $RESUME_SESSION_ID"
    state_set "$name" claude_session_id "$RESUME_SESSION_ID"
    resumed=1
    log "resuming archived conversation $RESUME_SESSION_ID"
  elif [ "$force_new" -eq 0 ] && [ "${RESUME_AFTER_RESTART:-1}" = "1" ] \
       && prev=$(state_get "$name" claude_session_id) && [ -n "$prev" ] \
       && transcript_path "$prev" "$WORKDIR" >/dev/null; then
    # A reboot takes the tmux server with it, so the session is recreated
    # from scratch — without this the instance would come back on an empty
    # conversation and the previous one would be left orphaned on disk,
    # reachable only by hand with `claude --resume`.
    extra_args="--resume $prev"
    resumed=1
    log "continuing this instance's previous conversation ($prev)"
  else
    local uuid
    uuid=$(uuidgen)
    extra_args="--session-id $uuid"
    state_set "$name" claude_session_id "$uuid"
  fi
  state_set "$name" workdir "$WORKDIR"
  state_set "$name" created_at "$(date -Iseconds)"

  # shellcheck disable=SC2086
  tmux_cmd new-session -d -s "$name" -n claude -c "$WORKDIR" -- "$CLAUDE_BIN" $CLAUDE_ARGS $extra_args
  tmux_cmd set-option -t "$name" remain-on-exit on

  # On a genuinely first-ever run, claude can show an onboarding/trust
  # screen that needs Enter to accept the default before it reaches the
  # normal prompt — observed needing two Enters, not one. An extra Enter
  # once claude is already at its normal prompt is a harmless no-op, so
  # send two rather than trying to detect exactly which screen is showing.
  sleep 2
  tmux_cmd send-keys -t "$name" Enter
  sleep 1
  tmux_cmd send-keys -t "$name" Enter

  # Best-effort: record the remote-control URL right away so `new` can print
  # it immediately instead of waiting for the first periodic check (up to
  # REMOTE_CONTROL_CHECK_SEC later). claude was started with
  # --remote-control, so this normally just reads its session file and types
  # nothing. It can still fall through to sending /remote-control if that
  # file has not appeared yet — and if claude is meanwhile still
  # mid-onboarding beyond the two Enters above, that lands on the wrong
  # screen; harmless, but it may need a manual '/remote-control' afterwards.
  # See DESIGN.md Known limitations.
  sleep 1

  # A --resume claude refuses (transcript unreadable, an id it no longer
  # knows, an incompatible version) makes it exit right away — and the
  # supervisor would then keep recreating the session with that same failing
  # command, every CHECK_INTERVAL_SEC, forever. Fall back to a new
  # conversation once instead: losing the history is bad, an instance that
  # never comes back is worse.
  #
  # Both halves of the test are needed. `remain-on-exit` is only set after
  # new-session returns, so a claude that exits within those first
  # milliseconds takes the whole tmux session with it (no session at all);
  # one that exits slightly later leaves a dead pane behind.
  if [ "$resumed" -eq 1 ] && { ! session_exists "$name" || pane_is_dead "$name"; }; then
    log "warning: claude exited immediately with '$extra_args' — starting a new conversation instead"
    tmux_cmd kill-session -t "$name" 2>/dev/null
    create_session "$name" 1
    return
  fi

  capture_remote_control_url "$name" || true
}

respawn_pane() {
  local name="$1"
  log "claude exited (Ctrl+C, crash, or manual exit) — respawning automatically"
  tmux_cmd respawn-pane -k -t "$name"
}

# auto permission mode falls back to an interactive confirmation after
# repeated classifier blocks (3 in a row or 20 total, per Anthropic's docs).
# With nobody attached, that confirmation would otherwise sit forever.
# Sending Enter accepts whatever is currently highlighted/default. Two
# presses, not one: some prompts (e.g. first-run onboarding) need a second
# Enter to actually clear, and an extra Enter once claude is already at its
# normal prompt is a harmless no-op. The caller decides *when* this is
# appropriate — see supervise_loop and session_status_of.
nudge_enter() {
  local name="$1"
  log "no attached client for ${UNATTENDED_NUDGE_SEC}s+ — sending Enter (x2) in case a prompt is stuck waiting for confirmation"
  tmux_cmd send-keys -t "$name" Enter
  sleep 1
  tmux_cmd send-keys -t "$name" Enter
}

# PID of an instance's claude process. create_session execs claude as the
# pane command itself, so the pane PID is claude's own PID, which is also
# what its file in $CLAUDE_SESSIONS_DIR is named after.
instance_pid() {
  tmux_cmd list-panes -t "$1" -F '#{pane_pid}' 2>/dev/null | head -n1
}

# Reads the Remote Control session id out of claude's own session file.
# Prints the claude.ai URL and returns 0 while connected; returns 1 when
# disconnected, when the file is missing (a Claude Code that doesn't write
# one), or when it turns out to describe some other session.
#
# No jq/python dependency on purpose — the fields are matched textually, and
# a disconnected session writes `"bridgeSessionId": null`, which cannot
# match a quoted-string pattern.
session_json_of() {
  local name="$1" pid f tracked recorded
  pid=$(instance_pid "$name")
  [ -n "$pid" ] || return 1
  f="$CLAUDE_SESSIONS_DIR/$pid.json"
  [ -r "$f" ] || return 1

  # Guard against PID reuse handing back a stale file: it must name this PID
  # and — when we know which claude session this instance owns — that
  # session too. Instances migrated from v0.1.0 have no tracked session id
  # (see DESIGN.md), and an empty one skips just that half of the check.
  recorded=$(grep -o '"pid"[[:space:]]*:[[:space:]]*[0-9][0-9]*' "$f" | grep -o '[0-9][0-9]*$')
  [ "$recorded" = "$pid" ] || return 1
  tracked=$(state_get "$name" claude_session_id)
  if [ -n "$tracked" ] \
     && ! grep -q "\"sessionId\"[[:space:]]*:[[:space:]]*\"$tracked\"" "$f"; then
    return 1
  fi
  echo "$f"
}

bridge_url_of() {
  local name="$1" f bridge
  f=$(session_json_of "$name") || return 1

  bridge=$(grep -o '"bridgeSessionId"[[:space:]]*:[[:space:]]*"session_[A-Za-z0-9_-]*"' "$f" \
    | sed 's/.*"\(session_[A-Za-z0-9_-]*\)".*/\1/')
  [ -n "$bridge" ] || return 1
  echo "https://claude.ai/code/$bridge"
}

# What claude itself says the session is doing, as "<status> <seconds it has
# been in that status>". Fails when there is no usable session file, which
# is the signal to fall back to the wall-clock timer rather than to guess.
#
# Statuses seen on Claude Code 2.1.202, all three verified live:
#   busy    — mid-turn, working
#   idle    — sitting at an empty prompt
#   waiting — parked on a confirmation dialog, i.e. the one and only state
#             the unattended Enter exists to clear
#
# This is what "unattended" has to mean here. Remote Control is not a tmux
# client, so a session someone is driving from claude.ai has no attached
# client and looks abandoned to tmux. `updatedAt` is no help either — it
# tracks status *transitions*, so a session that has been busy for twenty
# minutes still carries a twenty-minute-old timestamp (observed live) and
# would read as abandoned.
session_status_of() {
  local name="$1" f st ms now
  f=$(session_json_of "$name") || return 1
  st=$(grep -o '"status"[[:space:]]*:[[:space:]]*"[a-z_]*"' "$f" \
    | sed 's/.*"\([a-z_]*\)"$/\1/')
  [ -n "$st" ] || return 1
  ms=$(grep -o '"statusUpdatedAt"[[:space:]]*:[[:space:]]*[0-9][0-9]*' "$f" | grep -o '[0-9][0-9]*$')
  [ -n "$ms" ] || ms=$(grep -o '"updatedAt"[[:space:]]*:[[:space:]]*[0-9][0-9]*' "$f" | grep -o '[0-9][0-9]*$')
  [ -n "$ms" ] || return 1
  now=$(date +%s)
  echo "$st $(( now - ms / 1000 ))"
}

store_remote_url() {
  local name="$1" url="$2"
  state_set "$name" remote_url "$url"
  state_set "$name" remote_url_updated_at "$(date -Iseconds)"
}

# Same, but a no-op when the URL has not changed. The connection check runs
# on every tick now, and rewriting two state lines every few seconds for a
# URL that is still the same one would be pointless disk churn — and would
# turn remote_url_updated_at into a heartbeat instead of what it says it is.
store_remote_url_if_changed() {
  local name="$1" url="$2"
  [ "$(state_get "$name" remote_url)" = "$url" ] && return 0
  store_remote_url "$name" "$url"
}

# Records the instance's Remote Control URL, turning Remote Control back on
# first if it is off. Typing into the session is the last resort here, not
# the first move: claude is started with --remote-control, so on a healthy
# instance the URL is already readable from its session file and nothing is
# sent to the session at all.
capture_remote_control_url() {
  local name="$1" url

  if url=$(bridge_url_of "$name"); then
    store_remote_url "$name" "$url"
    log "remote control URL for '$name': $url"
    return 0
  fi

  # /remote-control turns Remote Control on when it is off. When it is
  # already on it instead opens an informational dialog offering "Disconnect
  # this session" / "Show QR code" / "Continue"; Escape closes that dialog
  # without selecting anything, so this is safe in both states.
  log "remote control not connected for '$name' — sending /remote-control to (re)connect"
  tmux_cmd send-keys -t "$name" C-u
  tmux_cmd send-keys -t "$name" "/remote-control" Enter
  sleep 3
  tmux_cmd send-keys -t "$name" Escape

  if url=$(bridge_url_of "$name"); then
    store_remote_url "$name" "$url"
    log "remote control URL for '$name': $url"
    return 0
  fi

  # Fallback for a Claude Code that writes no session file: read the URL off
  # the screen. Anchored to the /remote-control output rather than grepping
  # the whole pane, so a link that merely happens to be visible — another
  # instance's URL echoed by some command, a session URL in a commit message
  # — cannot be mistaken for this session's own. That confusion is not
  # hypothetical; see DECISIONS.md.
  url=$(tmux_cmd capture-pane -p -t "$name" 2>/dev/null \
    | grep -A2 -E '/remote-control is active|This session is available' \
    | grep -oE 'https://claude\.ai/code/session_[A-Za-z0-9_-]+' | tail -n1)
  if [ -n "$url" ]; then
    store_remote_url "$name" "$url"
    log "remote control URL for '$name' (read from the terminal; no usable entry in $CLAUDE_SESSIONS_DIR): $url"
    return 0
  fi

  log "warning: could not determine a remote-control URL for '$name' — check manually with '$PROG_NAME attach $name'"
  return 1
}

# Remote Control does drop on its own — the server times a session out, the
# network goes away — and nothing announces that in the terminal, so the
# only way to know is to look. Re-running /remote-control on a session that
# still believes it is connected does NOT re-establish anything; it just
# opens the informational dialog. That is why the loop asks this first
# (passively, typing nothing) and only sends keys when genuinely
# disconnected.
#
# Returns, and the distinction matters because the two cases deserve very
# different retry rates:
#   0 — connected; the URL is recorded if it changed
#   1 — claude's own session file says disconnected (bridgeSessionId null),
#       so a reconnect is both possible and worth doing right away
#   2 — no usable session file for this instance at all (a Claude Code that
#       writes none, or one that cannot be trusted to be this instance's).
#       Retrying every minute here would type /remote-control into the
#       session forever, since nothing will ever confirm success.
# Seed value for the reconnect timer: far enough in the past that the first
# disconnect found after a (re)start is repaired immediately, while every
# retry after it still waits out the backoff. Caught live in v0.6.0 testing:
# seeding it with "now" like the other timers meant a session that dropped
# 20 seconds after its supervisor started sat unreachable for the remaining
# 40 seconds of a backoff window that was protecting nothing — no reconnect
# had been attempted yet.
reconnect_ready_at() {
  echo "$(( $(date +%s) - REMOTE_CONTROL_RECONNECT_BACKOFF_SEC ))"
}

connection_state() {
  local name="$1" url
  if url=$(bridge_url_of "$name"); then
    store_remote_url_if_changed "$name" "$url"
    return 0
  fi
  session_json_of "$name" >/dev/null 2>&1 || return 2
  return 1
}

supervise_loop() {
  local name="$1"
  ensure_socket_dir
  log "supervision loop started: instance=$name socket=$TMUX_SOCKET interval=${CHECK_INTERVAL_SEC}s"

  local stop=0
  trap 'stop=1' TERM INT

  # Start the countdown from loop-start, not epoch 0 — otherwise a session
  # that's already alive and unattended when the loop (re)starts (e.g. a
  # systemd restart, or a reboot) triggers an immediate nudge instead of
  # waiting out the configured interval first. The reconnect timer is the
  # deliberate exception — see reconnect_ready_at.
  local last_nudge last_check last_reconnect
  last_nudge=$(date +%s)
  last_check=$(date +%s)
  last_reconnect=$(reconnect_ready_at)

  if [ -n "${REMOTE_CONTROL_REFRESH_SEC:-}" ]; then
    log "warning: REMOTE_CONTROL_REFRESH_SEC is set but was replaced in v0.6.0 by REMOTE_CONTROL_CHECK_SEC (how often to check, default 5s) and REMOTE_CONTROL_RECONNECT_BACKOFF_SEC (how often a reconnect may be retried, default 60s) — the old setting is ignored; remove it from $CONFIG_FILE"
  fi

  while [ "$stop" -eq 0 ]; do
    if ! session_exists "$name"; then
      create_session "$name"
      last_nudge=$(date +%s)
      last_check=$(date +%s)
      last_reconnect=$(reconnect_ready_at)
    elif pane_is_dead "$name"; then
      respawn_pane "$name"
    elif has_attached_client "$name"; then
      # someone is live in the session — never nudge or type a reconnect
      # while attended, and reset the timers so neither fires the instant
      # they leave
      last_nudge=$(date +%s)
      last_check=$(date +%s)
      last_reconnect=$(reconnect_ready_at)
    else
      local now
      now=$(date +%s)
      if [ "$UNATTENDED_NUDGE_SEC" -gt 0 ] && [ $(( now - last_nudge )) -ge "$UNATTENDED_NUDGE_SEC" ]; then
        local sstate sstatus sage
        if sstate=$(session_status_of "$name"); then
          sstatus="${sstate%% *}"; sage="${sstate##* }"
          if [ "$sstatus" != "waiting" ]; then
            # Working, or sitting at an empty prompt. There is no dialog to
            # clear, and a session someone is driving over Remote Control
            # looks exactly like this — typing into it would put a stray
            # Enter in their conversation.
            last_nudge=$now
          elif [ "$sage" -lt "$UNATTENDED_NUDGE_SEC" ]; then
            # A dialog is up but it has only just appeared: give whoever
            # opened it the chance to answer it themselves. Count from when
            # it appeared, so the nudge lands exactly one interval later.
            last_nudge=$(( now - sage ))
          else
            log "'$name' has been waiting on a confirmation for ${sage}s with nobody attached"
            nudge_enter "$name"
            last_nudge=$now
          fi
        else
          # No usable session file (a Claude Code that writes none, or one
          # that cannot be trusted to be this instance's): fall back to the
          # v0.2.0 behaviour of nudging on the wall clock alone.
          nudge_enter "$name"
          last_nudge=$now
        fi
      fi
      if [ "$REMOTE_CONTROL_CHECK_SEC" -gt 0 ] && [ $(( now - last_check )) -ge "$REMOTE_CONTROL_CHECK_SEC" ]; then
        last_check=$now
        local cstate=0 backoff
        connection_state "$name" || cstate=$?
        if [ "$cstate" -ne 0 ]; then
          # A dropped connection is the one failure the operator cannot see
          # from claude.ai — the session is alive and working, it just isn't
          # reachable — so it is reconnected as soon as it is noticed, not on
          # a slow timer. The backoff only limits how often keys are sent.
          backoff="$REMOTE_CONTROL_RECONNECT_BACKOFF_SEC"
          [ "$cstate" -eq 2 ] && backoff="$NO_SESSION_FILE_RETRY_SEC"
          if [ $(( now - last_reconnect )) -ge "$backoff" ]; then
            last_reconnect=$now
            if [ "$cstate" -eq 2 ]; then
              log "no usable session file for '$name' — retrying /remote-control on the slow path (every ${backoff}s)"
            else
              log "remote control disconnected for '$name' — reconnecting"
            fi
            capture_remote_control_url "$name" || true
          fi
        fi
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
# claude-guardian runtime configuration — shared defaults for every
# instance. Per-instance overrides (WORKDIR, CLAUDE_ARGS, CLAUDE_BIN) live
# in /etc/claude-guardian/instances/<name>.env instead — see `new --help`
# in README.md. Edit values here, then restart the affected instance(s),
# e.g.: systemctl restart 'claude-guardian@*'

# tmux server socket path (kept off the default /tmp socket on purpose).
# Shared by every instance: one tmux server, many sessions.
TMUX_SOCKET="/run/claude-guardian/tmux.sock"

# working directory claude starts in, for any instance that doesn't
# override it with `new --workdir`
WORKDIR="/root"

# claude executable; override with an absolute path if it is not on
# systemd's PATH (check with `command -v claude` as root)
CLAUDE_BIN="claude"

# extra arguments passed to claude on every (re)start, for any instance
# that doesn't override it with `new --args`.
# --permission-mode auto: use the auto-mode classifier instead of manual
#   per-action approval (still safer than --dangerously-skip-permissions).
# --remote-control: prints a claude.ai/code/... URL you can control the
#   session from on the web or phone, independent of SSH.
CLAUDE_ARGS="--permission-mode auto --remote-control"

# seconds between liveness checks
CHECK_INTERVAL_SEC="5"

# space-separated apt package names auto-installed if missing
REQUIRED_APT_PKGS="tmux uuid-runtime"

# when no tmux client is attached and claude has been parked on a
# confirmation dialog for this many seconds, send a bare Enter to clear it.
# Enter accepts whatever the dialog has highlighted, so this answers a
# permission prompt for you — including one you opened yourself from
# claude.ai and simply have not answered yet, which no tmux client can show.
# Off by default. Set a number of seconds only if you would rather have an
# abandoned session unstick itself than keep that decision.
UNATTENDED_NUDGE_SEC="0"

# how often to check that Remote Control is still connected, reconnecting it
# and picking up the new claude.ai URL if it has dropped (see
# `claude-guardian url <name>`). The check reads claude's own session file
# and types nothing into the session, so checking every tick is cheap; it is
# what keeps an instance continuously reachable. 0 disables.
REMOTE_CONTROL_CHECK_SEC="5"

# minimum seconds between two reconnect attempts for the same instance. Only
# the reconnect itself types into the session, so this is the knob that keeps
# an instance that cannot reconnect from being typed into every few seconds.
REMOTE_CONTROL_RECONNECT_BACKOFF_SEC="60"

# where Claude Code writes its per-session JSON files, one per running
# session, named after that session's PID. Read-only; it is what makes the
# connected/disconnected check above possible, and what tells the nudge
# whether anyone is actually working in the session. Override only if Claude
# Code is configured with a non-default CLAUDE_CONFIG_DIR.
CLAUDE_SESSIONS_DIR="${CLAUDE_CONFIG_DIR:-${HOME:-/root}/.claude}/sessions"

# where Claude Code keeps conversation transcripts. Read-only; used to check
# that a conversation still exists before trying to resume it.
CLAUDE_PROJECTS_DIR="${CLAUDE_CONFIG_DIR:-${HOME:-/root}/.claude}/projects"

# 1: after a reboot (or any restart that took the tmux session with it),
# bring the instance back on the conversation it had before, instead of an
# empty one. 0: always start a new conversation.
RESUME_AFTER_RESTART="1"

# `new` refuses once this many instances already exist — each concurrent
# instance is a separate claude process and a separate token cost.
# 0 = no limit.
MAX_SESSIONS="0"

# 1: at boot, if nothing at all would come up (every instance archived or
# deactivated), create and start the default instance 'claude-code' from the
# values above, so this host always boots with one reachable session. It
# never touches a host that already has an enabled instance. 0: a host left
# with no enabled instance boots with nothing running, and bringing one back
# is a manual `claude-guardian new`.
ENSURE_DEFAULT_INSTANCE="1"
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

write_unit_template() {
  cat > "$UNIT_TEMPLATE_PATH" <<EOF
[Unit]
Description=Claude Code guardian instance '%i' (remotely-attachable claude session)
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=60
StartLimitBurst=10

[Service]
Type=simple
ExecStart=$INSTALL_BIN run %i
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
  log "wrote systemd instance template to $UNIT_TEMPLATE_PATH"
}

# A second, non-templated unit whose only job is to run the boot floor once
# per boot. Separate from the instance template on purpose: the template's
# units only exist for instances that are already enabled, so none of them
# runs in exactly the state the floor has to repair (zero enabled
# instances). Type=oneshot with RemainAfterExit so it shows as active rather
# than dead once it has made its decision.
write_floor_unit() {
  cat > "$FLOOR_UNIT_PATH" <<EOF
[Unit]
Description=Claude Code guardian boot floor (bring up a default instance if none would start)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$INSTALL_BIN ensure-floor
User=root
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
  log "wrote systemd boot-floor unit to $FLOOR_UNIT_PATH"
}

# v0.1.0 shipped a single non-templated unit (claude-guardian.service,
# implicitly the 'claude-code' instance). Disable/remove it so the v0.2.0
# template (claude-guardian@claude-code.service) can take over the SAME
# tmux session without recreating it. Safe to run even against a live
# session: KillMode=process (both old and new unit) means this only stops
# the supervision loop, never the tmux server or the claude process inside
# it — verified in DESIGN.md "systemd layer" / "KillMode=process".
migrate_legacy_unit() {
  [ -e "$LEGACY_UNIT_PATH" ] || return 0
  log "found a v0.1.0 single-instance unit at $LEGACY_UNIT_PATH — migrating to instance '$DEFAULT_INSTANCE' (the live tmux session, if any, is not touched)"
  systemctl disable --now claude-guardian.service 2>/dev/null || true
  rm -f "$LEGACY_UNIT_PATH"
  systemctl daemon-reload
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
  local name="${1:-$DEFAULT_INSTANCE}"
  load_instance "$name"
  preflight_enforce
  supervise_loop "$name"
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

  migrate_legacy_unit

  write_unit_template
  write_floor_unit
  systemctl daemon-reload

  if ! instance_exists "$DEFAULT_INSTANCE"; then
    write_instance_file "$DEFAULT_INSTANCE" "$WORKDIR" "$CLAUDE_ARGS" "$CLAUDE_BIN"
  fi
  systemctl enable "claude-guardian@${DEFAULT_INSTANCE}.service"
  systemctl enable claude-guardian-floor.service

  log "install complete. Start the default instance with: $PROG_NAME start"
  log "create additional concurrent instances with: $PROG_NAME new <name>"
}

# The boot floor. Until v0.9.0 "at least one session is always available"
# — the requirement this tool was built for (DECISIONS.md, 2026-08-16) —
# was never enforced anywhere: it held only because `install` enabled the
# default instance and nobody had archived it since. `archive`,
# `deactivate` and `uninstall` can each take the count of boot-enabled
# instances to zero, and a host in that state comes back from a reboot with
# no conversation at all, silently. This runs once per boot and repairs
# exactly that state.
cmd_ensure_floor() {
  require_root
  if [ "${ENSURE_DEFAULT_INSTANCE:-1}" != "1" ]; then
    log "boot floor: ENSURE_DEFAULT_INSTANCE=${ENSURE_DEFAULT_INSTANCE:-1} — disabled, doing nothing"
    return 0
  fi

  local n
  n=$(boot_ready_count)
  if [ "$n" -gt 0 ]; then
    log "boot floor: $n instance(s) already enabled — nothing to do"
    return 0
  fi

  log "boot floor: no instance would come up at boot — bringing up the default instance '$DEFAULT_INSTANCE'"
  if instance_exists "$DEFAULT_INSTANCE"; then
    # Left behind by `deactivate` (which keeps the config) rather than
    # `archive` (which removes it). Reuse it: its workdir and args are the
    # operator's, the global defaults are only a fallback.
    log "boot floor: reusing the existing config at $(instance_file "$DEFAULT_INSTANCE")"
  else
    write_instance_file "$DEFAULT_INSTANCE" "$WORKDIR" "$CLAUDE_ARGS" "$CLAUDE_BIN"
  fi

  systemctl daemon-reload
  systemctl enable "claude-guardian@${DEFAULT_INSTANCE}.service"
  # --no-block, not `enable --now`: this unit runs inside the boot
  # transaction, and waiting there for another unit's start job to finish is
  # how a boot deadlocks. Queue it and return.
  systemctl start --no-block "claude-guardian@${DEFAULT_INSTANCE}.service"
  log "boot floor: instance '$DEFAULT_INSTANCE' enabled and starting — check it with '$PROG_NAME list'"
}

cmd_new() {
  require_root
  local name="${1:-}"
  shift || true
  [ -n "$name" ] || die "usage: $PROG_NAME new <name> [--workdir DIR] [--args \"...\"] [--claude-bin PATH]"
  validate_name "$name"
  [ "$name" != "run" ] || die "'run' is a reserved command name, pick another instance name"
  instance_exists "$name" \
    && die "instance '$name' already exists (config: $(instance_file "$name")). Use '$PROG_NAME activate $name' to (re)start it, or pick a different name."

  local count
  count=$(instance_count)
  if [ "$MAX_SESSIONS" -gt 0 ] && [ "$count" -ge "$MAX_SESSIONS" ]; then
    die "already at MAX_SESSIONS=$MAX_SESSIONS (see $CONFIG_FILE). Each concurrent instance is a separate claude process/token cost — raise MAX_SESSIONS (0 = no limit) if you really want more, or archive/rm-archive an existing instance first ('$PROG_NAME list')."
  fi

  local new_workdir="$WORKDIR" new_args="$CLAUDE_ARGS" new_bin="$CLAUDE_BIN"
  while [ $# -gt 0 ]; do
    case "$1" in
      --workdir)    new_workdir="$2"; shift 2 ;;
      --args)       new_args="$2"; shift 2 ;;
      --claude-bin) new_bin="$2"; shift 2 ;;
      *) die "unknown option: $1" ;;
    esac
  done
  [ -d "$new_workdir" ] || die "--workdir '$new_workdir' does not exist"

  CLAUDE_BIN="$new_bin"
  preflight_enforce
  require_login

  write_instance_file "$name" "$new_workdir" "$new_args" "$CLAUDE_BIN"
  systemctl daemon-reload
  systemctl enable --now "claude-guardian@${name}.service"
  log "instance '$name' enabled and starting — this can take a few seconds"

  sleep 5
  local url
  url=$(state_get "$name" remote_url)
  if [ -n "$url" ]; then
    log "remote control URL: $url"
  else
    log "URL not captured yet — check shortly with '$PROG_NAME url $name'"
  fi
}

cmd_list() {
  local files
  files=$(find "$INSTANCES_DIR" -maxdepth 1 -name '*.env' 2>/dev/null | sort)
  if [ -z "$files" ]; then
    echo "no instances. Create one with: $PROG_NAME new <name>"
    return
  fi

  printf '%-16s %-10s %-6s %-10s %-22s %s\n' NAME SYSTEMD TMUX ATTACHED WORKDIR URL
  local f name active tmux_state attached workdir url
  while IFS= read -r f; do
    name=$(basename "$f" .env)
    active=$(systemctl is-active "claude-guardian@${name}.service" 2>/dev/null || echo inactive)
    if session_exists "$name"; then
      tmux_state="up"
      attached=$(has_attached_client "$name" && echo yes || echo no)
    else
      tmux_state="down"
      attached="-"
    fi
    workdir=$(state_get "$name" workdir)
    [ -n "$workdir" ] || workdir="-"
    # Live value first, stored one only as a fallback: the URL changes every
    # time Remote Control reconnects, so state is only as fresh as the last
    # check the supervisor ran.
    url=$(bridge_url_of "$name") || url=$(state_get "$name" remote_url)
    [ -n "$url" ] || url="(not captured yet — try '$PROG_NAME url $name')"
    printf '%-16s %-10s %-6s %-10s %-22s %s\n' "$name" "$active" "$tmux_state" "$attached" "$workdir" "$url"
  done <<< "$files"
}

cmd_url() {
  local name="${1:-$DEFAULT_INSTANCE}"
  instance_exists "$name" || die "no such instance '$name' ($PROG_NAME list)"
  local url
  # Ask the live session first — a reconnect mints a new URL, so whatever is
  # in state is only as fresh as the last check the supervisor ran.
  if url=$(bridge_url_of "$name"); then
    store_remote_url "$name" "$url"
    echo "$url"
    return 0
  fi

  url=$(state_get "$name" remote_url)
  if [ -n "$url" ]; then
    echo "$url"
    local ts
    ts=$(state_get "$name" remote_url_updated_at)
    log "warning: remote control is not connected for '$name' right now, so this link is probably dead${ts:+ (URL last changed $ts)}. The supervisor notices within ${REMOTE_CONTROL_CHECK_SEC}s and reconnects (retried at most every ${REMOTE_CONTROL_RECONNECT_BACKOFF_SEC}s); the new link will show up here — follow it with '$PROG_NAME logs $name'."
  else
    die "no URL known yet for '$name'. It's recorded on creation and re-checked every ${REMOTE_CONTROL_CHECK_SEC}s; check '$PROG_NAME logs $name', or attach and run /remote-control yourself."
  fi
}

cmd_activate() {
  require_root
  local name="${1:-$DEFAULT_INSTANCE}"
  instance_exists "$name" \
    || die "no such instance '$name' ($PROG_NAME list; or '$PROG_NAME resume <archive-id>' if it was archived)"
  systemctl enable --now "claude-guardian@${name}.service"
  log "instance '$name' activated (enabled at boot, started now)"
}

cmd_deactivate() {
  require_root
  local name="" yes=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --yes) yes=1; shift ;;
      *) name="$1"; shift ;;
    esac
  done
  [ -n "$name" ] || name="$DEFAULT_INSTANCE"

  # Only warn when this call actually changes the answer to "what comes up at
  # boot": deactivating an already-disabled instance is a no-op, and a prompt
  # there would just train the operator to type y.
  local warn=""
  if unit_is_enabled "$name" && [ "$(boot_ready_count "$name")" -eq 0 ]; then
    warn=$(last_instance_warning "$name" "deactivating")
    if [ "$yes" -ne 1 ]; then
      confirm_or_die "WARNING: $warn

Deactivate '$name' anyway?"
    fi
  fi

  systemctl disable --now "claude-guardian@${name}.service" 2>/dev/null \
    || log "warning: 'systemctl disable --now' reported an issue for '$name' (it may already be inactive)"
  if [ -n "$warn" ]; then
    log "warning: $warn"
  fi
  log "instance '$name' deactivated — supervision stopped and won't restart at boot; its live tmux session (if any) was left running, still attachable with '$PROG_NAME attach $name'. Run '$PROG_NAME activate $name' to resume supervision."
}

cmd_archive() {
  require_root
  local name="" yes=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --yes) yes=1; shift ;;
      *) name="$1"; shift ;;
    esac
  done
  [ -n "$name" ] || die "usage: $PROG_NAME archive <name> [--yes]"
  instance_exists "$name" || die "no such instance '$name' ($PROG_NAME list)"

  # Unlike deactivate, this warns whenever the *resulting* host state is
  # "nothing would come up at boot", even if this instance was already
  # disabled — archive is the destructive one, and it is the state the
  # operator is left in that matters, not whether this call caused it.
  local warn=""
  [ "$(boot_ready_count "$name")" -eq 0 ] && warn=$(last_instance_warning "$name" "archiving")

  local prompt="This stops instance '$name', saves its scrollback + conversation id, then KILLS the live tmux session. Continue?"
  [ -n "$warn" ] && prompt="WARNING: $warn

$prompt"
  if [ "$yes" -ne 1 ]; then
    confirm_or_die "$prompt"
  fi
  if [ -n "$warn" ]; then
    log "warning: $warn"
  fi

  systemctl disable --now "claude-guardian@${name}.service" 2>/dev/null || true

  local ts archive_dir
  ts=$(date +%Y%m%dT%H%M%S)
  archive_dir="$ARCHIVE_DIR/${name}-${ts}"
  install -d -m 0700 "$archive_dir"

  if session_exists "$name"; then
    tmux_cmd capture-pane -pS - -t "$name" > "$archive_dir/scrollback.txt" 2>/dev/null || true
    tmux_cmd kill-session -t "$name" 2>/dev/null || true
    log "captured scrollback and killed tmux session '$name'"
  else
    log "no live tmux session for '$name' — archiving config/state only"
  fi

  {
    echo "name=$name"
    echo "archived_at=$(date -Iseconds)"
    echo "claude_session_id=$(state_get "$name" claude_session_id)"
    echo "workdir=$(state_get "$name" workdir)"
    echo "remote_url=$(state_get "$name" remote_url)"
    echo "created_at=$(state_get "$name" created_at)"
  } > "$archive_dir/meta.env"

  [ -e "$(instance_file "$name")" ] && cp "$(instance_file "$name")" "$archive_dir/instance.env"

  rm -f "$(instance_file "$name")"
  state_rm "$name"

  log "archived to $archive_dir"
  log "resume the conversation later with: $PROG_NAME resume $(basename "$archive_dir")"
}

cmd_archives() {
  local filter="${1:-}"
  local dirs
  dirs=$(find "$ARCHIVE_DIR" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort)
  if [ -z "$dirs" ]; then
    echo "no archives."
    return
  fi

  printf '%-30s %-14s %-22s %s\n' ARCHIVE-ID NAME ARCHIVED-AT WORKDIR
  local d id name archived_at workdir
  while IFS= read -r d; do
    id=$(basename "$d")
    if [ -n "$filter" ]; then
      case "$id" in "$filter"*) ;; *) continue ;; esac
    fi
    name=$(sed -n 's/^name=//p' "$d/meta.env" 2>/dev/null)
    archived_at=$(sed -n 's/^archived_at=//p' "$d/meta.env" 2>/dev/null)
    workdir=$(sed -n 's/^workdir=//p' "$d/meta.env" 2>/dev/null)
    printf '%-30s %-14s %-22s %s\n' "$id" "$name" "$archived_at" "$workdir"
  done <<< "$dirs"
}

cmd_resume() {
  require_root
  local archive_id="${1:-}" new_name="${2:-}"
  [ -n "$archive_id" ] || die "usage: $PROG_NAME resume <archive-id> [new-name]"

  local archive_dir="$ARCHIVE_DIR/$archive_id"
  if [ ! -d "$archive_dir" ]; then
    # convenience: allow the original instance name if exactly one archive
    # was made from it (archive dirs are named <name>-<timestamp>)
    local matches n
    matches=$(find "$ARCHIVE_DIR" -maxdepth 1 -mindepth 1 -type d -name "${archive_id}-*" 2>/dev/null | sort)
    n=$(printf '%s\n' "$matches" | grep -c . || true)
    if [ "$n" -eq 1 ]; then
      archive_dir="$matches"
      archive_id=$(basename "$archive_dir")
    elif [ "$n" -gt 1 ]; then
      local ids=""
      while IFS= read -r d; do ids="$ids $(basename "$d")"; done <<< "$matches"
      die "multiple archives match '$archive_id' — use the exact archive id:$ids"
    else
      die "no archive '$archive_id' found ($PROG_NAME archives)"
    fi
  fi

  local orig_name resume_id workdir
  orig_name=$(sed -n 's/^name=//p' "$archive_dir/meta.env")
  resume_id=$(sed -n 's/^claude_session_id=//p' "$archive_dir/meta.env")
  workdir=$(sed -n 's/^workdir=//p' "$archive_dir/meta.env")
  [ -n "$resume_id" ] \
    || die "archive '$archive_id' has no recorded claude session id — cannot resume; the scrollback in $archive_dir/scrollback.txt can still be read manually"

  local name="${new_name:-$orig_name}"
  validate_name "$name"
  instance_exists "$name" \
    && die "instance '$name' already exists — pick a different name: $PROG_NAME resume $archive_id <new-name>"

  local count
  count=$(instance_count)
  [ "$MAX_SESSIONS" -gt 0 ] && [ "$count" -ge "$MAX_SESSIONS" ] \
    && die "already at MAX_SESSIONS=$MAX_SESSIONS, 0 = no limit ($CONFIG_FILE)"

  local args="" bin=""
  if [ -r "$archive_dir/instance.env" ]; then
    args=$(sed -n 's/^CLAUDE_ARGS="\(.*\)"$/\1/p' "$archive_dir/instance.env")
    bin=$(sed -n 's/^CLAUDE_BIN="\(.*\)"$/\1/p' "$archive_dir/instance.env")
  fi
  [ -n "$args" ] || args="$CLAUDE_ARGS"
  [ -n "$bin" ] || bin="$CLAUDE_BIN"
  [ -n "$workdir" ] || workdir="$WORKDIR"

  write_instance_file "$name" "$workdir" "$args" "$bin" "$resume_id"
  systemctl daemon-reload
  systemctl enable --now "claude-guardian@${name}.service"
  log "resuming archived conversation from '$archive_id' as instance '$name' (claude session $resume_id)"
  log "note: the archive at $archive_dir is left in place — remove it explicitly with '$PROG_NAME rm-archive $archive_id' once you no longer need it"
}

cmd_rm_archive() {
  require_root
  local id="" yes=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --yes) yes=1; shift ;;
      *) id="$1"; shift ;;
    esac
  done
  [ -n "$id" ] || die "usage: $PROG_NAME rm-archive <archive-id> [--yes]"
  local d="$ARCHIVE_DIR/$id"
  [ -d "$d" ] || die "no archive '$id' ($PROG_NAME archives)"
  if [ "$yes" -ne 1 ]; then
    confirm_or_die "Permanently delete archive '$id' (scrollback + conversation id record)? This cannot be undone."
  fi
  rm -rf "$d"
  log "removed archive $id"
}

cmd_uninstall() {
  require_root
  local f name
  while IFS= read -r f; do
    name=$(basename "$f" .env)
    systemctl disable --now "claude-guardian@${name}.service" 2>/dev/null || true
  done < <(find "$INSTANCES_DIR" -maxdepth 1 -name '*.env' 2>/dev/null)
  # The boot floor goes with them: leaving it enabled would either fail at
  # the next boot (its ExecStart is the binary this is removing) or, if the
  # binary is still there, undo the uninstall by creating a fresh instance.
  systemctl disable --now claude-guardian-floor.service 2>/dev/null || true
  rm -f "$UNIT_TEMPLATE_PATH" "$FLOOR_UNIT_PATH"
  systemctl daemon-reload
  log "systemd instance template and boot-floor unit removed; every instance disabled. Configs ($INSTANCES_DIR) and any running tmux sessions were left untouched."
  log "to also remove configs: rm -rf $(dirname "$CONFIG_FILE")"
  log "to also kill all live sessions: tmux -S $TMUX_SOCKET kill-server"
  log "or run '$PROG_NAME purge' to do all of the above (and remove the installed binary) in one step"
}

# Full teardown: everything `uninstall` deliberately leaves behind, plus
# every live tmux session/socket and the installed binary. Unlike
# `uninstall`, this kills every in-progress claude instance — it's the
# explicit "remove everything" command, not the routine-maintenance one.
# Archives are deliberately NOT touched — see 'rm-archive' to remove those.
cmd_purge() {
  require_root
  local yes=0
  [ "${1:-}" = "--yes" ] && yes=1

  local count
  count=$(instance_count)
  if [ "$yes" -ne 1 ]; then
    confirm_or_die "This stops and KILLS all $count live instance(s), removes all config/state, and removes the installed binary (archives are kept). Continue?"
  fi

  local f name
  while IFS= read -r f; do
    name=$(basename "$f" .env)
    systemctl disable --now "claude-guardian@${name}.service" 2>/dev/null || true
  done < <(find "$INSTANCES_DIR" -maxdepth 1 -name '*.env' 2>/dev/null)
  systemctl disable --now claude-guardian-floor.service 2>/dev/null || true
  rm -f "$UNIT_TEMPLATE_PATH" "$LEGACY_UNIT_PATH" "$FLOOR_UNIT_PATH"
  systemctl daemon-reload
  systemctl reset-failed 'claude-guardian@*' claude-guardian claude-guardian-floor 2>/dev/null || true
  log "every instance stopped and disabled; unit template and boot-floor unit removed"

  if command -v tmux >/dev/null 2>&1 && [ -S "$TMUX_SOCKET" ]; then
    tmux_cmd kill-server 2>/dev/null || true
    log "killed the tmux server on $TMUX_SOCKET (every session and claude process with it)"
  fi
  rm -rf "$(dirname "$TMUX_SOCKET")"

  rm -rf "$(dirname "$CONFIG_FILE")"
  log "removed config directory $(dirname "$CONFIG_FILE")"

  rm -rf "$STATE_DIR"
  rm -f "$INSTALL_BIN"
  log "removed installed binary $INSTALL_BIN"

  log "purge complete. Not touched: the claude CLI itself, its login credentials, any git clone of this repo, and $ARCHIVE_DIR (remove archives explicitly with rm-archive if you want them gone too)."
}

cmd_attach() {
  local name="${1:-$DEFAULT_INSTANCE}"
  command -v tmux >/dev/null 2>&1 || die "tmux not installed"
  session_exists "$name" \
    || die "no live tmux session '$name' on socket $TMUX_SOCKET (is 'claude-guardian@${name}' running? check '$PROG_NAME list')"
  log "attaching to '$name' — detach with the tmux prefix + d (NOT Ctrl+C, which restarts claude instead)"
  exec tmux_cmd attach -t "$name"
}

cmd_logs() {
  local name="${1:-$DEFAULT_INSTANCE}"
  shift || true
  exec journalctl -u "claude-guardian@${name}.service" -f "$@"
}

usage() {
  # Pattern range instead of fixed line numbers — a fixed range silently
  # went stale (and printed the wrong text) the moment the header comment
  # above it grew, e.g. when the GPL notice was added. Matching on the
  # "Usage:" line and a dedicated end-of-usage sentinel instead can't drift
  # out of sync with edits above or within it.
  sed -n '/^# Usage:/,/^# ---- end of usage/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
}

main() {
  local cmd="${1:-}"
  shift || true
  case "$cmd" in
    install)    cmd_install ;;
    new)        cmd_new "$@" ;;
    list)       cmd_list ;;
    url)        cmd_url "${1:-}" ;;
    activate)   cmd_activate "${1:-}" ;;
    deactivate) cmd_deactivate "$@" ;;
    archive)    cmd_archive "$@" ;;
    archives)   cmd_archives "${1:-}" ;;
    resume)     cmd_resume "$@" ;;
    rm-archive) cmd_rm_archive "$@" ;;
    attach)     cmd_attach "${1:-}" ;;
    logs)       cmd_logs "$@" ;;
    start)      require_root; systemctl start "claude-guardian@${1:-$DEFAULT_INSTANCE}.service" ;;
    stop)       require_root; systemctl stop "claude-guardian@${1:-$DEFAULT_INSTANCE}.service" ;;
    restart)    require_root; systemctl restart "claude-guardian@${1:-$DEFAULT_INSTANCE}.service" ;;
    status)     systemctl status "claude-guardian@${1:-$DEFAULT_INSTANCE}.service" ;;
    uninstall)  cmd_uninstall ;;
    purge)      cmd_purge "$@" ;;
    check)      cmd_check ;;
    run)        cmd_run "$@" ;;
    ensure-floor) cmd_ensure_floor ;;
    *)          usage; exit 1 ;;
  esac
}

main "$@"
