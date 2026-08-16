# Changelog

Newest version first. Only changes a user can perceive — internal refactors do
not need an entry. Draft from `git log <previous-tag>..HEAD --oneline`, then
rewrite in user-facing terms.

## v0.1.0 — 2026-08-16

First release. `claude-guardian` keeps at least one remotely-attachable
Claude Code session alive on a Debian server, root-managed.

### Added
- `bin/claude-guardian.sh`: a single self-contained script covering
  `install`, `uninstall`, `purge`, `start`/`stop`/`restart`/`status`,
  `attach`, `logs`, `check`, and `run` (the systemd `ExecStart` target).
- systemd + tmux two-layer supervision: the tmux session survives
  `claude` exiting for any reason (Ctrl+C, crash, `exit`), and systemd
  (`Restart=always`, boot-enabled) survives the supervisor itself dying
  or a reboot.
- Launches `claude --permission-mode auto --remote-control` by default —
  remote-controllable from claude.ai on the web or a phone, not just
  SSH+tmux.
- Unattended-only keepalive: clears stuck confirmation prompts and
  proactively refreshes the Remote Control connection before Anthropic's
  ~30-minute disconnect threshold, so a long-idle deployment stays
  reachable. Configurable via `UNATTENDED_NUDGE_SEC` /
  `REMOTE_CONTROL_REFRESH_SEC`; documented as an explicit safety tradeoff
  (see DESIGN.md).
- Preflight checks: auto-installs missing `apt` packages, requires the
  `claude` binary to already be present (never auto-installed), and
  requires `claude` to already be logged in before `install` will
  proceed (checked via `claude auth status`).
- `purge` command for a full teardown (session, socket, config,
  installed binary), separate from the routine-maintenance-safe
  `uninstall`.
- Bilingual README/DESIGN docs, GPL-3.0 license.

### Fixed
Several of these were only caught via real deployment testing (this host
and a second, independent host), not code review alone:
- `StartLimitIntervalSec` placed in the wrong systemd unit section.
- systemd's default `KillMode=control-group` killing the live tmux
  session on `stop`/`restart` — fixed with `KillMode=process`.
- `CLAUDE_BIN` not resolving under systemd's minimal PATH even though it
  resolved fine interactively — now baked to an absolute path at install
  time, with a runtime self-heal fallback for already-installed hosts.
- Unattended keepalive timers firing immediately on every restart instead
  of waiting out their configured interval.
- A stale hardcoded line range in `usage()` that silently broke when an
  earlier commit added the license header above it.
