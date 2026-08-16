# claude-code-watchdog — Design

**English** | [简体中文](DESIGN.zh.md)

> Success criterion for this document: someone else, on a different machine,
> can rebuild this project from it. Assume the reader cannot see your machine.

## Goals & non-goals

**Goals**
- On a Debian-family server, keep exactly one `claude` (Claude Code CLI)
  process alive at all times, inside a detachable terminal multiplexer
  session, so an operator can SSH in at any time and take over it.
- Survive a reboot (service starts at boot).
- Survive the `claude` process itself being killed — Ctrl+C, crash, `exit`,
  OOM kill — by automatically restarting it within seconds, without losing
  the surrounding session.
- Run preflight checks before every start: required `apt` packages present
  (auto-install if missing), `claude` binary present (hard requirement,
  never auto-installed), and a best-effort login/credential check
  (informational only, never blocks startup).
- Be operable with a small, memorable CLI (`claude-guardian <verb>`).

**Non-goals**
- Installing or updating the Claude Code CLI itself. The operator is
  expected to have it installed and authenticated (or to authenticate
  interactively through the session this tool manages).
- Providing the remote transport. This tool assumes SSH access to the host
  already exists; it only keeps a `tmux` session alive for the operator to
  attach to over that existing SSH connection.
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
                                    | tmux has-session? / pane_dead?
                                    v
                     tmux session "claude-code" (remain-on-exit on)
                                    |
                                    v
                              claude  (the actual CLI process)
                                    ^
                                    |
                        operator: ssh + `claude-guardian attach`
                             (tmux attach, remote takeover)
```

- **systemd layer** recovers from: reboot, the supervisor script crashing,
  the whole tmux server disappearing. `Restart=always` plus a bounded
  `StartLimitBurst` stop it from spinning forever if `claude` is genuinely
  missing (see Known limitations).
- **tmux layer** recovers from: the `claude` process itself exiting for any
  reason, while the *session* (its scrollback, its pty) is preserved. This
  is what makes Ctrl+C safe to send inside the session without losing state
  — only `claude` exits and is respawned, the tmux session survives.
- The two layers are deliberately independent: `systemctl stop
  claude-guardian` only stops the *supervision loop*; it does not kill the
  live tmux session, so an operator who is mid-conversation is not cut off
  by routine maintenance. Full teardown is a separate, explicit step (see
  `uninstall` in README).

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
| `CLAUDE_ARGS` | extra CLI args passed on every (re)start | *(empty)* | no |
| `CHECK_INTERVAL_SEC` | seconds between liveness checks | `5` | no |
| `REQUIRED_APT_PKGS` | space-separated apt packages auto-installed if missing | `tmux` | no |

## Setup from scratch

1. Clone the repo (a tag, not the branch tip) onto the target Debian server, as root — verify: `git clone ...` exits 0 and `bin/claude-guardian.sh` exists.
2. `bash bin/claude-guardian.sh check` — verify: prints the three check sections (`apt dependencies`, `claude CLI`, `login state`) with `[ok]`/`[missing]`/`[warn]` markers and does not modify anything.
3. `bash bin/claude-guardian.sh install` — verify: ends with `install complete`; `systemctl is-enabled claude-guardian` prints `enabled`.
4. `claude-guardian start` — verify: `systemctl is-active claude-guardian` prints `active`.
5. `claude-guardian attach` — verify: drops you into a live `claude` terminal inside tmux. Detach with the tmux prefix (default `Ctrl+b`) then `d` — **not** Ctrl+C, which is interpreted as killing `claude` (by design) and triggers an automatic respawn instead of a clean detach.
6. From a second terminal, kill the `claude` process from inside the session (e.g. attach and press Ctrl+C, or `tmux -S /run/claude-guardian/tmux.sock send-keys -t claude-code C-c`) — verify: within `CHECK_INTERVAL_SEC`, `claude-guardian logs` shows a `respawning automatically` line and `claude-guardian attach` shows a live session again.
7. `reboot` the host — verify: after boot, `systemctl is-active claude-guardian` is `active` again without manual intervention.

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
- **`systemctl stop claude-guardian` does not kill the live session.** This
  is intentional (see Architecture) — it stops supervision, not the
  operator's terminal. To fully tear down, kill the tmux session
  explicitly: `tmux -S $TMUX_SOCKET kill-session -t $SESSION_NAME`.
- **Detach with the tmux prefix, not Ctrl+C.** Ctrl+C is sent straight to
  `claude` and is treated the same as a crash — the pane is respawned. This
  is the intended behavior (per the original requirement: a manual Ctrl+C
  must never leave zero live instances), but it means Ctrl+C is not a clean
  way to step away from the session.
- **The repo, when checked out on the maintenance NAS mount at
  `/root/MyGithub_Project`, lives on a CIFS filesystem mounted with a fixed
  `file_mode=0644`** — `chmod +x` on `bin/claude-guardian.sh` is a silent
  no-op there (exit code 0, permission bits unchanged). The executable bit
  is instead recorded directly in the git tree with `git update-index
  --chmod=+x bin/claude-guardian.sh` at commit time, so a normal `git
  clone` onto any other filesystem checks it out executable. When working
  directly inside this NAS-mounted copy, invoke the script explicitly with
  `bash bin/claude-guardian.sh ...` rather than `./bin/claude-guardian.sh`.
- **Login is never enforced.** If `claude` has no valid credentials, the
  session still starts; `claude` itself will show its normal interactive
  login flow the first time someone attaches. The preflight check only logs
  a warning so operators know to expect it.

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
