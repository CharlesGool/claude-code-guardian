# claude-code-guardian

**English** | [简体中文](README.zh.md)

Keeps one or more named, remotely-attachable Claude Code (`claude`) sessions alive on a Debian server, root-managed, surviving both reboots and the `claude` process itself being killed (Ctrl+C, crash, `exit`).

## What it does

- Installs a systemd **instance template** that supervises one dedicated `tmux` session per named instance, each running `claude --permission-mode auto --remote-control` by default — remote control means you can take any instance over from **claude.ai on the web or your phone**, not just SSH+tmux.
- Captures each instance's `claude.ai/code/...` remote-control URL automatically (at creation, and again on every unattended refresh) and stores it — `claude-guardian url <name>` or `claude-guardian list` prints it without ever attaching. The point: create, discover, and reach a session entirely from another device, no terminal required.
- If `claude` exits for any reason, it is respawned automatically within a few seconds, continuing the same conversation — the tmux session (and its scrollback) survives.
- If the whole supervisor or the host reboots, every instance that was `activate`d comes back automatically.
- While nobody is attached to an instance, periodically nudges it so it can't go silently stuck or unreachable: sends Enter to clear any confirmation `auto` permission mode fell back to after repeated classifier blocks, and proactively re-runs `/remote-control` well before Anthropic's ~30-minute "unreachable" threshold. See `DESIGN.md` → Known limitations for the safety tradeoff this involves.
- Lets you **pause** an instance (`deactivate`/`activate`: stop/resume supervision, tmux session left running) independently of **archiving** it (`archive`/`resume`: save scrollback + conversation id, then kill the process; pick the conversation back up later with `claude --resume`).
- Runs preflight checks: auto-installs missing `apt` packages (`tmux`, `uuid-runtime` by default), verifies `claude` is on `PATH`. `install`/`new` refuse to proceed if `claude` isn't logged in yet (checked via `claude auth status`); once running, `run` only warns on login state so an instance that later loses auth keeps retrying instead of failing to start.
- Ships an `attach` command for remote operators to take over a live session over SSH, as an alternative to the claude.ai remote-control URL.
- Bounds cost/resource growth: `new` refuses once `MAX_SESSIONS` (default 3) concurrent instances already exist — each is a separate `claude` process and a separate token cost.

Non-goals: it does not install or update the Claude Code CLI itself, and it does not expose a network control API — lifecycle management is CLI-only (see `DESIGN.md`).

## Requirements

- OS: Debian or a Debian-derivative with systemd (Ubuntu, etc.)
- Must be run as root
- `claude` already installed and reachable on `PATH` (or via `CLAUDE_BIN`) — this tool does not install it
- `claude` already logged in (`claude auth status` must succeed) — `install` refuses to proceed otherwise; run `claude auth login` first
- Internet access for `apt-get` if `tmux` is not already installed

## Install

```bash
# Clone a tag, not the branch tip — the tip can be mid-change.
# List available tags: git ls-remote --tags <repo-url>
git clone --depth 1 --branch v0.2.0 https://github.com/CharlesGool/claude-code-guardian.git
cd claude-code-guardian
bash bin/claude-guardian.sh install
```

`install` runs the preflight checks, writes a default global config to `/etc/claude-guardian/config.env`, installs the script to `/usr/local/bin/claude-guardian`, writes the systemd **instance template** (`claude-guardian@.service`), and creates + enables one default instance named `claude-code`. It does not start it — that's the next step. Upgrading from a v0.1.0 install migrates its single session onto the new template automatically, without killing the live `claude` process.

## Quick start

```bash
claude-guardian start
claude-guardian attach
```

That's the default `claude-code` instance. To run a second, independent, concurrently-supervised conversation:

```bash
claude-guardian new work --workdir /root/some-project
claude-guardian list          # every instance: systemd/tmux state, attached?, workdir, remote-control URL
claude-guardian url work      # print just the claude.ai URL — no attach needed
```

## Verify it works

