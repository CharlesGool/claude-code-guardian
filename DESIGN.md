# claude-code-guardian — Design

**English** | [简体中文](DESIGN.zh.md)

> Success criterion for this document: someone else, on a different machine,
> can rebuild this project from it. Assume the reader cannot see your machine.

## Goals & non-goals

**Goals**
- On a Debian-family server, keep one or more named `claude` (Claude Code
  CLI) instances alive concurrently, each inside its own detachable
  terminal multiplexer session, so an operator can take any of them over
  remotely at any time — either via Claude Code's own Remote Control (a
  `claude.ai/code/...` URL, controllable from the web or a phone) or by
  SSH + `tmux attach`. See `DECISIONS.md`, 2026-08-17, for why this
  replaced the original single-session design.
- Make every instance's remote-control URL retrievable without attaching
  to it — captured automatically at creation and on every unattended
  refresh, stored per instance, printed by `list`/`url`. The point is that
  an operator can create, discover, and reach a session entirely from
  another Claude Code session driving this tool's CLI, without ever
  needing a terminal of their own.
- Let an instance be **paused** (`deactivate`/`activate`: stop/resume
  supervision, tmux session left running) independently of being
  **archived** (`archive`/`resume`: save scrollback + conversation id,
  then kill the process; recreate later via `claude --resume`) — these are
  deliberately two different operations with two different blast radii.
