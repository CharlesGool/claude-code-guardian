# claude-code-guardian

**English** | [简体中文](translated_zh_cn/README_zh_cn.md)

Keeps one or more named, remotely-attachable Claude Code (`claude`) sessions alive on a Debian server, surviving both reboots and the `claude` process itself being killed (Ctrl+C, crash, `exit`). Root installs and supervises; the sessions themselves run as an ordinary account.

## What it does

- Installs a systemd **instance template** that supervises one dedicated `tmux` session per named instance, each running `claude --dangerously-skip-permissions --remote-control` by default — remote control means you can take any instance over from **claude.ai on the web or your phone**, not just SSH+tmux.
- **The session belongs to an ordinary account, not to root.** `RUN_AS_USER` names the account that owns the tmux server, every `claude` process, and everything `claude` writes; root only installs, supervises, and runs the admin commands. `install` adopts the account you `sudo`'d from. This is not hardening for its own sake: `claude` refuses `--dangerously-skip-permissions` outright when it runs as root, so an unattended session that must never stop to ask for permission *has* to run as somebody else. A host that installs straight as root still works — it gets `--permission-mode auto --remote-control` instead, and the combination "root plus the skip-permissions flag" is refused at the door rather than left to respawn forever.
- Knows each instance's current `claude.ai/code/...` remote-control URL — `claude-guardian url <name>` or `claude-guardian list` prints it without ever attaching. The point: create, discover, and reach a session entirely from another device, no terminal required. Fetch it when you need it rather than bookmarking it: the URL changes whenever Remote Control reconnects.
- If `claude` exits for any reason, it is respawned automatically within a few seconds, continuing the same conversation — the tmux session (and its scrollback) survives.
- If the whole supervisor or the host reboots, every instance that was `activate`d comes back automatically — **on the conversation it was having before**, not an empty one. A reboot takes the tmux server with it, so the session is rebuilt from scratch; the instance's conversation is picked back up with `claude --resume` when its transcript is still on disk (`RESUME_AFTER_RESTART=0` opts out). A conversation that can no longer be resumed falls back to a new one rather than leaving the instance stuck.
- **Keeps every instance continuously reachable.** Remote Control drops on its own — a server-side timeout, a network blip — and nothing announces it: the session keeps working, it just stops being reachable from claude.ai. Every supervision tick (`REMOTE_CONTROL_CHECK_SEC`, default 5s) the supervisor reads Claude Code's own session file to see whether the connection is still up, and reconnects the moment it isn't, picking up the new URL. The check types nothing into the session; only an actual reconnect does, and that is rate-limited by `REMOTE_CONTROL_RECONNECT_BACKOFF_SEC` (default 60s) so an instance that cannot reconnect is never typed into on a loop.
- **Never answers a confirmation dialog for you, by default.** A session parked on a permission prompt can be unstuck by sending Enter — but Enter accepts whatever the dialog has highlighted, which means deciding on your behalf, and from outside there is no way to tell "abandoned" from "you simply haven't answered it yet". So `UNATTENDED_NUDGE_SEC` defaults to `0` (off) since v0.6.0. Set it to a number of seconds if you would rather have an unattended instance unstick itself; it then only ever types into a session Claude Code itself reports as parked on a dialog, never one that is working or idle. See `DESIGN.md` → Known limitations.
- Lets you **pause** an instance (`deactivate`/`activate`: stop/resume supervision, tmux session left running) independently of **archiving** it (`archive`/`resume`: save scrollback + conversation id, then kill the process; pick the conversation back up later with `claude --resume`).
- **Never boots with nothing running.** Archiving or deactivating instances can leave zero of them enabled, and until v0.9.0 a host in that state came back from a reboot with no conversation at all — silently. Two things now prevent it: `archive` and `deactivate` warn (and ask, unless `--yes`) when the instance being removed is the last one that would come up at boot, and a boot-time unit (`claude-guardian-floor.service`) creates and starts the default `claude-code` instance when nothing else would. Set `ENSURE_DEFAULT_INSTANCE=0` if you would rather a host with no enabled instance boot with nothing.
- Runs preflight checks: auto-installs missing `apt` packages (`tmux`, `uuid-runtime` by default), verifies `claude` is on `PATH`. `install`/`new` refuse to proceed if `claude` isn't logged in yet (checked via `claude auth status`); once running, `run` only warns on login state so an instance that later loses auth keeps retrying instead of failing to start.
- Ships an `attach` command for remote operators to take over a live session over SSH, as an alternative to the claude.ai remote-control URL.
- Optional guardrail on cost/resource growth: set `MAX_SESSIONS` and `new` refuses once that many instances already exist — each is a separate `claude` process and a separate token cost. Unlimited by default (`0`).

