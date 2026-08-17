# Changelog

Newest version first. Only changes a user can perceive — internal refactors do
not need an entry. Draft from `git log <previous-tag>..HEAD --oneline`, then
rewrite in user-facing terms.

## v0.2.0 — unreleased

`claude-guardian` now supervises multiple named, concurrent Claude Code
instances instead of exactly one. See DECISIONS.md, 2026-08-17, for why.

### Added
- `new <name> [--workdir D] [--args "..."] [--claude-bin PATH]`: create,
  enable, and start a new concurrently-supervised instance. Refuses past
  `MAX_SESSIONS` (default 3) instances.
- `list`: table of every instance — systemd state, tmux state, whether
  someone is attached, workdir, and its captured remote-control URL.
- `url <name>`: print the stored `claude.ai/code/...` remote-control URL
  without attaching. Captured automatically at instance creation and
  re-captured on every unattended `/remote-control` refresh.
- `activate <name>` / `deactivate <name>`: enable+start / disable+stop
  supervision only — the live tmux session is left running either way, so
  pausing supervision never cuts off an in-progress conversation.
- `archive <name> [--yes]`: deactivate, save the full scrollback and the
  instance's `claude` conversation id, then kill the tmux session — a
  deliberate, confirmed-by-default destructive step.
- `resume <archive-id> [new-name]`: recreate an instance from an archive
  and continue its conversation via `claude --resume`.
- `archives` / `rm-archive <id> [--yes]`: list / permanently delete
  archived instances.
- Each instance is created with its own `claude --session-id` (or
  `--resume`, if resumed from an archive), so a respawn after a crash
  always continues the same conversation instead of silently starting a
  new one.
- `MAX_SESSIONS` config variable bounds concurrent instance count (default
  `3`); `uuid-runtime` added to the default `REQUIRED_APT_PKGS`.

### Changed
- The systemd unit is now a template (`claude-guardian@<name>.service`)
  instead of a single fixed unit. `attach`/`logs`/`start`/`stop`/`restart`/
  `status` all still work with no name argument, defaulting to the
  `claude-code` instance, for backward compatibility with existing
  muscle-memory commands.
- `install` on an existing v0.1.0 host now migrates its old single unit to
  the new template in place, against the same live tmux session —
  `KillMode=process` means the live `claude` process is never touched by
  this migration.
- `SESSION_NAME` is no longer a config variable — the instance name *is*
  the tmux session name.
- `purge`'s blast radius grew from "one session" to "every live instance":
  it now reports the live count and requires interactive confirmation (or
  `--yes`) before proceeding, and deliberately never deletes
  `/var/lib/claude-guardian/archive/` — remove archives explicitly with
  `rm-archive`.
- `refresh_remote_control` (the periodic unattended reconnect) now also
  re-captures and stores the instance's remote-control URL, and dismisses
  the resulting on-screen overlay with an Enter afterward.

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
