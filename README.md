# claude-code-guardian

**English** | [简体中文](README.zh.md)

Keeps at least one remotely-attachable Claude Code (`claude`) session alive on a Debian server, root-managed, surviving both reboots and the `claude` process itself being killed (Ctrl+C, crash, `exit`).

## What it does

- Installs a systemd service that supervises a dedicated `tmux` session running `claude --permission-mode auto --remote-control` by default — remote control means you can take the session over from **claude.ai on the web or your phone**, not just SSH+tmux (the CLI prints a `claude.ai/code/...` URL on start; `claude-guardian logs` shows it).
- If `claude` exits for any reason, it is respawned automatically within a few seconds — the tmux session (and its scrollback) survives.
- If the whole supervisor or the host reboots, systemd brings it back automatically.
- While nobody is attached, periodically nudges the session so it can't go silently stuck or unreachable: sends Enter to clear any confirmation `auto` permission mode fell back to after repeated classifier blocks, and proactively re-runs `/remote-control` well before Anthropic's ~30-minute "unreachable" threshold. See `DESIGN.md` → Known limitations for the safety tradeoff this involves.
- Runs preflight checks before starting: auto-installs missing `apt` packages (`tmux` by default), verifies `claude` is on `PATH`, and warns (without blocking) if no login credentials are detected.
- Ships an `attach` command for remote operators to take over the live session over SSH, as an alternative to the claude.ai remote-control URL.

Non-goals: it does not install or update the Claude Code CLI itself, and it does not manage multiple concurrent named sessions (see `DESIGN.md`).

## Requirements

- OS: Debian or a Debian-derivative with systemd (Ubuntu, etc.)
- Must be run as root
- `claude` already installed and reachable on `PATH` (or via `CLAUDE_BIN`) — this tool does not install it
- Internet access for `apt-get` if `tmux` is not already installed

## Install

```bash
# No tagged release yet (see CHANGELOG.md) — clone main for now.
# Once v0.1.0 ships, clone that tag instead: `git ls-remote --tags <repo-url>`
git clone --depth 1 https://github.com/CharlesGool/claude-code-guardian.git
cd claude-code-guardian
bash bin/claude-guardian.sh install
```

`install` runs the preflight checks, writes a default config to `/etc/claude-guardian/config.env`, installs the script to `/usr/local/bin/claude-guardian`, writes and enables the systemd unit. It does not start the service — that's the next step.

## Quick start

```bash
claude-guardian start
claude-guardian attach
```

## Verify it works

- `systemctl is-active claude-guardian` prints `active`.
- `claude-guardian attach` drops you into a live `claude` terminal. Detach with the tmux prefix (default `Ctrl+b`) then `d` — **not** Ctrl+C (see gotcha below).
- Actually exit `claude` from inside the session (press Ctrl+C **twice** in quick succession, or type `/exit` — a single Ctrl+C only interrupts the current turn, it does not exit) — within a few seconds `claude-guardian logs` shows a `respawning automatically` line, and attaching again shows `claude` running once more.
- `systemctl stop claude-guardian` — `claude` keeps running (stop only pauses supervision, see gotcha below); `claude-guardian start` resumes watching it without restarting it.
- `reboot` the host — after boot, `systemctl is-active claude-guardian` is `active` again without manual intervention.

## Configuration

| Variable | Meaning | Default | Required |
|---|---|---|---|
| `SESSION_NAME` | tmux session name hosting `claude` | `claude-code` | no |
| `TMUX_SOCKET` | dedicated tmux server socket path | `/run/claude-guardian/tmux.sock` | no |
| `WORKDIR` | working directory `claude` starts in | `/root` | no |
| `CLAUDE_BIN` | `claude` executable name or absolute path | `claude` | no |
| `CLAUDE_ARGS` | extra CLI args passed on every (re)start | `--permission-mode auto --remote-control` | no |
| `CHECK_INTERVAL_SEC` | seconds between liveness checks | `5` | no |
| `REQUIRED_APT_PKGS` | space-separated apt packages auto-installed if missing | `tmux` | no |
| `UNATTENDED_NUDGE_SEC` | unattended-only: send Enter after this many idle seconds to clear a stuck confirmation prompt (`0` disables) | `300` | no |
| `REMOTE_CONTROL_REFRESH_SEC` | unattended-only: re-run `/remote-control` after this many idle seconds to refresh the connection (`0` disables) | `1200` | no |

Editing `CLAUDE_ARGS` to remove `--permission-mode auto` changes the safety tradeoff described in `DESIGN.md` → Known limitations — read that first.

Edit `/etc/claude-guardian/config.env` and `systemctl restart claude-guardian` to apply. Full reference: see `DESIGN.md` → Configuration reference.

## Other commands

```bash
claude-guardian check      # preflight report only, no changes
claude-guardian status     # systemctl status
claude-guardian logs       # follow the service journal
claude-guardian stop       # stop supervision (the live tmux session is left running)
claude-guardian uninstall  # remove the systemd service (config and session left untouched)
claude-guardian purge      # full teardown: uninstall + kill the session + remove config/binary
```

Gotcha: inside an attached session, Ctrl+C is interpreted by `claude` itself (interrupts the current turn; two in a row exits it, which then gets auto-respawned by design — a manual kill is guaranteed to still leave an instance running). Either way it is not a clean way to detach. Use the tmux prefix + `d` instead.

## License

[GPL-3.0](LICENSE). No third-party code is vendored in this repository.