- `systemctl is-active claude-guardian@claude-code` prints `active`.
- `claude-guardian attach` drops you into a live `claude` terminal. Detach with the tmux prefix (default `Ctrl+b`) then `d` — **not** Ctrl+C (see gotcha below).
- Actually exit `claude` from inside the session (press Ctrl+C **twice** in quick succession, or type `/exit` — a single Ctrl+C only interrupts the current turn, it does not exit) — within a few seconds `claude-guardian logs` shows a `respawning automatically` line, and attaching again shows `claude` running once more, same conversation.
- `claude-guardian deactivate` — `claude` keeps running (only pauses supervision and disables restart-on-boot, see gotcha below); `claude-guardian activate` resumes watching it without restarting it.
- `claude-guardian archive claude-code --yes` then `claude-guardian resume claude-code` — the instance disappears from `list`, shows up in `archives`, and comes back with the same conversation continued (`claude --resume`).
- `reboot` the host — after boot, every instance that was `activate`d is `active` again without manual intervention.

## Configuration

Global defaults live in `/etc/claude-guardian/config.env`. Per-instance overrides (`WORKDIR`, `CLAUDE_ARGS`, `CLAUDE_BIN`) are set at creation time with `new --workdir`/`--args`/`--claude-bin` and live in `/etc/claude-guardian/instances/<name>.env`.

| Variable | Meaning | Default | Scope |
|---|---|---|---|
| `TMUX_SOCKET` | shared tmux server socket path | `/run/claude-guardian/tmux.sock` | global |
| `WORKDIR` | working directory `claude` starts in | `/root` | global / per-instance |
| `CLAUDE_BIN` | `claude` executable name or absolute path | `claude` | global / per-instance |
| `CLAUDE_ARGS` | extra CLI args passed on every (re)start | `--permission-mode auto --remote-control` | global / per-instance |
| `CHECK_INTERVAL_SEC` | seconds between liveness checks | `5` | global |
| `REQUIRED_APT_PKGS` | space-separated apt packages auto-installed if missing | `tmux uuid-runtime` | global |
| `UNATTENDED_NUDGE_SEC` | unattended-only: send Enter after this many idle seconds to clear a stuck confirmation prompt (`0` disables) | `300` | global |
| `REMOTE_CONTROL_REFRESH_SEC` | unattended-only: re-run `/remote-control` after this many idle seconds to refresh the connection and re-capture its URL (`0` disables) | `1200` | global |
| `MAX_SESSIONS` | `new`/`resume` refuse once this many instances already exist | `3` | global |

Editing `CLAUDE_ARGS` to remove `--permission-mode auto` changes the safety tradeoff described in `DESIGN.md` → Known limitations — read that first.

Edit `/etc/claude-guardian/config.env` and `systemctl restart 'claude-guardian@*'` to apply globally, or edit one instance's file and `claude-guardian restart <name>` for just that instance. Full reference: see `DESIGN.md` → Configuration reference.

## Other commands

```bash
claude-guardian new <name> [--workdir D] [--args "..."] [--claude-bin PATH]
                            # create + enable + start a new instance
claude-guardian list       # table of every instance
claude-guardian url <name> # print the stored claude.ai remote-control URL
claude-guardian activate <name>    # enable + start (survives reboot)
claude-guardian deactivate <name>  # disable + stop supervision only — tmux session left running
claude-guardian archive <name> [--yes]   # deactivate, save scrollback + conversation id, kill the session
claude-guardian archives                 # list archived instances
claude-guardian resume <archive-id> [name]  # recreate an instance from an archive, continue the conversation
claude-guardian rm-archive <id> [--yes]  # permanently delete one archive

claude-guardian check      # preflight report only, no changes
claude-guardian status [name]  # systemctl status (name defaults to 'claude-code')
claude-guardian logs [name]    # follow one instance's service journal
claude-guardian stop [name]    # stop (temporary — 'deactivate' also disables at boot)
claude-guardian uninstall  # remove the systemd template (every instance's config/session left untouched)
claude-guardian purge [--yes]  # full teardown: uninstall + kill every session + remove config/binary
                                # (archives are NOT deleted — see rm-archive)
```

Gotcha: inside an attached session, Ctrl+C is interpreted by `claude` itself (interrupts the current turn; two in a row exits it, which then gets auto-respawned by design — a manual kill is guaranteed to still leave an instance running). Either way it is not a clean way to detach. Use the tmux prefix + `d` instead.

## License

[GPL-3.0](LICENSE). No third-party code is vendored in this repository.
