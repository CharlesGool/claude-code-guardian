# Changelog

Newest version first. Only changes a user can perceive — internal refactors do
not need an entry. Draft from `git log <previous-tag>..HEAD --oneline`, then
rewrite in user-facing terms.

## v0.6.1 — 2026-08-17

### Fixed
- **The first dropped connection after a restart is repaired immediately, not up to a minute later.** The reconnect backoff timer was seeded as if a reconnect had just been attempted, so an instance that dropped shortly after its supervisor started (or after a reboot, when every instance starts at once) waited out a backoff window that was protecting nothing. Found by live-testing v0.6.0: a deliberate disconnect 40s after instance creation took 25s to repair instead of 5s. Retries after the first attempt are unaffected.

## v0.6.0 — 2026-08-17

An instance stays reachable now: a dropped Remote Control connection is
noticed within seconds instead of up to twenty minutes. The supervisor also
stopped answering confirmation dialogs on your behalf unless you ask it to.
Both came out of running v0.4.0 in production for an afternoon.

### Changed
- **A dropped connection is repaired in seconds, not minutes.** The connection check now runs on every supervision tick (`REMOTE_CONTROL_CHECK_SEC`, default 5s) instead of every 20 minutes. It was always passive — one file read, nothing typed into the session — so the slow cadence bought nothing and cost up to 20 minutes of an instance being alive but unreachable from claude.ai. Reconnect attempts are rate-limited separately (`REMOTE_CONTROL_RECONNECT_BACKOFF_SEC`, default 60s), because the reconnect is the part that types.
- **The unattended Enter is off by default.** `UNATTENDED_NUDGE_SEC` now defaults to `0`. Enter accepts whatever a confirmation dialog has highlighted, and nothing distinguishes "this session was abandoned" from "the operator is looking at that dialog right now and hasn't decided yet" — v0.4.0 narrowed that gap but could not close it, and it was seen answering a real dialog on the maintainer's behalf. Set it to a number of seconds to opt back in; the `waiting`-only rule from v0.4.0 still applies when you do.
- **`REMOTE_CONTROL_REFRESH_SEC` was replaced** by `REMOTE_CONTROL_CHECK_SEC` + `REMOTE_CONTROL_RECONNECT_BACKOFF_SEC`. A config still setting the old name logs a warning at startup and is otherwise ignored — delete that line from `/etc/claude-guardian/config.env`.

### Fixed
- The stored remote-control URL is only rewritten when it actually changes, so `remote_url_updated_at` still means "when this URL was established" instead of becoming a five-second heartbeat.

## v0.5.0 — 2026-08-17

The `claude-session` Agent Skill now ships with the tool.

### Added
- `skills/claude-session/`, installed with `cp -r skills/claude-session ~/.claude/skills/`. With it, Claude Code drives these commands from plain language — "开一个常驻对话", "list my sessions", "give me the link for that one", "archive this" — instead of you recalling the CLI. It also carries the destructive-command rules: `archive` and `purge` kill live `claude` processes, so the skill runs neither without you naming that action, shows which instance it is about to archive first, and refuses to read "pause" / "取消激活" as a request to end a conversation. Entirely optional.

### Changed
- Nothing in `bin/claude-guardian.sh` — the supervisor is byte-identical to v0.4.0. This release is the skill plus the install notes for it in both READMEs.

## v0.4.0 — 2026-08-17

A rebooted instance now comes back on the conversation it was having, and
the unattended Enter is no longer sent to sessions that don't need it. Both
were reported from production use and were listed as known issues in v0.3.0.
See DECISIONS.md, 2026-08-17 ("resume the conversation across a reboot" and
"nudge only a session that is actually parked").

### Fixed
- **A reboot no longer throws away the conversation.** Every boot started
  each instance on a brand-new conversation while the previous one sat on
  disk, reachable only by hand with `claude --resume`. An instance now comes
  back on the conversation it already had, whenever that conversation's
  transcript still exists. Set `RESUME_AFTER_RESTART=0` for the old
  behaviour. A conversation that can no longer be resumed falls back to a
  new one instead of leaving the instance stuck respawning.
- **The unattended Enter no longer lands in sessions somebody is using.** It
  fired on elapsed time alone, and Remote Control is not a tmux client, so
  a session being driven from claude.ai looked abandoned and could have a
  confirmation dialog answered on the operator's behalf. The supervisor now
  asks `claude` what the session is actually doing and types only into one
  that has been parked on a dialog, unanswered, for the full
  `UNATTENDED_NUDGE_SEC`.

### Changed
- `MAX_SESSIONS` now defaults to `0`, meaning no limit; set it to a positive
  number to reinstate a ceiling. It previously defaulted to `3`, which read
  as a hard limit of the tool rather than the cost guardrail it is. Existing
  installs keep whatever value is already in
  `/etc/claude-guardian/config.env`.
- `UNATTENDED_NUDGE_SEC` now means "how long a confirmation dialog may sit
  unanswered before it is cleared" rather than "how long the session may go
  untouched". Same default (`300`).
- New config keys `RESUME_AFTER_RESTART` and `CLAUDE_PROJECTS_DIR`. Both
  have working defaults, so an existing `config.env` needs no edit;
  `install` leaves an existing config untouched as before.

## v0.3.0 — 2026-08-17

Remote Control now actually gets repaired when it drops, and the URL an
instance reports is guaranteed to be its own. See DECISIONS.md, 2026-08-17
("read Remote Control state from claude's own session file"), for how these
were found and why the approach changed.

### Fixed
- **Instances no longer sit disconnected until someone notices.** The
  unattended keepalive re-ran `/remote-control` on a timer believing that
  refreshed the connection; it does not — on an already-connected session
  that command only opens an informational dialog. A dropped Remote Control
  connection was therefore never repaired. The supervisor now checks
  whether the connection is genuinely up and reconnects only if it isn't.
- **`url` / `list` could report another instance's URL.** The URL was found
  by grepping the terminal for any `claude.ai/code/session_...` link, so a
  link that merely happened to be on screen — another instance's, one in a
  commit message, one echoed by a command — could be recorded as this
  instance's own. Observed in production. The URL now comes from the
  session's own state, and the terminal fallback is anchored to the
  `/remote-control` output.
- **The supervisor no longer types into healthy sessions.** Remote Control
  is not a tmux client, so a session being driven from claude.ai looked
  unattended and received a `/remote-control` line as a user turn every
  `REMOTE_CONTROL_REFRESH_SEC`. The connection check is now a file read;
  keys are sent only to perform an actual reconnect.

### Changed
- `REMOTE_CONTROL_REFRESH_SEC` now means "how often to check that Remote
  Control is still connected" rather than "how often to re-run
  `/remote-control`". Same default (`1200`); it now bounds how long a
  dropped connection can go unnoticed.
- `url <name>` and `list` report the instance's *current* URL rather than
  the last one stored. Reconnecting mints a new URL, so fetch it when you
  need it instead of bookmarking it; `url` warns when an instance is
  disconnected and the link it has is probably dead.

### Added
- `CLAUDE_SESSIONS_DIR` (default
  `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/sessions`): where Claude Code writes
  its per-session files. Read-only, and only needs setting if Claude Code
  uses a non-default config directory.

## v0.2.0 — 2026-08-17

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
