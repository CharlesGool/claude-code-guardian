# Decisions

Newest first. Append only — never delete or rewrite an entry. To reverse a past
decision, add a new entry that says so explicitly.

**Read this file before proposing any technical approach.** Without it, an
already-rejected option gets recommended again two weeks later.

---

## 2026-08-17 — reverses "single default session" (2026-08-16): add named, concurrent multi-instance support

- **Context:** the operator's real workflow evolved into wanting several
  independent, concurrently-supervised `claude` conversations available at
  once (e.g. one per project), each separately remotely-controllable, with
  the ability to pause ("deactivate") or permanently archive one without
  affecting the others — none of which the single-instance design could
  do. Before building anything, it was verified live that a single
  claude.ai account *can* host more than one concurrent
  `--remote-control` session (the operator was already doing this
  manually) — this was the one open technical unknown from the 2026-08-16
  decision below ("Revisit if the operator later needs to run more than
  one Claude instance concurrently").
- **Decision:** turn the systemd unit into a template
  (`claude-guardian@<name>.service`), exactly as sketched in DESIGN.md's
  "How to extend" section at the time. One tmux server (one
  `TMUX_SOCKET`), many named sessions — tmux already supports this
  natively, so no per-instance socket was needed. Per-instance config
  lives at `/etc/claude-guardian/instances/<name>.env` (overrides
  `WORKDIR`/`CLAUDE_ARGS`/`CLAUDE_BIN` only); `TMUX_SOCKET`,
  `CHECK_INTERVAL_SEC`, `REQUIRED_APT_PKGS`, `UNATTENDED_NUDGE_SEC`,
  `REMOTE_CONTROL_REFRESH_SEC`, and the new `MAX_SESSIONS` stay global,
  shared machine-wide knobs — instance-specific overrides for those were
  not a real requirement, and adding them would have doubled the config
  surface for no asked-for benefit.
- **New capabilities added as part of this reversal:**
  - `new` / `activate` / `deactivate`: create, resume-supervision, and
    pause-supervision-without-killing-the-session, respectively.
    `deactivate` was deliberately kept distinct from `archive` — the
    operator asked for both "取消激活" (pause) and "归档" (archive) as
    separate, non-destructive-vs-destructive operations.
  - `archive` / `resume` / `archives` / `rm-archive`: the operator
    confirmed archiving should **kill** the live claude process after
    saving state (not just deactivate-and-leave-running) — see the
    "archive kills the process" sub-decision below.
  - Each instance now gets a `claude --session-id <uuid>` at creation
    (generated via `uuidgen`, hence `uuid-runtime` added to
    `REQUIRED_APT_PKGS`) instead of leaving it implicit, specifically so
    `archive` can record which on-disk conversation
    (`~/.claude/projects/<escaped-cwd>/<uuid>.jsonl`) belongs to which
    instance, and `resume` can hand that same id back to
    `claude --resume <uuid>`. Verified directly: `claude --help` exposes
    `--session-id`, `--resume`, and `--fork-session`; conversation
    transcripts do live at that path (confirmed against this host's own
    `~/.claude/projects/-root/*.jsonl`).
  - The claude.ai remote-control URL (`https://claude.ai/code/session_...`)
    is now scraped from the tmux pane right after each instance starts
    (and re-scraped on every unattended `/remote-control` refresh) and
    stored in per-instance state, so `claude-guardian url <name>` /
    `list` can print it without a human ever needing to attach — this was
    the operator's explicit goal ("以后都不需要终端"). Verified live: the
    text `https://claude.ai/code/session_...` is present in
    `tmux capture-pane -p`'s output right after `/remote-control` runs.
- **Sub-decision — archive kills the process, not just deactivates:**
  confirmed explicitly with the operator (asked directly: deactivate-only
  vs. capture-then-kill). Rationale: an "archived" instance should free
  its tmux pane and process resources, not sit paused forever counting
  against `MAX_SESSIONS`-adjacent resource limits; the scrollback and
  `claude_session_id` are saved to `/var/lib/claude-guardian/archive/`
  before the kill specifically so nothing about the conversation is lost.
- **Rejected:**
  - **Keep single-instance, let the operator run a second unrelated copy
    of the tool by hand** — defeats the point of a guardian: the second
    copy would have no supervision, no auto-respawn, no unattended
    keepalive, and no unified `list`/`archive` story.
  - **Per-instance `TMUX_SOCKET`** (one tmux server per instance) — tmux
    already multiplexes sessions on one server; a second server per
    instance would only add operational overhead (N sockets to track, N
    servers to keep alive) with no capability gained.
  - **A REST/HTTP control API for lifecycle management** — the operator's
    ask was CLI/remote-control based ("不需要终端" refers to not needing
    to SSH in, not to replacing the CLI itself, which is still driven
    from a remote `claude` session via the tool's own commands); adding a
    network-facing control plane would be a large, unrequested increase
    in attack surface for a single-operator, single-host tool.
- **Consequences:** every documented command that used to take no instance
  argument (`attach`, `logs`, `start`, `stop`, `restart`, `status`)
  still works with none, defaulting to the `claude-code` instance, so an
  existing v0.1.0 deployment's muscle-memory commands keep working
  post-upgrade. `install` on an existing v0.1.0 host disables/removes the
  old non-templated unit and re-enables the same tmux session under the
  new template (`claude-guardian@claude-code.service`) — `KillMode=process`
  in both the old and new unit means this only ever stops the supervision
  *loop*, never the tmux server or the `claude` process inside it, so an
  in-progress conversation survives the upgrade. `purge`'s blast radius
  grew from "one session" to "every live instance" — it now prints the
  live instance count and requires interactive confirmation (or `--yes`)
  before proceeding, and deliberately leaves `/var/lib/claude-guardian/archive/`
  untouched (archives must be removed explicitly via `rm-archive`) so a
  full teardown can never silently destroy an archived conversation.

---

## 2026-08-16 — `install` hard-refuses if claude isn't logged in; login check switched to `claude auth status`

- **Context:** user asked for a login check that actually blocks
  installation if Claude Code isn't logged in yet (previously, missing
  login only ever produced a warning, at both `install` and `run`).
- **Decision:**
  - Discovered `claude auth status` (JSON output, `loggedIn` field) is a
    real, authoritative auth check — verified directly: exits 0 when
    logged in, exits 1 under an isolated `HOME` with zero credentials.
    Replaced the old file-existence heuristic (checking for
    `~/.claude/.credentials.json` etc.) with this everywhere login state
    is checked, since a stale/invalid credentials file would have passed
    the old heuristic without actually being usable.
  - Added `require_login()`, called only from `cmd_install`, which `die`s
    if `claude auth status` fails — verified end-to-end with a fake
    logged-out `HOME` that `cmd_install` refuses and writes no config file.
  - `preflight_enforce` (shared by `run` and `install`) keeps its existing
    non-blocking behavior, just using the more accurate check now.
- **Rejected:** folding the hard block into `preflight_enforce` itself,
  which would also have made `run`/the live systemd service hard-fail if
  login was ever lost after a successful install — out of scope for what
  was actually asked (which was specifically about *installing*), and
  would turn a recoverable situation (re-login via `attach`) into a
  restart-fail loop for an already-working deployment.
- **Consequences:** `install` now requires `claude auth login` (or any
  other already-completed login) to have happened first — deploying the
  guardian and only then logging in interactively via `attach` is no
  longer possible; login must come first.

---

## 2026-08-16 — double Enter (not single) on first run and unattended nudge; added `purge` command

- **Context:** user reported the first-ever deployment needed Enter pressed
  twice before `claude` reached its normal prompt (likely an
  onboarding/trust screen), and asked to always send two — noting an extra
  Enter once already at the normal prompt costs nothing. Separately asked
  for a genuinely complete uninstall that removes everything, not just the
  systemd service.
- **Decision:**
  - `create_session` now sends Enter twice (one second apart) right after
    starting `claude`, instead of relying solely on the unattended-nudge
    timer to eventually clear a first-run screen.
  - `nudge_enter` now also sends Enter twice instead of once, for the same
    reason — verified with a real functional test (a stdin-line-counting
    fake process) that both paths send exactly two keystrokes, correctly
    timed, and that the full `supervise_loop` fires them at the right
    tick.
  - Added `claude-guardian purge`: stops/disables/removes the systemd
    unit (like `uninstall`), plus kills the tmux server, and removes the
    config directory and the installed binary. `uninstall` itself is
    unchanged — still the safe, routine-maintenance command that leaves
    the live session and config alone; `purge` is the new, explicit,
    deliberately destructive "remove everything" command.
  - While making this change, also found and fixed a latent bug: `usage()`
    used a hardcoded `sed -n '2,25p'` line range that had already gone
    stale (silently, no error) when the GPL header was added in an earlier
    commit, printing the wrong help text. Replaced with a pattern-matched
    range (`/^# Usage:/,/^#   run /p`) that can't drift out of sync with
    edits to the header above it.
- **Rejected:** trying to detect which specific screen is showing (trust
  dialog vs. onboarding vs. already-normal-prompt) before deciding how many
  Enters to send — not worth the added fragility when a harmless extra
  Enter achieves the same result. Also rejected changing `uninstall`'s
  existing behavior instead of adding a separate `purge` command — the
  safe default (leave the session running) is a deliberate, already-tested
  property worth keeping distinct from a full teardown.
- **Consequences:** `purge` unconditionally kills any live claude session —
  documented clearly as the difference from `uninstall`. Not covered by an
  end-to-end test against the real systemd unit on this host (that would
  have torn down the live production deployment); verified by code review
  and by re-using the already-tested `cmd_uninstall` pattern plus
  straightforward `rm -rf` on paths this tool itself owns
  (`/etc/claude-guardian`, `/run/claude-guardian`, the installed binary).

---

## 2026-08-16 — resolve CLAUDE_BIN to an absolute path, don't trust systemd's PATH

- **Context:** a fresh `install` on a second host succeeded, but the
  service immediately went into `failed` state. `preflight_enforce`'s
  `command -v "$CLAUDE_BIN"` check passed fine when run interactively
  during `install`, but failed when systemd itself ran `claude-guardian
  run` — systemd's default PATH
  (`/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin`) doesn't
  include `~/.local/bin`, which is where `claude` lives on a typical
  npm/pip user install. This host's own deployment happened to mask the
  same latent bug because it has a second `claude` at `/usr/bin/claude`
  (decoy), so it never surfaced here.
- **Decision:** two-part fix, both verified with real functional tests
  (not just code review): (1) `write_default_config` now resolves
  `CLAUDE_BIN` via `command -v` at install time — using the installer's
  own full-PATH interactive shell — and bakes the absolute path into
  `/etc/claude-guardian/config.env`, so fresh installs never hit this. (2)
  `preflight_enforce`/`preflight_report` fall back to resolving `claude`
  through `bash -ic "command -v claude"` if the plain lookup fails, so
  already-installed hosts with the bare `"claude"` default self-heal on
  the next `run`/`check` without needing the config edited by hand.
- **Rejected:** `bash -lc` (login, non-interactive) as the fallback
  mechanism — tested and confirmed it does NOT work: Debian's default
  `~/.bashrc` starts with `[ -z "$PS1" ] && return`, which fires for any
  non-interactive invocation including `bash -l`, so it returns before
  ever reaching the `PATH=` line. `bash -ic` (interactive) is what
  actually gets bash to set `$PS1` and run the rest of `~/.bashrc` — this
  was the actual, tested reason the first version of this fix wouldn't
  have worked, not a hypothetical.
- **Consequences:** `bash -ic` prints job-control/terminal warnings to
  stderr in a non-tty context (harmless, discarded — verified the noise
  never reaches the captured stdout value). Every `preflight_enforce` call
  now potentially spawns an extra interactive shell when the fast path
  fails, which only happens when `CLAUDE_BIN` isn't already resolvable —
  negligible cost, and only on the failure path.

---

## 2026-08-16 — open-sourced under GPL-3.0

- **Context:** user asked to open-source the project under GPL-3.0.
- **Decision:** added `LICENSE` (unmodified GPL-3.0 text, fetched via
  `gh api /licenses/gpl-3.0` rather than reproduced from memory), a short
  GPL notice header in `bin/claude-guardian.sh`, and updated the License
  sections of README.md/README.zh.md. Provenance check (B-tier, required
  before going public per the project-management skill): this repo vendors
  no third-party code — `bin/claude-guardian.sh` is original, and the tool
  only shells out to `tmux`/`systemctl`/`apt-get`/`claude` as external
  programs, which does not create a licensing obligation. No
  `THIRD_PARTY_NOTICES.md` needed. Also ran a full-history sensitive-info
  sweep (all commits, not just current tree) before flipping visibility —
  clean, no secrets/credentials/IPs, no files ever added-then-removed.
- **Also fixed while preparing to go public:** DESIGN.md, DESIGN.zh.md, and
  a DECISIONS.md entry had hardcoded the maintainer's internal NAS storage
  path (`/root/MyGithub_Project`) — that path is an operational convention
  of the maintainer's project-management workflow, not something that
  should ever be baked into a project's own README/DESIGN. Generalized the
  CIFS/chmod gotcha to describe the underlying filesystem behavior without
  naming the specific path, and did the same in STATUS.md's template
  comment.
- **Rejected:** nothing — no viable alternative to a license/provenance
  review before a first public release; this is a mandatory step, not a
  choice between options.
- **Consequences:** repository visibility flipped from private to public
  (see STATUS.md for the current URL). GitHub's public visibility is
  irreversible in the sense that anyone who cloned or cached the repo
  during the time it was public retains that copy even if visibility is
  later reverted to private.

---

## 2026-08-16 — project renamed claude-code-watchdog → claude-code-guardian

- **Context:** the project was scaffolded under the name `claude-code-watchdog`
  (GitHub repo, local folder, doc titles), but the CLI command, systemd
  service name, config directory (`/etc/claude-guardian`), socket path
  (`/run/claude-guardian`), and log prefix had all already been written as
  `claude-guardian` from the very first commit. User flagged the mismatch
  and asked for one consistent name across code and project.
- **Decision:** standardize on `claude-code-guardian`. Renamed the GitHub
  repo (`gh repo rename`, which auto-updated the local `origin` remote) and
  the maintainer's local project folder to match, and fixed the title/URL
  references inside README.md, DESIGN.md, and STATUS.md.
- **Rejected:** renaming the code side (CLI command, systemd unit name,
  `/etc/claude-guardian`, `/run/claude-guardian` socket) to `watchdog`
  instead — all of those were already live and deployed on the production
  host at the time this was raised; renaming them would have meant
  uninstalling and reinstalling the running service under a new name for
  no functional benefit, versus a repo/folder rename which only touches
  git-hosting metadata and doc text.
- **Consequences:** the live host's systemd unit, binary path, config
  directory, and socket path are unaffected by this change — only the
  GitHub repo name, local folder path, and documentation titles changed.
  Anyone with the old `claude-code-watchdog` GitHub URL will be
  auto-redirected by GitHub's rename redirect, but should update bookmarks.

---

## 2026-08-16 — always remotely controllable: --remote-control default, and unattended auto-Enter accepted as an explicit tradeoff

- **Context:** user reported the original design wasn't good enough for
  "always remotely controllable" — specifically asked for
  `claude --permission-mode auto --remote-control`, an auto-Enter mechanism
  to clear stuck confirmations, and a fix for Claude Code becoming
  uncontrollable after long inactivity.
- **Decision:**
  - `CLAUDE_ARGS` now defaults to `--permission-mode auto --remote-control`.
    `--remote-control` was verified live to print a `claude.ai/code/...`
    URL controllable from the web/phone, independent of SSH — this is now
    the primary remote-control path, with SSH+`tmux attach` as a fallback
    (DESIGN.md Goals/Architecture updated accordingly).
  - Added an unattended-only keepalive in `supervise_loop`: when
    `tmux list-clients` shows nobody attached, send a bare Enter after
    `UNATTENDED_NUDGE_SEC` (default 300s) to clear any confirmation `auto`
    mode fell back to, and re-run `/remote-control` after
    `REMOTE_CONTROL_REFRESH_SEC` (default 1200s) to refresh the connection
    before Anthropic's documented ~30-minute "could not reach the Remote
    Control server" threshold. Sources: `claude --help` (flag existence,
    verified locally), Anthropic's `remote-control.md` and
    `permission-modes.md` docs (30-minute threshold, auto-mode fallback
    behavior — via research, not independently reproduced end-to-end).
  - The auto-Enter mechanism was **flagged live by Claude Code's own
    auto-mode classifier** when first deployed ("defeats the
    human-in-the-loop safety fallback without explicit user authorization")
    — it accepts whatever option is currently highlighted/default without
    knowing if that's the safe choice for that specific prompt. Presented
    this tradeoff explicitly to the user (auto-Enter vs. the more
    predictable but higher-setup `--permission-mode dontAsk` +
    `permissions.allow` alternative); user confirmed proceeding with
    auto-Enter as originally requested.
- **Rejected:** `--permission-mode dontAsk` with an explicit
  `permissions.allow` list — more predictable (denies unlisted actions
  silently instead of guessing at a confirmation dialog) but requires the
  operator to enumerate allowed actions up front. Not what was asked for;
  documented in DESIGN.md Known limitations as the alternative to reach for
  if the auto-Enter tradeoff turns out to be unacceptable in practice.
- **Consequences:** an unattended, `auto`-mode confirmation prompt will be
  auto-accepted at whatever is currently the default/highlighted option,
  which is not guaranteed to be the safe choice — this is a real, accepted
  safety tradeoff, not an oversight. `UNATTENDED_NUDGE_SEC="0"` disables it
  per-deployment if that tradeoff needs to be revisited later. Also
  surfaced (and fixed) two implementation bugs found only by testing this
  live against the real `claude` binary and a real `systemctl restart`:
  timers starting from epoch 0 instead of loop-start time (caused an
  immediate spurious nudge/refresh on every restart of an
  already-unattended session) — see DESIGN.md Known limitations for both
  this and the separately-discovered `KillMode` bug.

---

## 2026-08-16 — single default session, not multi-session templating

- **Context:** deciding whether `claude-guardian` should support several
  concurrently supervised, independently named `claude` sessions (e.g. via a
  systemd template unit `claude-guardian@%i.service`).
- **Decision:** support exactly one default session (`claude-code`),
  configured via `/etc/claude-guardian/config.env`. Confirmed with the user.
- **Rejected:** systemd template unit + per-instance config directory for
  N concurrent sessions — real requirement was "at least one always
  available," not "many always available." Multi-session support can be
  added later if a real need shows up (see DESIGN.md "How to extend").
- **Consequences:** simpler unit file, simpler config, simpler CLI (no
  `<name>` argument threaded through every command). Revisit if the operator
  later needs to run more than one Claude instance concurrently on the same
  host.

---

## 2026-08-16 — tmux + systemd two-layer supervision, not screen or a custom daemon

- **Context:** the requirement is that a `claude` instance must survive both
  a host reboot and a manual Ctrl+C kill of the `claude` process itself,
  while remaining attachable for remote takeover over SSH.
- **Decision:** two independent layers — systemd (`Restart=always`)
  supervises a bash loop, which in turn keeps a `tmux` session alive and
  respawns the pane if `claude` exits. See DESIGN.md → Architecture.
- **Rejected:**
  - **`screen` instead of `tmux`** — screen has no scriptable
    "is the process in this window still alive" query equivalent to tmux's
    `#{pane_dead}` format string; detecting a Ctrl+C'd process would need
    polling `/proc` or parsing `screen -list`, both less reliable.
  - **A single-layer systemd-only design** (`ExecStart=claude` directly,
    `Restart=always`) — would restart `claude` on exit, but the operator
    would lose the interactive terminal/session entirely on every restart
    (no scrollback, no way to "reattach" — systemd units are not
    directly attachable ttys) and there is no clean remote-takeover story.
  - **A custom Python/Go supervisor daemon** — no meaningful advantage over
    shelling out to `systemd` + `tmux`, which are already present on every
    Debian target, at the cost of a build/runtime dependency.
- **Consequences:** the tool depends on both `systemd` (assumed present, not
  checked) and `tmux` (checked and auto-installed by preflight). Detaching
  safely requires the tmux prefix key, not Ctrl+C — documented as a gotcha
  in DESIGN.md and README.md.

---

## 2026-08-16 — this tool never installs or auto-authenticates the Claude Code CLI

- **Context:** user's explicit instruction: preflight should check whether
  `claude` is installed and whether it's logged in, but must not attempt to
  install Claude Code itself.
- **Decision:** `claude` presence is a hard-fail precondition (checked, not
  fixed); login state is checked on a best-effort basis (looks for known
  credential file locations) and only produces a warning, never blocks
  startup — `claude`'s own interactive login flow runs naturally the first
  time an operator attaches.
- **Rejected:** auto-installing `claude` via `npm i -g @anthropic-ai/claude-code`
  or similar when missing — explicitly out of scope per the user's request.
- **Consequences:** on a fresh host with no `claude` installed, `install`
  and `run` both fail loudly with an actionable message rather than doing
  anything on the operator's behalf.