Non-goals: it does not install or update the Claude Code CLI itself, and it does not expose a network control API — lifecycle management is CLI-only (see `DESIGN.md`).

## Requirements

- OS: Debian or a Debian-derivative with systemd (Ubuntu, etc.)
- Root for every command that writes to `/etc`, `/var/lib` or systemd — `sudo` is enough, and the usual way in is `sudo claude-guardian <command>` from your own account
- An account for the session to run as (`RUN_AS_USER`). `install` uses the account behind your `sudo`; root is the fallback when there is none. `runuser` (util-linux, normally already present) is what lets root act as it
- `claude` installed **for that account** and reachable on its `PATH` (or via `CLAUDE_BIN`) — this tool does not install it. The usual `~/.local/bin/claude` is found even when it is not on systemd's `PATH`
- `claude` already logged in **as that account** (`claude auth status` must succeed there) — `install` refuses to proceed otherwise; run `claude auth login` as that user first. A login belongs to one account: root being logged in says nothing about the session account
- Internet access for `apt-get` if `tmux` is not already installed

## Install

```bash
# Clone a tag, not the branch tip — the tip can be mid-change.
# List available tags: git ls-remote --tags <repo-url>
git clone --depth 1 --branch v0.10.0 https://github.com/CharlesGool/claude-code-guardian.git
cd claude-code-guardian
sudo bash bin/claude-guardian.sh install
```

Run it with `sudo` from the account the sessions should belong to: `install` records that account (`$SUDO_USER`) as `RUN_AS_USER` and resolves `claude` and its login as that user. It then runs the preflight checks, writes a default global config to `/etc/claude-guardian/config.env`, installs the script to `/usr/local/bin/claude-guardian`, writes the systemd **instance template** (`claude-guardian@.service`, carrying `User=$RUN_AS_USER`) and the **boot-floor unit** (`claude-guardian-floor.service`), hands the state and socket directories to that account, and creates + enables one default instance named `claude-code`. It does not start it — that's the next step. Upgrading from a v0.1.0 install migrates its single session onto the new template automatically, without killing the live `claude` process.

Upgrading from any earlier version: re-run `sudo bash bin/claude-guardian.sh install`. It is idempotent and leaves an existing `config.env` untouched, so settings added since that file was written — `ENSURE_DEFAULT_INSTANCE`, and now `RUN_AS_USER` — will not appear in it, and their built-in defaults apply until you add them yourself. For `RUN_AS_USER` that default is `root`, so **an upgraded host keeps running its sessions exactly as before**; moving them to an ordinary account is a deliberate, one-way step:

```bash
# 1. archive every instance (saves scrollback + conversation id, kills the session)
sudo claude-guardian archive <name> --yes
# 2. copy the conversations across — they live in the *old* account's ~/.claude
#    and the new one cannot read them. The directory is named after the workdir,
#    with every non-alphanumeric character replaced by '-'
sudo cp /root/.claude/projects/-root/<conversation-id>.jsonl \
        /home/you/.claude/projects/-home-you/
sudo chown you:you /home/you/.claude/projects/-home-you/<conversation-id>.jsonl
# 3. point RUN_AS_USER at the new account and re-install, then recreate the
#    instances (`resume <archive-id>` continues the conversation; edit the
#    archive's meta.env first if its workdir was the old account's home)
sudoedit /etc/claude-guardian/config.env
sudo claude-guardian install
```

A live tmux server owned by the old account blocks the new one; `install` says so and stops rather than orphaning its sessions. A socket file merely left behind by a server that is already gone is cleaned up for you. Live instances are not restarted by `install`.

