# claude-code-guardian — Design

**English** | [简体中文](DESIGN.zh.md)

> Success criterion for this document: someone else, on a different machine,
> can rebuild this project from it. Assume the reader cannot see your machine.

## Goals & non-goals

**Goals**
- On a Debian-family server, keep exactly one `claude` (Claude Code CLI)
  process alive at all times, inside a detachable terminal multiplexer
  session, so an operator can take over it remotely at any time — either
  via Claude Code's own Remote Control (a `claude.ai/code/...` URL,
  controllable from the web or a phone) or by SSH + `tmux attach`.
- Survive a reboot (service starts at boot).
- Survive the `claude` process itself being killed — Ctrl+C, crash, `exit`,
  OOM kill — by automatically restarting it within seconds, without losing
  the surrounding session.
- Stay actually reachable through long unattended stretches, not just
  "process is running": periodically clear confirmation prompts `auto`
  permission mode may fall back to, and proactively refresh the Remote
  Control connection before it can go stale (see Known limitations for the
  safety tradeoff this implies).
- Run preflight checks before every start: required `apt` packages present
  (auto-install if missing), `claude` binary present (hard requirement,
  never auto-installed), and a best-effort login/credential check
  (informational only, never blocks startup).
- Be operable with a small, memorable CLI (`claude-guardian <verb>`).

**Non-goals**
- Installing or updating the Claude Code CLI itself. The operator is
  expected to have it installed and authenticated (or to authenticate
  interactively through the session this tool manages).
- Building a remote-access transport from scratch. This tool relies on
  Claude Code's own `--remote-control` feature for the primary remote path,
  and assumes SSH access to the host as a fallback; it only keeps a `tmux`
  session alive for either to attach to.
- Running multiple concurrent named Claude sessions. One default session is
  the supported configuration (see `DECISIONS.md`, 2026-08-16).
- A GUI, web dashboard, or notification system. Status is read via
  `systemctl status` / `journalctl`.

## Architecture

Two independent supervision layers, so that either kind of failure — "the
`claude` process died" or "the whole supervisor died" — is recovered by a
different mechanism:

```
                     boot / crash of the supervisor itself
                                    |
                                    v
   systemd (Restart=always) ---> claude-guardian run  (foreground loop)
                                    |
                                    | every CHECK_INTERVAL_SEC:
                                    | tmux has-session? / pane_dead? / client attached?
                                    | (if unattended: nudge Enter / refresh /remote-control
                                    |  on their own longer intervals — see below)
                                    v
                     tmux session "claude-code" (remain-on-exit on)
                                    |
                                    v
                    claude --permission-mode auto --remote-control
                                    ^                       ^
                                    |                       |
                        operator: ssh + `claude-guardian     operator: claude.ai
                        attach` (tmux attach)                web/phone (Remote Control)
```

- **systemd layer** recovers from: reboot, the supervisor script crashing,
  the whole tmux server disappearing. `Restart=always` plus a bounded
  `StartLimitBurst` stop it from spinning forever if `claude` is genuinely
  missing (see Known limitations). `KillMode=process` so `stop`/`restart`
  only signals the tracked loop PID, never the tmux server or `claude`
  (verified live — the default `KillMode=control-group` killed the whole
  session, which is why this is explicit, not left at the systemd default).
- **tmux layer** recovers from: the `claude` process itself exiting for any
  reason, while the *session* (its scrollback, its pty) is preserved. This
  is what makes Ctrl+C safe to send inside the session without losing state
  — only `claude` exits and is respawned, the tmux session survives. (Note:
  Claude Code itself treats a single Ctrl+C as "interrupt this turn," not
  exit — it takes two in a row, or `/exit`, to actually terminate the
  process; verified against the real binary.)