- Survive a reboot (each enabled instance's service starts at boot).
- Survive the `claude` process itself being killed — Ctrl+C, crash, `exit`,
  OOM kill — by automatically restarting it within seconds, without losing
  the surrounding session.
- Stay actually reachable through long unattended stretches, not just
  "process is running": notice a dropped Remote Control connection within
  seconds and repair it, so an instance is never alive-but-unreachable for
  longer than a tick. Clearing a confirmation prompt `auto` permission mode
  fell back to is available too, but off by default — answering a prompt is
  a decision, and this tool's job stops at keeping the session reachable
  (see Known limitations).
- Run preflight checks: required `apt` packages present (auto-install if
  missing), `claude` binary present (hard requirement, never
  auto-installed). Login state is checked via `claude auth status`
  (authoritative, not a file-existence guess) — `install`/`new` refuse to
  proceed if not logged in (an instance that has never logged in would
  just sit respawning a session nobody can use), while `run` only warns,
  so an instance that later loses auth keeps retrying instead of refusing
  to start.
- Offer a guardrail on resource/cost growth without imposing one: `new`
  refuses once `MAX_SESSIONS` concurrent instances already exist — each
  instance is a separate `claude` process and a separate token cost. The
  default is `0` (no limit), because the number of concurrent conversations
  an operator wants is a workflow decision, not something this tool can
  guess; the knob exists for whoever does want a ceiling.
- Be operable with a small, memorable CLI (`claude-guardian <verb>
  [<name>]`).

**Non-goals**
- Installing or updating the Claude Code CLI itself. The operator is
  expected to have it installed and authenticated (or to authenticate
  interactively through a session this tool manages).
- Building a remote-access transport from scratch. This tool relies on
  Claude Code's own `--remote-control` feature for the primary remote path,
  and assumes SSH access to the host as a fallback; it only keeps `tmux`
  sessions alive for either to attach to.
- A lifecycle control API (HTTP/REST or otherwise) for managing instances
  remotely. Lifecycle management is CLI-only, driven either over SSH or
  from inside a Claude Code session this tool itself manages (see
  `DECISIONS.md`, 2026-08-17, "Rejected").
- A GUI, web dashboard, or notification system. Status is read via
  `claude-guardian list` / `systemctl status` / `journalctl`.

## Architecture

Every named instance runs the same two independent supervision layers as
the original single-session design, just parameterized by instance name —
one systemd unit instance and one tmux session per `claude-guardian
<name>`, all tmux sessions sharing a single tmux server:

```
                     boot / crash of one instance's supervisor
                                    |
                                    v
   systemd (Restart=always) ---> claude-guardian run <name>  (foreground loop)
   claude-guardian@<name>.service    |
   (one instance per name,           | every CHECK_INTERVAL_SEC:
    from a template unit)            | tmux has-session? / pane_dead? / client attached?
                                      | (if unattended: check every tick that
                                      |  Remote Control is still connected and
                                      |  reconnect it if not; optionally, and
                                      |  off by default, clear a dialog nobody
                                      |  answered — see below)
                                      v
                     tmux session "<name>" (remain-on-exit on)
                     — one of possibly several, all on the same
                       tmux server / $TMUX_SOCKET
                                    |
                                    v
        claude --permission-mode auto --remote-control --session-id <uuid>
        (or --resume <uuid> instead of --session-id: an instance created
         via `claude-guardian resume <archive-id>`, or one coming back
         from a reboot onto the conversation it already had)
                                    ^                       ^
                                    |                       |
                        operator: ssh + `claude-guardian     operator: claude.ai
                        attach <name>` (tmux attach)          web/phone (Remote Control) —
                                                               URL read from claude's own
                                                               session file and stored, so
                                                               `claude-guardian url <name>`
                                                               prints it without ever
                                                               attaching
```

- **systemd layer** recovers from: reboot, one instance's supervisor
  script crashing, that instance's tmux server-side state disappearing.
  `Restart=always` plus a bounded `StartLimitBurst` stop it from spinning
  forever if `claude` is genuinely missing (see Known limitations).
  `KillMode=process` so `stop`/`restart`/`deactivate` only signal the
  tracked loop PID, never the tmux server or `claude` (verified live — the
  default `KillMode=control-group` killed the whole session, which is why
  this is explicit, not left at the systemd default). Because it's a
  *template* unit (`claude-guardian@.service`), each instance is an
  independent systemd unit instance (`claude-guardian@work.service`,
  `claude-guardian@personal.service`, ...) that can be individually
  started, stopped, enabled, or disabled without touching any other
  instance.
- **tmux layer** recovers from: the `claude` process itself exiting for any
  reason, while the *session* (its scrollback, its pty) is preserved. This
  is what makes Ctrl+C safe to send inside the session without losing state
  — only `claude` exits and is respawned, the tmux session survives. (Note:
  Claude Code itself treats a single Ctrl+C as "interrupt this turn," not
  exit — it takes two in a row, or `/exit`, to actually terminate the
  process; verified against the real binary.) All instances share one tmux
  server (one `$TMUX_SOCKET`) with one session per instance, named after
  the instance — tmux already multiplexes sessions natively, so a second
  server per instance would add operational overhead for no benefit (see
  `DECISIONS.md`, 2026-08-17).
- **session identity**: at creation, each instance is handed either a
  fresh `claude --session-id <uuid>` (generated via `uuidgen`) or a
  `claude --resume <uuid>` pointing at an existing conversation. Either way
  the id is baked into the tmux pane's original command line, so every
  `respawn-pane` after a crash automatically reuses the same id — a respawn
  continues the same conversation, it never silently forks a new one. The id
  is recorded in per-instance state
  (`/var/lib/claude-guardian/state/<name>.state`) so `archive` can save it,
  `resume` can reuse it, and the instance can find its way back to the same
  conversation after a restart.
- **surviving a reboot with the conversation intact**: `respawn-pane` only
  covers `claude` dying while its tmux session lives on. A reboot takes the
  whole tmux server with it, so the session is built from scratch — and
  before v0.4.0 that meant a brand-new empty conversation on every boot,
  with the previous one left on disk, reachable only by hand. Now
  `create_session` prefers, in order: an explicit `RESUME_SESSION_ID` (set
  by `resume <archive-id>`); the instance's own last `claude_session_id`
  from state, if `RESUME_AFTER_RESTART=1` and its transcript is still on
  disk; otherwise a fresh `uuidgen` id. The transcript check is what keeps
  this honest — it is the difference between "continue that conversation"
  and "hand `claude` an id it has never heard of". If `claude` rejects the
  resume anyway it exits immediately, and rather than let the supervisor
  rebuild that same failing command every `CHECK_INTERVAL_SEC` forever,
  `create_session` notices the dead (or vanished) session once and retries
  with a new conversation.
- **unattended keepalive** (see `DECISIONS.md` 2026-08-16 "always remotely
  controllable"): when `tmux list-clients` shows nobody attached to an
  instance's session, its loop (a) checks that Remote Control is still
  connected and reconnects it if it isn't, and (b) — only if the operator
  opted in by setting `UNATTENDED_NUDGE_SEC` above `0` — sends Enter, twice
  one second apart, to clear a confirmation dialog nobody has answered.
  Both stop immediately once a client attaches (checked every tick).
  The two run on very different clocks, and v0.6.0 separated them for a
  reason (see `DECISIONS.md`, 2026-08-17 "watch the connection on every
  tick"): (a) is passive — it reads a file and types nothing — so it runs
  every `REMOTE_CONTROL_CHECK_SEC` (default 5s, i.e. every tick), because a
  dropped connection is invisible from claude.ai and every second of it is
  a second the operator cannot reach a session that is otherwise fine. Only
  the reconnect types, and it is rate-limited separately by
  `REMOTE_CONTROL_RECONNECT_BACKOFF_SEC` (default 60s). (b) types by
  definition, decides on the operator's behalf, and is therefore off by
  default. "Nobody attached" is necessary but not sufficient for it: the
  loop also asks `claude` what the session is doing, and only types into
  one that is actually parked on a dialog — see **when the nudge is allowed
  to type** below. `create_session`
  sends the same double Enter right after starting `claude`, regardless of
  that setting: a genuinely first-ever run can show an onboarding/trust
  screen that needs two Enters to clear, and no conversation content exists
  yet for an Enter to affect — then records the URL once
  synchronously, so `new` can print it immediately instead of waiting up to
  `REMOTE_CONTROL_CHECK_SEC`. A second Enter once `claude` is already
  sitting at its normal prompt is a harmless no-op either way, so there's
  no downside to always sending two instead of trying to detect which
  screen is showing.
- **how "still connected?" is answered** (see `DECISIONS.md`, 2026-08-17
  "read claude's session file"): Claude Code writes one JSON file per
  running session under `$CLAUDE_SESSIONS_DIR`
  (`${CLAUDE_CONFIG_DIR:-$HOME/.claude}/sessions`), named after that
  session's PID, whose `bridgeSessionId` field holds the Remote Control
  session id while connected and is `null` once disconnected. An instance's
  `claude` *is* its tmux pane command, so `#{pane_pid}` names the file
  directly. Reading it answers both "is Remote Control still up?" and "what
  is the current `claude.ai/code/...` URL?" without typing anything into
  the session, which matters because the session may well have a human
  working in it over Remote Control at that moment — Remote Control is not
  a tmux client, so an actively-used instance still looks unattended here.
  The file is matched textually (no `jq`/`python` dependency), and is
  cross-checked against the instance's own `pid` and tracked
  `claude_session_id` so a reused PID can't hand back a stranger's session.
  Reconnecting is the only step that sends keys: `/remote-control` turns
  Remote Control on when it is off, and when it is already on merely opens
  an informational dialog ("Disconnect this session" / "Show QR code" /
  "Continue"), which a trailing Escape closes without selecting anything.
  **Re-running `/remote-control` on a session that still believes it is
  connected refreshes nothing** — that mistaken assumption was the whole
  basis of the v0.2.0 keepalive, and is why this checks before acting.
- **when the nudge is allowed to type at all** (see `DECISIONS.md`,
  2026-08-17 "nudge only a session that is actually parked" and "stop
  answering dialogs by default"): first, only when the operator has turned
  it on — `UNATTENDED_NUDGE_SEC` defaults to `0`, and at `0` no Enter is
  ever sent to a running session, full stop. When it is turned on, the same
  session file carries a `status` field, and the loop nudges on that rather
  than on the wall clock. Three values, all three observed live on 2.1.202: `busy`
  (mid-turn), `idle` (sitting at an empty prompt), and `waiting` (parked on
  a confirmation dialog). Only `waiting` justifies sending Enter, and only
  once it has held that status for `UNATTENDED_NUDGE_SEC` — read from
  `statusUpdatedAt`, so the countdown starts when the dialog appeared, not
  when the supervisor happened to look. Everything else is left alone,
  which is what finally makes a session someone is driving from claude.ai
  safe: it has no tmux client, so it looks abandoned, but it reads `busy`
  or `idle`, never `waiting`, unless a dialog really is sitting there
  unanswered. `updatedAt` was tried first and rejected: it tracks status
  *transitions*, so a session that had been busy for twenty minutes still
  carried a twenty-minute-old timestamp and read as abandoned (observed on
  the maintainer's own live session while it was mid-turn). When no usable
  session file exists the loop falls back to the v0.2.0 behaviour of
  nudging on elapsed time alone.
- The two layers are deliberately independent per instance:
  `claude-guardian deactivate <name>` (`systemctl disable --now`) only
  stops that instance's *supervision loop*; it does not kill its live
  tmux session, so an operator who is mid-conversation is not cut off by
  routine maintenance — `activate <name>` resumes supervision against the
  same, still-running session. Full teardown of one instance is a
  separate, explicit, destructive step: `archive <name>` (see below).
  Full teardown of the *tool* is `uninstall` (systemd template only,
  every instance's config/session left alone) vs. `purge` (everything:
  every session, the socket, every config, the installed binary — but
  never `/var/lib/claude-guardian/archive/`, see README).
- **archive / resume**: `archive <name>` stops supervision, captures the
  full scrollback (`tmux capture-pane -pS -`) and the instance's
  `claude_session_id` to `/var/lib/claude-guardian/archive/<name>-<ts>/`,
  then kills the tmux session — a deliberate, confirmed-by-default
  destructive operation (see `DECISIONS.md`, 2026-08-17, "archive kills
  the process"). `resume <archive-id> [new-name]` recreates an instance
  from that archive with `RESUME_SESSION_ID` set, so `create_session`
  passes `--resume <uuid>` instead of minting a new one — the operator
  picks back up in the same conversation.

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
| `uuidgen` (`uuid-runtime` package) | auto-installed by preflight if missing, like `tmux` | used once per instance creation/resume to mint or reuse a `claude --session-id`/`--resume` value |
| Claude Code's per-session files (`$CLAUDE_SESSIONS_DIR/<pid>.json`, fields `bridgeSessionId`, `status`, `statusUpdatedAt`) | written by `claude` itself while a session runs — nothing to install | read to tell whether an instance's Remote Control is still connected, to get its current `claude.ai/code/...` URL, and to tell whether it is working, idle, or parked on a confirmation dialog. Verified against Claude Code **2.1.202**; these are internal details, not a promised interface, so a different version may not provide them — the tool then falls back to reading the URL off the terminal and to the wall-clock nudge (see Known limitations) |
| Claude Code's conversation transcripts (`$CLAUDE_PROJECTS_DIR/<slugged-workdir>/<session-id>.jsonl`) | written by `claude` itself — nothing to install | existence is checked before resuming a conversation after a restart; the directory name is the working directory with every character outside `[A-Za-z0-9]` replaced by `-`. Verified against **2.1.202**, same caveat as above: a miss just means a new conversation is started |

### Paths & mounts

Every path below is configurable only via the constants near the top of `bin/claude-guardian.sh` (not runtime config — these are deployment topology, not per-instance behavior); none are hardcoded elsewhere in the script.

| Path | Provided by | Purpose |
|---|---|---|
| `/etc/claude-guardian/config.env` | this tool, on first `install` | global runtime configuration, shared by every instance (see below) |
| `/etc/claude-guardian/instances/<name>.env` | this tool, on `new`/`resume` | per-instance overrides: `WORKDIR`, `CLAUDE_ARGS`, `CLAUDE_BIN`, and (if resumed) `RESUME_SESSION_ID` |
| `/etc/systemd/system/claude-guardian@.service` | this tool, on `install` | systemd **template** unit — `claude-guardian@<name>.service` is one instance of it per running instance |
| `/var/lib/claude-guardian/state/<name>.state` | this tool, at runtime | per-instance runtime state: `claude_session_id`, `workdir`, `created_at`, `remote_url`, `remote_url_updated_at` |
| `/var/lib/claude-guardian/archive/<name>-<timestamp>/` | this tool, on `archive` | one directory per archived instance: `scrollback.txt`, `meta.env`, `instance.env` |
| `/usr/local/bin/claude-guardian` | this tool, on `install` (copied from `bin/claude-guardian.sh`) | the installed CLI entry point |
| `$TMUX_SOCKET` (default `/run/claude-guardian/tmux.sock`) | this tool, created at runtime | one dedicated tmux server socket shared by every instance, isolated from any interactive admin's own tmux server on `/tmp` |
| `$WORKDIR` (default `/root`, overridable per instance) | operator, via config or `new --workdir` | working directory `claude` starts in |
| `$CLAUDE_SESSIONS_DIR` (default `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/sessions`) | Claude Code, not this tool | read-only: one JSON file per running `claude` session, named after its PID; source of the Remote Control connected/disconnected check and of the busy/idle/waiting check the nudge gates on |
| `$CLAUDE_PROJECTS_DIR` (default `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects`) | Claude Code, not this tool | read-only: conversation transcripts, one directory per working directory; checked for existence before resuming a conversation after a restart |

### Configuration reference

Global variables live in `/etc/claude-guardian/config.env`, a plain `KEY="value"` shell file sourced first. Per-instance overrides (`WORKDIR`, `CLAUDE_ARGS`, `CLAUDE_BIN`) live in `/etc/claude-guardian/instances/<name>.env`, sourced on top for that instance only — see `new --workdir`/`--args`/`--claude-bin`. The repo's `.env.example` documents the global defaults for reference (this project has no separate app-level `.env` — the installed config file *is* the runtime configuration).

| Variable | Meaning | Default | Scope | Required |
|---|---|---|---|---|
| `TMUX_SOCKET` | shared tmux server socket path | `/run/claude-guardian/tmux.sock` | global | no |
| `WORKDIR` | working directory `claude` starts in | `/root` | global, overridable per instance | no |
| `CLAUDE_BIN` | `claude` executable name or absolute path | `claude` | global, overridable per instance | no |
| `CLAUDE_ARGS` | extra CLI args passed on every (re)start | `--permission-mode auto --remote-control` | global, overridable per instance | no |
| `CHECK_INTERVAL_SEC` | seconds between liveness checks | `5` | global | no |
| `REQUIRED_APT_PKGS` | space-separated apt packages auto-installed if missing | `tmux uuid-runtime` | global | no |
| `UNATTENDED_NUDGE_SEC` | unattended-only: how long a confirmation dialog may sit unanswered, with no tmux client attached, before a bare Enter answers it on the operator's behalf; `0` (the default) never sends one. A session that is working or at an empty prompt is never typed into either way | `0` | global | no |
| `REMOTE_CONTROL_CHECK_SEC` | unattended-only: seconds between connection checks. The check is passive — it reads the session file and types nothing — so the default is one check per supervision tick; `0` disables | `5` | global | no |
| `REMOTE_CONTROL_RECONNECT_BACKOFF_SEC` | minimum seconds between two reconnect attempts for one instance. The reconnect is the only part that types (`/remote-control`), so this bounds how often an instance that cannot reconnect is typed into | `60` | global | no |
| `CLAUDE_SESSIONS_DIR` | where Claude Code writes its per-session JSON files; read-only, and what makes the connected/disconnected and busy/idle/waiting checks possible | `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/sessions` | global | no |
| `CLAUDE_PROJECTS_DIR` | where Claude Code keeps conversation transcripts; read-only, checked before resuming a conversation after a restart | `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects` | global | no |
| `RESUME_AFTER_RESTART` | `1`: after a restart that took the tmux session with it, bring the instance back on the conversation it already had; `0`: always start a new one | `1` | global, overridable per instance | no |
| `MAX_SESSIONS` | `new`/`resume` refuse once this many instances already exist; `0` = no limit | `0` | global | no |

## Setup from scratch

1. Clone the repo (a tag, not the branch tip) onto the target Debian server, as root — verify: `git clone ...` exits 0 and `bin/claude-guardian.sh` exists.
2. `bash bin/claude-guardian.sh check` — verify: prints the three check sections (`apt dependencies`, `claude CLI`, `login state`) with `[ok]`/`[missing]`/`[warn]` markers and does not modify anything.
3. `bash bin/claude-guardian.sh install` — verify: ends with `install complete`; `systemctl is-enabled claude-guardian@claude-code` prints `enabled` (the default instance is created and enabled automatically).
4. `claude-guardian start` — verify: `systemctl is-active claude-guardian@claude-code` prints `active`.
5. `claude-guardian attach` — verify: drops you into a live `claude` terminal inside tmux (name defaults to `claude-code`), and the pane shows a `/remote-control is active ... https://claude.ai/code/session_...` line — that URL is controllable from the web or a phone independent of this SSH session, and is also printed by `claude-guardian url claude-code` without attaching at all. Detach with the tmux prefix (default `Ctrl+b`) then `d` — **not** Ctrl+C.
6. `claude-guardian new second-instance` — verify: `claude-guardian list` shows two rows (`claude-code`, `second-instance`), each with its own `SYSTEMD`/`TMUX`/`URL` columns, confirming both are independently supervised and remotely controllable.
7. From a second terminal, actually exit `claude` from inside a session and verify the respawn — e.g. `tmux -S /run/claude-guardian/tmux.sock send-keys -t claude-code C-c C-c` (Claude Code treats a single Ctrl+C as "interrupt current turn," matching most REPLs; it takes two in quick succession to actually exit, same as typing `/exit`). Verify: within `CHECK_INTERVAL_SEC`, `claude-guardian logs claude-code` shows a `respawning automatically` line, the `claude` PID (`pgrep -f 'claude --permission-mode'`) has changed for that instance, and `claude-guardian attach` shows a live session again (with a newly re-captured remote-control URL).
8. `claude-guardian deactivate second-instance` then check `pgrep -f 'claude --permission-mode'` — verify: both `claude` processes are still running (deactivate only pauses supervision, see Known limitations on `KillMode`). `claude-guardian activate second-instance` again — verify: the same `claude` PID for that instance is still there (supervision resumes against the existing session instead of recreating it).
9. `claude-guardian archive second-instance --yes` — verify: `claude-guardian list` no longer shows `second-instance`; `claude-guardian archives` shows one entry for it with a saved `scrollback.txt`; `pgrep -f 'claude --permission-mode'` shows only the `claude-code` process remains.
10. `claude-guardian resume second-instance` (or the exact archive id from step 9) — verify: `claude-guardian list` shows `second-instance` again, and `claude-guardian attach second-instance` continues the same conversation instead of starting fresh.
11. Disconnect Remote Control from inside the session (`/remote-control` → `Disconnect this session`) and detach — verify: within `REMOTE_CONTROL_CHECK_SEC` (5s by default) `claude-guardian logs claude-code` shows `remote control disconnected ... reconnecting` followed by a *new* URL, and `claude-guardian url claude-code` prints that new URL. Leave the instance connected and detached for several minutes afterwards — verify the log stays completely silent, i.e. checking every tick costs nothing visible and types nothing. To exercise the reconnect backoff, disconnect and then immediately break reconnection (e.g. take the network down): the `reconnecting` line must appear at most once per `REMOTE_CONTROL_RECONNECT_BACKOFF_SEC`, not once per tick.
12. With the default `UNATTENDED_NUDGE_SEC=0`: trigger a confirmation dialog (easiest with `--permission-mode default`: ask it to run any shell command), detach, and leave it for several minutes — verify: `claude-guardian logs claude-code` never shows a `sending Enter` line and the dialog is still waiting when you come back. Nothing answers it for you. Then set `UNATTENDED_NUDGE_SEC="60"` in `/etc/claude-guardian/config.env`, `claude-guardian restart claude-code`, and repeat — verify: at the 60s mark the log shows `has been waiting on a confirmation for Ns with nobody attached` followed by `sending Enter`, and the dialog is gone. Reattach and detach once more — verify it does not fire again immediately (timers reset on attach). Set it back to `0` afterwards.
13. `reboot` the host — verify: after boot, every instance that was `activate`d (not `deactivate`d) is `active` again without manual intervention, `claude-guardian logs <name>` shows `continuing this instance's previous conversation (<uuid>)`, and attaching shows the conversation from before the reboot rather than an empty one. To rehearse this without rebooting: `claude-guardian stop <name>`, `tmux -S /run/claude-guardian/tmux.sock kill-session -t <name>`, `claude-guardian start <name>`.

This project is not deployed with Docker; steps above are the full deployment procedure.

## Data model / file layout

```
repo/
├── bin/claude-guardian.sh   # the entire tool — self-contained, no other source files
├── README.md / README.zh.md
├── DESIGN.md / DESIGN.zh.md
├── .env.example             # documents the global config.env variables (see Configuration reference)
└── ...
```

There is no separate systemd unit file or config template checked into the
repo: `claude-guardian install` generates both from heredocs embedded in
`bin/claude-guardian.sh`, so this one file is a complete, self-contained
deployment artifact — copying it anywhere and running `install` is
sufficient, without needing the rest of the repo.

## Known limitations & gotchas

- **`UNATTENDED_NUDGE_SEC` (auto-Enter) is off by default since v0.6.0, and
  turning it on is a deliberate safety tradeoff, not a neutral convenience
  feature.** Everything below describes what you are opting into; at the
  default `0` none of it happens and a confirmation dialog simply waits
  until a human answers it. `--permission-mode
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
  v0.4.0 narrowed *who* it can happen to — the Enter goes only to a session
  `claude` itself reports as `waiting`, and only after the dialog has gone
  unanswered for the full interval, so a session somebody is working in is
  not typed into. What that could not fix is the residual case: a human on
  claude.ai who opens a dialog and then leaves it longer than
  `UNATTENDED_NUDGE_SEC` while still intending to answer it is
  indistinguishable, from the outside, from an abandoned session — and it
  was observed happening in production the day v0.4.0 shipped. There is no
  signal that separates the two, so v0.6.0 stopped trying: the feature is
  off unless the operator turns it on, and the loop then holds the same
  `waiting`-only rule. Whoever turns it on is choosing "an abandoned
  instance unsticks itself" over "nobody but me ever answers a permission
  prompt".
- **`claude-guardian install`/`new` auto-install missing apt packages
  non-interactively** (`DEBIAN_FRONTEND=noninteractive apt-get install -y`).
  By default this is `tmux` and `uuid-runtime`. If you widen
  `REQUIRED_APT_PKGS`, review what you are asking it to install unattended.
- **Missing `claude` binary makes an instance's service fail-loop for about
  a minute, then stop.** `preflight_enforce` hard-fails if `claude` is not
  found (by design — this tool never installs it). `StartLimitBurst=10` /
  `StartLimitIntervalSec=60` in the unit stop systemd from restarting
  forever; after that the instance sits in `failed` state until you install
  `claude` and run `systemctl reset-failed claude-guardian@<name> &&
  claude-guardian start <name>`.
- **`claude-guardian deactivate <name>` (`systemctl disable --now`) does
  not kill the live session — this required `KillMode=process` in the unit,
  verified against the real binary.** systemd's *default* `KillMode` is
  `control-group`, which would SIGTERM the entire cgroup on stop/restart,
  including the tmux server and `claude` itself (this was caught live: the
  first version of the unit had no explicit `KillMode` and a `systemctl
  restart` silently killed and recreated the session). With
  `KillMode=process`, only the tracked loop PID is signaled, so `claude`
  and its tmux session survive a `stop`/`restart`/`deactivate` of that
  instance's supervisor. One side effect: systemd logs a benign `Found
  left-over process ... in control group` notice on the next `start`,
  because the previous `claude` process is still in the cgroup — this is
  expected, not an error. To actually end one instance's conversation, use
  `claude-guardian archive <name>` (destructive, confirmed by default); to
  tear down everything, `claude-guardian purge` (also confirmed by
  default, and does not touch archives — see below).
- **`purge`'s blast radius grew from "one session" to "every live
  instance"** when multi-instance support was added (see `DECISIONS.md`,
  2026-08-17). It now prints the live instance count and requires
  interactive confirmation (or `--yes`) before killing anything, and
  deliberately never deletes `/var/lib/claude-guardian/archive/` — remove
  individual archives explicitly with `rm-archive` if you want them gone
  too.
- **Three behaviours now depend on internal Claude Code files.**
  `$CLAUDE_SESSIONS_DIR/<pid>.json` (fields `bridgeSessionId`, `status`,
  `statusUpdatedAt`) and `$CLAUDE_PROJECTS_DIR/<slugged-workdir>/<id>.jsonl`
  are not a documented, promised interface; a future Claude Code may
  rename, move, or stop writing them. All verified against 2.1.202. Each
  degrades rather than breaks when its file is absent or unreadable:
  the connected check falls back to sending `/remote-control` and reading
  the URL off the screen (what v0.2.0 always did), the nudge falls back to
  the wall clock (also v0.2.0 behaviour), and a resume that cannot be
  confirmed simply starts a new conversation. Both paths are overridable in
  the config (`CLAUDE_SESSIONS_DIR`, `CLAUDE_PROJECTS_DIR`) so a moved file
  can be pointed at without patching the script. The transcript directory
  name is derived by replacing every character outside `[A-Za-z0-9]` in the
  working directory with `-`; if that convention changes, resume-after-reboot
  silently stops finding transcripts and every reboot starts a fresh
  conversation again — the symptom to look for, since nothing errors.
- **Reconnecting Remote Control sends literal keystrokes (`C-u`,
  `/remote-control`, `Escape`) into the tmux pane**, as does the initial
  capture at instance creation (right after the onboarding double-Enter).
  Unlike v0.2.0 this no longer happens on a timer — only when the check
  above says Remote Control is actually disconnected — but if `claude` is,
  unexpectedly, on a screen other than its normal prompt at that exact
  moment (e.g. an onboarding step beyond the two Enters already sent),
  those keystrokes can be typed into the wrong place. Harmless (nothing is
  auto-confirmed by this step, and Escape dismisses rather than selects)
  but it may leave stray text that needs clearing manually via
  `claude-guardian attach <name>`. Same class of "blind keystroke" tradeoff
  already accepted for the double-Enter onboarding clear and the unattended
  nudge; see the `UNATTENDED_NUDGE_SEC` entry above.
- **A reconnect changes the instance's `claude.ai/code/...` URL.** The
  conversation is unaffected — it is the same `claude` process and the same
  `claude_session_id` — but a previously-bookmarked link stops working.
  There is no way to both genuinely reconnect and keep the old URL, so the
  tool optimises for the connection being live and expects the URL to be
  fetched on demand (`claude-guardian url <name>`) rather than saved.
- **`resume` can only reconstruct a conversation if the archive has a
  recorded `claude_session_id`.** This is always true for archives created
  by this tool's own `archive` command (the id is captured at instance
  creation and carried through), but if an archive directory is ever
  hand-edited or `meta.env` is lost, `resume` refuses and points at the
  raw `scrollback.txt` instead of guessing.
- **`install` migrates a v0.1.0 single-instance deployment in place**
  (`migrate_legacy_unit`): it disables/removes the old
  `claude-guardian.service` and enables the new
  `claude-guardian@claude-code.service` against the *same* tmux session.
  This relies on `KillMode=process` in both the old and new unit to be
  true (verified above) — if a future systemd unit change ever drops that
  setting, this migration path would need re-verification against a live
  session before being trusted again. Verified against a real production
  host: the tmux pane's PID and liveness were unchanged immediately before
  and after `install`.
- **A migrated pre-existing session never gets a tracked
  `claude_session_id`, `workdir`, or captured URL until it is genuinely
  recreated** — discovered on the same live migration above.
  `respawn-pane` only ever replays the *original* command tmux stored when
  the session was first created; for a session that predates v0.2.0, that
  original command has no `--session-id`, so no crash-respawn will ever
  retroactively add one. Practically: `list` shows `-` for that instance's
  workdir, its URL is still found (that comes from claude's own session
  file, which every running session has, and the missing tracked id only
  skips half of the PID-reuse cross-check), and `archive` on that
  instance will
  save an empty `claude_session_id` — `resume` will then correctly refuse
  and point at the raw scrollback instead of guessing. The only way to
  give a migrated instance a real, resumable session id is to let its
  tmux session actually end and be recreated (e.g. `archive` it once,
  deliberately, then `resume`/`new` it back) — there is no in-place
  backfill, and hand-editing its state file would just fabricate an id
  `claude` never actually used.
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
- **Login is enforced at `install` time only, not continuously.** `install`
  hard-refuses if `claude auth status` fails (verified against both real
  states: logged in, and an isolated `HOME` with no credentials at all —
  exits 0 vs. 1 respectively). Once installed, `run` only warns if auth is
  missing or later lost — the service keeps retrying and `claude` shows its
  normal interactive login flow the next time someone attaches, rather than
  refusing to start. This is deliberate, not an oversight: a service that
  was working and later loses auth (expired token, revoked session) should
  keep trying to serve, not go into a restart-fail loop.
- **`REMOTE_CONTROL_CHECK_SEC` bounds how long a dropped connection can go
  unnoticed, and nothing more.** v0.2.0 set this to 1200s to stay inside
  Anthropic's documented ~30-minute "could not reach the Remote Control
  server" window, on the assumption that re-running `/remote-control`
  beforehand would keep the connection from ever expiring. That assumption
  was wrong (see `DECISIONS.md`, 2026-08-17), which left a 20-minute number
  doing a job it was never chosen for: it had become "how long an instance
  can sit unreachable", and in production it did exactly that. Since v0.6.0
  the check runs every tick (5s) — it is a single file read that types
  nothing, so there was never a reason for it to be slow — and the old
  variable is gone. A config still setting `REMOTE_CONTROL_REFRESH_SEC`
  gets a warning at loop start; the setting itself is ignored.
- **A reconnect that keeps failing is retried on a backoff, not on every
  check.** `REMOTE_CONTROL_RECONNECT_BACKOFF_SEC` (60s) exists because the
  reconnect is the one step that types into the session: without it, an
  instance whose Remote Control cannot come back would get `/remote-control`
  typed into it every 5 seconds. When `claude` writes no usable session file
  at all, nothing can ever confirm success, so that case falls back to a
  much slower internal retry (1200s) instead of the 60s backoff.
- **The unattended-nudge/connection timers only start counting from when the
  supervision loop itself (re)starts, not from whenever the session was
  actually last attended.** This was a real bug caught live: the first
  version initialized both timers to `0` (epoch), so any `systemctl
  restart` against an already-unattended session fired an immediate nudge
  and refresh instead of waiting out the configured interval. Fixed by
  seeding both timers with the current time at loop start.

## How to extend

- **New preflight checks** go in both `preflight_report` (report-only) and
  `preflight_enforce` (may mutate / hard-fail) — keep the two in sync so
  `check` accurately previews what `run`/`install`/`new` will do.
- **New global config variables** are added by extending both the default
  block near the top of `bin/claude-guardian.sh` and the heredoc in
  `write_default_config`, plus a row in this document's Configuration
  reference table and in `.env.example`. **New per-instance overrides**
  instead go through `write_instance_file` and a new `new --flag` option —
  keep the set small; `WORKDIR`/`CLAUDE_ARGS`/`CLAUDE_BIN` were chosen
  because they're the only knobs a real per-instance need has come up for
  (see `DECISIONS.md`, 2026-08-17).
- **A per-instance TMUX_SOCKET or an HTTP control API** were both
  considered and rejected when multi-instance support was added — see
  `DECISIONS.md`, 2026-08-17, "Rejected", before reintroducing either.
- **New instance-lifecycle subcommands** should follow the existing
  pattern: read/write state only through `instance_file`/`state_get`/
  `state_set`, never touch another instance's files, and update `usage()`
  (the comment block) and the `main()` case statement together — `usage()`
  is generated from that comment block via `sed`, so drift between the two
  is not possible as long as both are edited in the same change.