### Optional: the `claude-session` skill

`skills/claude-session/` is an Agent Skill that teaches Claude Code to drive these commands from plain language ("开一个常驻对话", "list my sessions", "archive this one") instead of you remembering the CLI. It also encodes the destructive-command rules — `archive` and `purge` kill live `claude` processes, so the skill requires an explicit request naming that action before it will run either.

```bash
cp -r skills/claude-session ~/.claude/skills/
```

Optional, and it changes nothing about the tool itself: `claude-guardian` works identically without it.

## Quick start

```bash
claude-guardian start
claude-guardian attach
```

That's the default `claude-code` instance. To run a second, independent, concurrently-supervised conversation:

```bash
claude-guardian new work --workdir /home/you/some-project
claude-guardian list          # every instance: systemd/tmux state, attached?, workdir, remote-control URL
claude-guardian url work      # print just the claude.ai URL — no attach needed
```

## Verify it works

- `systemctl is-active claude-guardian@claude-code` prints `active`.
- `claude-guardian attach` drops you into a live `claude` terminal. Detach with the tmux prefix (default `Ctrl+b`) then `d` — **not** Ctrl+C (see gotcha below).
- Actually exit `claude` from inside the session (press Ctrl+C **twice** in quick succession, or type `/exit` — a single Ctrl+C only interrupts the current turn, it does not exit) — within a few seconds `claude-guardian logs` shows a `respawning automatically` line, and attaching again shows `claude` running once more, same conversation.
- `claude-guardian deactivate` — `claude` keeps running (only pauses supervision and disables restart-on-boot, see gotcha below); `claude-guardian activate` resumes watching it without restarting it. If it is your only instance, it now warns that the host would boot with nothing and asks first; pass `--yes` to skip the question.
- The boot floor: with every instance deactivated or archived, `systemctl start claude-guardian-floor` logs `no instance would come up at boot` and brings `claude-code` back — `claude-guardian list` shows it `active`/`up` within a few seconds. Run it again and it logs `already enabled — nothing to do` without creating a second session. This is the same unit that runs at boot.
- `claude-guardian archive claude-code --yes` then `claude-guardian resume claude-code` — the instance disappears from `list`, shows up in `archives`, and comes back with the same conversation continued (`claude --resume`).
- Disconnect Remote Control from inside a session (`/remote-control` → `Disconnect this session`) and detach — within `REMOTE_CONTROL_CHECK_SEC` (5s by default) `claude-guardian logs <name>` shows `remote control disconnected ... reconnecting` followed by a URL, and `claude-guardian url <name>` prints that new URL. While the connection is healthy the log stays silent, which is the point: nothing is typed into a session that does not need it.
- `reboot` the host — after boot, every instance that was `activate`d is `active` again without manual intervention, and `claude-guardian logs <name>` shows a `continuing this instance's previous conversation` line. Attach: the conversation from before the reboot is still there. (Without a reboot: `claude-guardian stop <name>`, kill its tmux session with `tmux -S /run/claude-guardian/tmux.sock kill-session -t <name>`, then `claude-guardian start <name>` — same result.)

- `bash tests/run-as-user.sh` from a clone — the isolated checks for the session-account layer (who the unit runs as, what the generated config and unit contain, which pairings are refused). It installs nothing, needs no root, and never touches a live session.

## Configuration

Global defaults live in `/etc/claude-guardian/config.env`. Per-instance overrides (`WORKDIR`, `CLAUDE_ARGS`, `CLAUDE_BIN`) are set at creation time with `new --workdir`/`--args`/`--claude-bin` and live in `/etc/claude-guardian/instances/<name>.env`.