- **unattended keepalive** (see `DECISIONS.md` 2026-08-16 "always remotely
  controllable"): when `tmux list-clients` shows nobody attached, the loop
  periodically (a) sends Enter — twice, one second apart — to clear any
  confirmation `--permission-mode auto` fell back to after repeated
  classifier blocks, and (b) re-runs `/remote-control` to refresh the
  connection before Anthropic's documented ~30-minute "could not reach the
  Remote Control server" threshold can ever be hit. Both stop immediately
  once a client attaches (checked every tick). `create_session` sends the
  same double Enter right after starting `claude`, for the same reason: a
  genuinely first-ever run can show an onboarding/trust screen that needs
  two Enters to clear, and that shouldn't have to wait for the first
  unattended-nudge interval to pass. A second Enter once `claude` is
  already sitting at its normal prompt is a harmless no-op either way, so
  there's no downside to always sending two instead of trying to detect
  which screen is showing.
- The two layers are deliberately independent: `systemctl stop
  claude-guardian` only stops the *supervision loop*; it does not kill the
  live tmux session, so an operator who is mid-conversation is not cut off
  by routine maintenance. Full teardown is a separate, explicit step —
  `uninstall` (systemd only, session/config left alone, for routine
  maintenance) vs. `purge` (everything: session, socket, config directory,
  installed binary — an explicit, deliberate "remove it all" command, see
  README).

## Tech stack

| Layer | Choice | Version | Why |
|---|---|---|---|
| Process supervisor | systemd | (Debian default) | Already present on every target OS; native boot integration and restart policy, no extra daemon to babysit. |
| Session multiplexer | tmux | Debian stable package | Scriptable liveness signal (`#{pane_dead}`) and `respawn-pane`, unlike `screen` which requires polling process tables. |
| Implementation | POSIX-ish Bash | bash (Debian default `/bin/bash`) | Whole tool is process orchestration and shell-outs to `tmux`/`systemctl`/`apt-get`; a scripting runtime would add a dependency for no benefit. |

Rejected alternatives and the reasoning behind each choice live in
`DECISIONS.md` — do not restate them here.

## Reproduction requirements

### Environment

- OS: Debian or a Debian-derivative (Ubuntu, etc.) with `systemd` as PID 1 and `apt`/`dpkg` available.
- Runtime: `bash` (present by default), `tmux` (auto-installed by preflight if missing).
- Privileges: must run as root — it manages a system-wide systemd unit, installs apt packages, and writes to `/etc` and `/run`.
- Hardware: negligible; one idle bash loop waking every few seconds.
- Dependency restore command: none — this project has no package manager dependencies, only the single shell script in `bin/`.

### External dependencies

| Item | Source | Placed at |
|---|---|---|
| `claude` (Claude Code CLI) | installed and authenticated by the operator beforehand — this tool does not install it | anywhere on `root`'s `PATH`, or point `CLAUDE_BIN` at an absolute path |

### Paths & mounts

Every path below is configurable in `/etc/claude-guardian/config.env` (written by `claude-guardian install` on first run); none are hardcoded in the script.

| Path | Provided by | Purpose |
|---|---|---|
| `/etc/claude-guardian/config.env` | this tool, on first `install` | runtime configuration (see below) |
| `/etc/systemd/system/claude-guardian.service` | this tool, on `install` | systemd unit definition |
| `/usr/local/bin/claude-guardian` | this tool, on `install` (copied from `bin/claude-guardian.sh`) | the installed CLI entry point |
| `$TMUX_SOCKET` (default `/run/claude-guardian/tmux.sock`) | this tool, created at runtime | dedicated tmux server socket, isolated from any interactive admin's own tmux server on `/tmp` |
| `$WORKDIR` (default `/root`) | operator, via config | working directory `claude` starts in |

### Configuration reference

All variables live in `/etc/claude-guardian/config.env`, a plain `KEY="value"` shell file sourced by the script. The repo's `.env.example` documents the same defaults for reference (this project has no separate app-level `.env` — the installed config file *is* the runtime configuration).

| Variable | Meaning | Default | Required |
|---|---|---|---|
| `SESSION_NAME` | tmux session name hosting `claude` | `claude-code` | no |
| `TMUX_SOCKET` | dedicated tmux server socket path | `/run/claude-guardian/tmux.sock` | no |
| `WORKDIR` | working directory `claude` starts in | `/root` | no |
| `CLAUDE_BIN` | `claude` executable name or absolute path | `claude` | no |
| `CLAUDE_ARGS` | extra CLI args passed on every (re)start | `--permission-mode auto --remote-control` | no |
| `CHECK_INTERVAL_SEC` | seconds between liveness checks | `5` | no |
| `REQUIRED_APT_PKGS` | space-separated apt packages auto-installed if missing | `tmux` | no |
| `UNATTENDED_NUDGE_SEC` | unattended-only: seconds of no attached tmux client before sending a bare Enter to clear a stuck confirmation prompt; `0` disables | `300` | no |
| `REMOTE_CONTROL_REFRESH_SEC` | unattended-only: seconds of no attached tmux client before re-running `/remote-control` to refresh the connection; `0` disables | `1200` | no |

## Setup from scratch

1. Clone the repo (a tag, not the branch tip) onto the target Debian server, as root — verify: `git clone ...` exits 0 and `bin/claude-guardian.sh` exists.
2. `bash bin/claude-guardian.sh check` — verify: prints the three check sections (`apt dependencies`, `claude CLI`, `login state`) with `[ok]`/`[missing]`/`[warn]` markers and does not modify anything.
3. `bash bin/claude-guardian.sh install` — verify: ends with `install complete`; `systemctl is-enabled claude-guardian` prints `enabled`.
4. `claude-guardian start` — verify: `systemctl is-active claude-guardian` prints `active`.
5. `claude-guardian attach` — verify: drops you into a live `claude` terminal inside tmux, and the pane shows a `/remote-control is active ... https://claude.ai/code/session_...` line — that URL is controllable from the web or a phone independent of this SSH session. Detach with the tmux prefix (default `Ctrl+b`) then `d` — **not** Ctrl+C.
6. From a second terminal, actually exit `claude` from inside the session and verify the respawn — e.g. `tmux -S /run/claude-guardian/tmux.sock send-keys -t claude-code C-c C-c` (Claude Code treats a single Ctrl+C as "interrupt current turn," matching most REPLs; it takes two in quick succession to actually exit, same as typing `/exit`). Verify: within `CHECK_INTERVAL_SEC`, `claude-guardian logs` shows a `respawning automatically` line, the `claude` PID (`pgrep -f 'claude --permission-mode'`) has changed, and `claude-guardian attach` shows a live session again (with a new remote-control URL).
7. `systemctl stop claude-guardian` then check `pgrep -f 'claude --permission-mode'` — verify: the process is still running (stop only pauses supervision, see Known limitations on `KillMode`). `claude-guardian start` again — verify: the same `claude` PID is still there (supervision resumes against the existing session instead of recreating it).
8. Detach and leave the session unattended for longer than `UNATTENDED_NUDGE_SEC` — verify: `claude-guardian logs` shows a `sending Enter in case a prompt is stuck` line at that mark, and (after `REMOTE_CONTROL_REFRESH_SEC`) a `refreshing remote control connection` line, and neither fires again immediately after you reattach and detach once more (timers reset on attach).
9. `reboot` the host — verify: after boot, `systemctl is-active claude-guardian` is `active` again without manual intervention.

This project is not deployed with Docker; steps above are the full deployment procedure.

## Data model / file layout

```
repo/
├── bin/claude-guardian.sh   # the entire tool — self-contained, no other source files
├── README.md / README.zh.md
├── DESIGN.md / DESIGN.zh.md
├── .env.example             # documents the config.env variables (see Configuration reference)
└── ...
```

There is no separate systemd unit file or config template checked into the
repo: `claude-guardian install` generates both from heredocs embedded in
`bin/claude-guardian.sh`, so this one file is a complete, self-contained
deployment artifact — copying it anywhere and running `install` is
sufficient, without needing the rest of the repo.

## Known limitations & gotchas

- **`UNATTENDED_NUDGE_SEC` (auto-Enter) is a deliberate, explicitly-approved
  safety tradeoff, not a neutral convenience feature.** `--permission-mode
  auto` falls back to an interactive confirmation after the classifier
  blocks 3 actions in a row (or 20 total) — that fallback exists so a human
  makes the call on something the classifier couldn't clear automatically.
  Sending a bare Enter when unattended accepts whichever option is
  currently highlighted/default, **without knowing whether that default is
  the safe choice for that specific prompt.** This was flagged live by
  Claude Code's own auto-mode classifier when the guardian tried to restart
  with this behavior enabled ("defeats the human-in-the-loop safety
  fallback") and required explicit user confirmation before deploying (see
  `DECISIONS.md`, 2026-08-16). Set `UNATTENDED_NUDGE_SEC="0"` to disable it
  if this tradeoff is not acceptable for a given deployment — the
  documented alternative is `--permission-mode dontAsk` with an explicit
  `permissions.allow` list, which denies unlisted actions silently instead
  of guessing at a confirmation dialog (more predictable, more setup work).
- **`claude-guardian install` auto-installs missing apt packages
  non-interactively** (`DEBIAN_FRONTEND=noninteractive apt-get install -y`).
  By default this is just `tmux`. If you widen `REQUIRED_APT_PKGS`, review
  what you are asking it to install unattended.
- **Missing `claude` binary makes the service fail-loop for about a minute,
  then stop.** `preflight_enforce` hard-fails if `claude` is not found (by
  design — this tool never installs it). `StartLimitBurst=10` /
  `StartLimitIntervalSec=60` in the unit stop systemd from restarting
  forever; after that the service sits in `failed` state until you install
  `claude` and run `systemctl reset-failed claude-guardian && systemctl
  start claude-guardian`.
- **`systemctl stop claude-guardian` does not kill the live session — this
  required `KillMode=process` in the unit, verified against the real
  binary.** systemd's *default* `KillMode` is `control-group`, which would
  SIGTERM the entire cgroup on stop/restart, including the tmux server and
  `claude` itself (this was caught live: the first version of the unit had
  no explicit `KillMode` and a `systemctl restart` silently killed and
  recreated the session). With `KillMode=process`, only the tracked loop
  PID is signaled, so `claude` and its tmux session survive a
  `stop`/`restart` of the supervisor. One side effect: systemd logs a
  benign `Found left-over process ... in control group` notice on the next
  `start`, because the previous `claude` process is still in the cgroup —
  this is expected, not an error. To fully tear down, run `claude-guardian
  purge` (or manually: `tmux -S $TMUX_SOCKET kill-session -t $SESSION_NAME`).
- **Detach with the tmux prefix, not Ctrl+C — and a single Ctrl+C does not
  kill `claude` anyway.** Verified against the real CLI: Claude Code treats
  one Ctrl+C as "interrupt the current turn" (like most REPLs), not exit —
  the pane stays alive and nothing is respawned. It takes two Ctrl+C in
  quick succession (or `/exit`) to actually terminate the process, at which
  point the pane dies and the guardian respawns it, per the original
  requirement that a deliberate kill must never leave zero live instances.
  Regardless of how many Ctrl+C it takes to exit, it is not a clean way to
  step away from the session — always use the tmux prefix + `d`.
- **If your working copy of this repo lives on a CIFS/SMB-mounted
  filesystem with a fixed `file_mode` option (common for NAS-backed dev
  setups), `chmod +x` on `bin/claude-guardian.sh` can be a silent no-op**
  (exit code 0, permission bits unchanged — this was hit during
  development). The executable bit is recorded directly in the git tree
  with `git update-index --chmod=+x bin/claude-guardian.sh` at commit time,
  so a normal `git clone` onto a filesystem that supports real permission
  bits checks it out executable regardless. If your local working copy
  can't hold the exec bit, invoke the script explicitly with
  `bash bin/claude-guardian.sh ...` rather than `./bin/claude-guardian.sh`.
- **Login is never enforced.** If `claude` has no valid credentials, the
  session still starts; `claude` itself will show its normal interactive
  login flow the first time someone attaches. The preflight check only logs
  a warning so operators know to expect it.
- **`REMOTE_CONTROL_REFRESH_SEC`'s 1200s default is a proactive guess based
  on documented behavior, not an exact reproduction.** Anthropic's docs
  state a Remote Control session that "could not reach the Remote Control
  server for about 30 minutes" needs a manual `/remote-control` to
  reconnect; whether an idle-but-network-healthy session can go stale on
  its own timeline was explicitly flagged as undocumented during research
  for this feature. Refreshing at 20 minutes is comfortably inside the
  documented 30-minute failure window either way.
- **The unattended-nudge/refresh timers only start counting from when the
  supervision loop itself (re)starts, not from whenever the session was
  actually last attended.** This was a real bug caught live: the first
  version initialized both timers to `0` (epoch), so any `systemctl
  restart` against an already-unattended session fired an immediate nudge
  and refresh instead of waiting out the configured interval. Fixed by
  seeding both timers with the current time at loop start.

## How to extend

- **New preflight checks** go in both `preflight_report` (report-only) and
  `preflight_enforce` (may mutate / hard-fail) — keep the two in sync so
  `check` accurately previews what `run`/`install` will do.
- **Supporting more than one named session** would mean turning the systemd
  unit into a template (`claude-guardian@%i.service`), keyed by session
  name, with per-instance config at
  `/etc/claude-guardian/<name>.env`. Deliberately not built (see
  `DECISIONS.md`, 2026-08-16) — add it only if a real need for concurrent
  sessions shows up, not speculatively.
- **Config variables** are added by extending both the default block near
  the top of `bin/claude-guardian.sh` and the heredoc in
  `write_default_config`, plus a row in this document's Configuration
  reference table and in `.env.example`.