| Variable | Meaning | Default | Scope |
|---|---|---|---|
| `TMUX_SOCKET` | shared tmux server socket path | `/run/claude-guardian/tmux.sock` | global |
| `RUN_AS_USER` | the account the tmux server, `claude`, and the supervision loop run as. One per host: every instance shares one tmux server, and a tmux server belongs to exactly one account. Changing it needs a re-`install` (the unit carries `User=`) and a `claude` login for the new account — conversations live in the old account's `~/.claude` and do not follow | the account `install` was `sudo`'d from, else `root` | global |
| `WORKDIR` | working directory `claude` starts in | `$RUN_AS_USER`'s home | global / per-instance |
| `CLAUDE_BIN` | `claude` executable name or absolute path, resolved as `$RUN_AS_USER` at install time | `claude` | global / per-instance |
| `CLAUDE_ARGS` | extra CLI args passed on every (re)start | `--dangerously-skip-permissions --remote-control`, or `--permission-mode auto --remote-control` when the session runs as root | global / per-instance |
| `CHECK_INTERVAL_SEC` | seconds between liveness checks | `5` | global |
| `REQUIRED_APT_PKGS` | space-separated apt packages auto-installed if missing | `tmux uuid-runtime` | global |
| `UNATTENDED_NUDGE_SEC` | unattended-only: send Enter once a confirmation dialog has been unanswered this long, answering it on your behalf. `0` = never (default). Nothing is ever sent to a session that is working or at a prompt | `0` | global |
| `REMOTE_CONTROL_CHECK_SEC` | unattended-only: seconds between connection checks; the check is passive and types nothing, so this can be as low as the tick interval (`0` disables) | `5` | global |
| `REMOTE_CONTROL_RECONNECT_BACKOFF_SEC` | minimum seconds between two reconnect attempts — the reconnect is the part that types `/remote-control` into the session | `60` | global |
| `CLAUDE_SESSIONS_DIR` | where Claude Code writes its per-session JSON files; read-only, and what the connected/disconnected and busy/idle/waiting checks read | `$RUN_AS_USER`'s `~/.claude/sessions` | global |
| `CLAUDE_PROJECTS_DIR` | where Claude Code keeps conversation transcripts; read-only, checked before resuming a conversation after a restart | `$RUN_AS_USER`'s `~/.claude/projects` | global |
| `RESUME_AFTER_RESTART` | `1`: bring an instance back on its previous conversation after a reboot. `0`: always start a new one | `1` | global / per-instance |
| `MAX_SESSIONS` | `new`/`resume` refuse once this many instances already exist; `0` = no limit | `0` | global |
| `ENSURE_DEFAULT_INSTANCE` | `1`: at boot, if no instance would come up at all, create and start the default `claude-code` one. Never touches a host that already has an enabled instance. `0`: such a host boots with nothing | `1` | global |

`CLAUDE_ARGS` is where the safety tradeoff lives, and it is tied to `RUN_AS_USER`: `--dangerously-skip-permissions` means the session never stops to ask, and `claude` refuses it as root. `claude-guardian check` reports on that pairing, and `install`/`new`/`run` refuse the impossible combination instead of respawning a session that exits immediately. Read `DESIGN.md` → Known limitations before changing either.

Edit `/etc/claude-guardian/config.env` and `systemctl restart 'claude-guardian@*'` to apply globally, or edit one instance's file and `claude-guardian restart <name>` for just that instance. Full reference: see `DESIGN.md` → Configuration reference.

## Other commands

```bash
claude-guardian new <name> [--workdir D] [--args "..."] [--claude-bin PATH]
                            # create + enable + start a new instance
claude-guardian list       # table of every instance
claude-guardian url <name> # print the instance's current claude.ai remote-control URL
claude-guardian activate <name>    # enable + start (survives reboot)
claude-guardian deactivate <name> [--yes]  # disable + stop supervision only — tmux session left running
                                           # asks first if it is the last instance that would boot
claude-guardian archive <name> [--yes]   # deactivate, save scrollback + conversation id, kill the session
                                         # same last-instance warning as deactivate
claude-guardian archives                 # list archived instances
claude-guardian resume <archive-id> [name]  # recreate an instance from an archive, continue the conversation
claude-guardian rm-archive <id> [--yes]  # permanently delete one archive

claude-guardian ensure-floor   # the boot floor, on demand: if no instance would come up at
                               # boot, create + enable + start the default one. Run automatically
                               # by claude-guardian-floor.service; safe to run by hand
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
