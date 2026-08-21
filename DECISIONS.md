# Decisions

Newest first. Append only — never delete or rewrite an entry. To reverse a past
decision, add a new entry that says so explicitly.

**Read this file before proposing any technical approach.** Without it, an
already-rejected option gets recommended again two weeks later.

---

## 2026-08-21 — enforce the "at least one session" floor, and default it to on

- **Context:** the operator asked whether a host whose resident sessions had
  all been closed would bring one back on reboot. It would not. The
  2026-08-16 entry below records the founding requirement as "at least one
  always available", and v0.1.0's changelog says the tool "keeps at least
  one remotely-attachable Claude Code session alive" — but after v0.2.0
  moved to multi-instance templating, nothing enforced it. It was emergent:
  `install` enables the default instance, systemd starts whatever is
  enabled, and no one had archived the last one. `archive` (disable +
  delete the config) and `deactivate` (disable) both take the count to zero
  with no check and no warning; the host that prompted this question was in
  exactly that state after the v0.7.0/v0.8.0 withdrawal, and a reboot would
  have produced nothing at all.
- **Decision:** two mechanisms, deliberately separate.
  (A) `archive`/`deactivate` warn — and ask, unless `--yes` — when the
  instance being removed is the last one that would come up at boot.
  (B) A `oneshot` unit, `claude-guardian-floor.service`, runs
  `ensure-floor` once per boot and recreates + starts the default instance
  when nothing else would. New setting `ENSURE_DEFAULT_INSTANCE`,
  **default `1`**.
- **Why default on:** the question that started this was "surely it should
  bring one back?" — shipping it off by default would leave that
  expectation unmet for everyone who does not read the config file. A tool
  whose entire purpose is "a session is always reachable" should not make
  the guarantee opt-in. The opt-out exists and is documented in three
  places, which is the right way round.
- **Counted on `is-enabled`, not on config files:** `deactivate` leaves the
  config file behind, so counting `$INSTANCES_DIR/*.env` would report
  instances that will never start. The floor asks the question that
  matters — how many units would systemd actually bring up.
- **Accepted consequence:** at `ENSURE_DEFAULT_INSTANCE=1`, deactivating the
  *last* instance is undone at the next boot, which contradicts
  `deactivate`'s own promise of "won't restart at boot". The guarantee wins,
  and `deactivate` now says so out loud before it acts. A host genuinely
  meant to boot idle sets `ENSURE_DEFAULT_INSTANCE=0`; that is not the same
  operation as deactivating everything, and conflating the two is what
  produced the silent-zero state in the first place.
- **Rejected:**
  - **Warning only (A without B)** — the operator's question was about what
    happens on reboot, and a warning does nothing for a host already at
    zero, which this one was.
  - **A floor that runs continuously, on every supervision tick** — it would
    re-create an instance seconds after a deliberate `archive`, making
    `archive` unusable. Once per boot is the cadence that matches the
    promise ("survives a reboot") without fighting the operator.
  - **Folding the floor into the instance template unit** — the template's
    units only exist for instances that are already enabled, so none of them
    runs in the one state that needs repairing. It has to be its own unit.
  - **`systemctl enable --now` inside the floor** — waiting on another
    unit's start job from inside the boot transaction is a deadlock risk;
    `enable` + `start --no-block` gets the same result without blocking.
  - **Reusing the version number `v0.7.0`** — that tag and `v0.8.0` were
    both pushed and then deleted. Anyone who fetched either would get
    different code under the same name on a re-fetch, which is the reason
    the release rules forbid moving a published tag. This ships as
    `v0.9.0`; `v0.7.0` and `v0.8.0` stay burned.
- **Verified:** shellcheck-clean; a 48-case isolated suite against a stub
  `systemctl`/`claude` in a sandboxed path tree (floor at zero / at one / at
  two / with every instance deactivated / opted out; the warning on archive
  and on deactivate, present and absent, under both settings, in a non-tty
  and under a pty; `--yes` handling; install/uninstall/purge unit wiring;
  regressions on `list`/`archives`/usage). The same suite run against the
  v0.6.2 baseline fails 27 of those 48, so it can actually detect the
  absence of this work rather than merely agreeing with it — the lesson
  from the v0.6.1 defect below. Then live on the maintainer's host with
  real systemd: `install` wrote and enabled the floor unit; `deactivate` of
  the only instance refused without `--yes` and warned with it; starting the
  floor unit at zero brought the instance back (real `claude` process, tmux
  session up, no boot deadlock); starting it again logged `already enabled
  — nothing to do` and created no second session.
- **Not verified live:** the branch where the instance config file is
  missing entirely (the `archive` path) — the sandbox covers it, but on the
  live host `archive` was blocked by a permission classifier and was not
  worked around. Nor was an actual reboot; the floor unit was exercised by
  starting it directly, which is the same code path systemd runs at boot.

---

## 2026-08-21 — withdraw v0.7.0 and v0.8.0; the code baseline returns to v0.6.2

- **Context:** four supervised instances and, separately, a plain `claude`
  the tool was not supervising all became unreachable from claude.ai
  ("Can't reach your computer") after sitting idle. The supervisor log was
  clean across an eleven-hour window before the first recorded drop, which
  is the failure mode this project has been chasing since v0.6.0.
- **Decision:** the maintainer judged the v0.7.0 Remote Control rework to be
  the cause and withdrew it. The installed binary was rolled back to v0.6.2;
  the `v0.7.0` and `v0.8.0` tags were deleted locally and on the remote, the
  `v0.7.0` Release object was deleted, both snapshot directories were
  removed, and `main` was force-reset to `v0.6.2`. All later work starts
  from the v0.6.2 baseline.
- **Why (the maintainer's judgement):** the drops began after v0.7.0 shipped
  and were not observed on v0.6.2.
- **Evidence recorded against that judgement, so it is not re-argued from
  memory:** (1) the same drop hit a plain `claude` running outside tmux at a
  moment when zero supervised instances existed, and no version of this tool
  can cause a drop in a process it is not supervising; (2) v0.7.0's own
  changelog listed "an instance could sit unreachable indefinitely behind a
  clean log" as a defect it *fixed* — that was v0.6.2 behaviour, so the
  rollback restores it; (3) the real v0.7.0 regression was dropping
  `--permission-mode auto` from `CLAUDE_ARGS`, which crash-loops a root
  instance whose settings request `bypassPermissions`, and v0.8.0 had
  already fixed exactly that. This decision was taken with those three
  points on the table.
- **What the withdrawal costs:** the `reconnect` command, the isolated
  23-case Remote Control suite, `REMOTE_CONTROL_MAX_BRIDGE_AGE_SEC` (the
  only automatic recovery from a bridge that dies silently upstream), and
  `BACKLOG.md`. Until something replaces them the only remedy for an
  unreachable session is to attach and type `/remote-control` by hand.
- **Also learned, and it outlives this decision:** a bridge id survives a
  restart. A killed instance brought back with `claude --resume` re-attaches
  the *same* `bridgeSessionId`, so the claude.ai URL is unchanged (verified
  on four instances). The id therefore cannot be read as proof that anything
  is flowing, and an unchanged URL after a restart is not a symptom.
- **Open, and the reason this entry exists:** the deciding experiment had
  not been run when the deletion was made — leave an instance idle overnight
  and see whether v0.6.2 drops too. If it does, the cause is the Remote
  Control link rather than this tool, and the withdrawn work is worth
  recovering; a full bundle of every deleted ref was taken beforehand and
  its location is in the maintainer's local notes. If it does not drop, the
  judgement above is confirmed and the v0.7.0 diff is where to look.

---

## 2026-08-17 — watch the connection on every tick, and stop answering dialogs by default

- **Context:** within an hour of v0.4.0 going live with three instances, the
  operator reported "怎么其他两个会话都disconnected了". Both were genuinely
  disconnected (`bridgeSessionId: null`) and both were working fine
  otherwise — alive, mid-conversation, simply unreachable from claude.ai.
  Nothing was broken: the supervisor checks every
  `REMOTE_CONTROL_REFRESH_SEC` (1200s) and one instance self-healed at the
  next check while we were looking at it. That *is* the problem. The same
  investigation showed the other half: that instance's log carried three
  `sending Enter` lines — the unattended nudge had answered confirmation
  dialogs the operator had opened from claude.ai and not yet answered.
- **Decision (connection):** the check runs every supervision tick
  (`REMOTE_CONTROL_CHECK_SEC`, default 5s = `CHECK_INTERVAL_SEC`), and the
  reconnect is rate-limited on its own timer
  (`REMOTE_CONTROL_RECONNECT_BACKOFF_SEC`, default 60s).
  `REMOTE_CONTROL_REFRESH_SEC` is removed, with a startup warning if a
  config still sets it.
- **Why:** the 1200s number was inherited from v0.2.0, where it meant "how
  often to re-send `/remote-control` to keep the connection alive". v0.3.0
  proved that assumption false and made the check passive, but kept the
  number — so a value chosen as a keystroke interval silently became "how
  long an instance may sit unreachable". A file read costs nothing and types
  nothing; there was never a reason to do it slowly. Separating the two
  timers is what makes that safe: only the reconnect touches the session, so
  only the reconnect needs a backoff. The degenerate case (no usable session
  file at all, so nothing can ever confirm success) keeps a much slower
  internal 1200s retry, otherwise it would type `/remote-control` into that
  session forever.
- **Decision (nudge):** `UNATTENDED_NUDGE_SEC` defaults to `0` — the
  supervisor does not answer confirmation dialogs unless the operator
  explicitly turns it on.
- **Why:** v0.4.0 assumed "no tmux client + parked on a dialog for the full
  interval" was a good proxy for "abandoned". Production showed it is not:
  Remote Control is not a tmux client, so an operator reading a dialog on
  their phone is indistinguishable from an abandoned session, and Enter
  accepts whatever is highlighted. Rejected alternatives: raising the
  interval (makes the window smaller, keeps the failure mode, and slows real
  recovery); treating a *connected* Remote Control as "somebody can answer"
  and nudging only when disconnected (still guesses — a connected session
  can be genuinely abandoned, and it would have changed nothing in this
  incident, since both instances were disconnected); keeping it on and
  documenting harder (v0.4.0 already documented it, and it still surprised
  the person who wrote the documentation). The feature stays, with its
  `waiting`-only guard, for operators who prefer an instance that unsticks
  itself — it just is not the default.
- **Consequence:** an abandoned instance parked on a dialog now stays parked
  until a human answers it. That is the intended tradeoff: the supervisor's
  job is to keep the session *reachable*, not to make decisions inside it.

---

## 2026-08-17 — resume the conversation across a reboot instead of starting an empty one

- **Context:** the operator's report, after v0.3.0 had been running a while:
  "重启后恢复的也没有记录啊，所以没什么意义" — the instances did come back
  after a reboot, but each on a blank conversation, so what survived was the
  *process*, not the *work*. This had been recorded as a v0.3.0 known issue;
  production use made it the more important of the two.
- **What was actually happening:** `respawn-pane` reuses the pane's original
  command line, so a `claude` that crashes comes back on the same
  `--session-id` — that path was always fine. A reboot is different: it
  takes the tmux server with it, so `create_session` runs, and it minted a
  fresh `uuidgen` id unconditionally. Confirmed on the operator's host: the
  pre-reboot transcript was intact on disk (4.6 MB, last written seven
  minutes before the reboot) and simply orphaned.
- **Decision:** `create_session` now prefers the instance's own last
  `claude_session_id` — already recorded in state for `archive`/`resume` —
  and starts `claude --resume <id>`, gated on that conversation's transcript
  still existing under `$CLAUDE_PROJECTS_DIR`. Order of preference: explicit
  `RESUME_SESSION_ID` (from `resume <archive-id>`), then the instance's own
  previous conversation, then a new id. `RESUME_AFTER_RESTART=0` restores
  the old behaviour.
- **Rejected — resume unconditionally, without checking the transcript.**
  One less internal-layout dependency, but it hands `claude` an id it may
  never have heard of, and the failure is silent-then-fatal: `claude` exits
  immediately, the supervisor rebuilds the same failing command every
  `CHECK_INTERVAL_SEC`, and the instance never comes back. Checking first
  costs one `[ -r ]`.
- **Rejected — `claude --continue` (resume the most recent conversation in
  this working directory).** No transcript path dependency at all, but "most
  recent in this cwd" is not "this instance's own": two instances sharing a
  `WORKDIR`, or any conversation the operator ran there by hand, would be
  picked up by the wrong instance. Instance identity has to come from this
  tool's own state.
- **Rejected — `--fork-session` on resume.** Would keep each boot's history
  separate and readable, at the cost of the thing being asked for: one
  continuous conversation across reboots.
- **Accepted cost:** the transcript path (`$CLAUDE_PROJECTS_DIR/<workdir
  with every non-alphanumeric replaced by `-`>/<id>.jsonl`) is an internal
  Claude Code layout, verified against 2.1.202, in the same class as
  `bridgeSessionId`. Mitigated the same way: the path is configurable, and a
  miss degrades to starting a new conversation rather than failing. The
  failure mode to watch for is silent — if the convention changes, every
  reboot quietly starts fresh again.
- **Also accepted:** a `--resume` that `claude` rejects for some other
  reason. `create_session` checks once, a few seconds after starting,
  whether the session died — or never materialised, since `remain-on-exit`
  is only set after `new-session` returns, so a fast exit takes the whole
  session with it — and retries with a new conversation. That second half
  was found by the isolated tests, and it is exactly the loop-forever bug
  the check exists to prevent.
- **Consequence for operators:** observed live and worth knowing — because
  the `claude` session id is unchanged, the instance's `claude.ai/code/...`
  URL also survived the reboot in testing. That is a side effect of how
  Remote Control binds to the session, not a promise; keep fetching the URL
  with `claude-guardian url <name>`.

---

## 2026-08-17 — nudge only a session that is actually parked on a dialog, not one that merely looks unattended

- **Context:** the second v0.3.0 known issue. `UNATTENDED_NUDGE_SEC` sent a
  double Enter to any instance with no tmux client, every 300s. Remote
  Control is not a tmux client, so a session the operator was driving from
  claude.ai qualified — harmless at an idle prompt, but capable of answering
  a confirmation dialog on their behalf.
- **Decision:** gate the nudge on Claude Code's own `status` field in
  `$CLAUDE_SESSIONS_DIR/<pid>.json`. Three values, all observed live on
  2.1.202: `busy` (mid-turn), `idle` (empty prompt), `waiting` (parked on a
  confirmation dialog). Only `waiting` is typed into, and only once
  `statusUpdatedAt` shows the dialog has gone unanswered for
  `UNATTENDED_NUDGE_SEC` — so the countdown starts when the dialog appeared,
  not when the supervisor happened to look. This also makes the nudge
  strictly more useful: it fires on the one state it was written for,
  instead of on a timer that mostly hit sessions with nothing to clear.
- **Rejected — gate on `updatedAt` (last activity) instead.** Tried first,
  and it looked right until it was measured against a real session: the
  maintainer's own instance had been mid-turn for twenty minutes and still
  carried a twenty-minute-old `updatedAt`, because the field tracks status
  *transitions*, not ongoing work. Gating on it would have sent Enter into
  exactly the session the change exists to protect.
- **Rejected — skip the nudge whenever Remote Control is connected.**
  Trivial with what v0.3.0 already reads, but every instance runs
  `--remote-control` by default, so it would disable the nudge everywhere
  rather than narrow it.
- **Accepted cost:** a human on claude.ai who opens a dialog and leaves it
  for longer than `UNATTENDED_NUDGE_SEC` while still meaning to answer it is
  indistinguishable from an abandoned session, and will still have it
  answered for them. Raising the interval is the knob. When no usable
  session file exists, the v0.2.0 wall-clock behaviour remains as the
  fallback.

---

## 2026-08-17 — MAX_SESSIONS defaults to 0 (no limit)

- **Context:** the operator hit `MAX_SESSIONS=3` and read it as a limit of
  the tool — "对话为什么有3个限制，我实测可以开很多啊?" — which is the wrong
  mental model: the limit only ever applied to guardian-supervised
  instances, never to Claude Code itself.
- **Decision:** default `MAX_SESSIONS="0"`, meaning no limit, with the
  ceiling still available to anyone who wants one. `0` had to be given that
  meaning explicitly; before this it would have refused every instance,
  since the check was a bare `count >= MAX_SESSIONS`.
- **Rejected — remove the setting entirely.** The cost concern behind it is
  real (each instance is a separate `claude` process and token budget); what
  was wrong was imposing a number on everyone by default.
- **Consequence:** existing installs keep whatever is already in their
  `config.env` — `install` deliberately never overwrites it — so this only
  changes what a fresh install gets.

---

## 2026-08-17 — read Remote Control state from claude's own session file instead of scraping the terminal

- **Context:** the operator reported two symptoms in production: sessions
  showing "disconnected" on claude.ai after being left alone for a while,
  and an extra conversation appearing after every boot. Investigating both
  turned up four distinct problems, three of them in this tool.
- **What was actually wrong:**
  1. **The v0.2.0 keepalive did nothing.** It re-ran `/remote-control`
     every `REMOTE_CONTROL_REFRESH_SEC` on the belief that this refreshes
     the connection. Verified against the real binary: when Remote Control
     is *already* on, `/remote-control` only opens an informational dialog
     ("Disconnect this session" / "Show QR code" / "Continue"). It
     re-establishes nothing. So when the connection genuinely dropped,
     nothing repaired it — which is exactly the reported symptom.
  2. **The URL scrape could capture a stranger's URL.** It grepped the
     whole visible pane for `https://claude.ai/code/session_...` and took
     the last match. Caught live: instance `claude-code` had another
     instance's URL printed on screen (the operator had been debugging
     there), and the refresh wrote *that* into `claude-code`'s state, so
     `claude-guardian url claude-code` handed back a link to a different
     conversation. Any session URL that happens to be visible — a commit
     trailer, some command's output — could do this.
  3. **"Unattended" was measured wrong for this purpose.** Remote Control
     is not a tmux client, so an instance a human is actively driving from
     claude.ai looks unattended, and the periodic `/remote-control`
     injection landed *in that live conversation* as a user turn.
  4. Not a tool bug: a leftover `test` instance from v0.2.0 verification
     was still enabled, so boot started two instances. Archived.
- **Decision:** stop inferring Remote Control state from the terminal.
  Claude Code writes `$CLAUDE_SESSIONS_DIR/<pid>.json` per running
  session, whose `bridgeSessionId` field holds the Remote Control session
  id while connected and is `null` once disconnected; an instance's
  `claude` is its tmux pane command, so `#{pane_pid}` names that file
  directly. Read it to answer both "still connected?" and "what is the
  URL?". `REMOTE_CONTROL_REFRESH_SEC` changes meaning accordingly: it is
  now how often that check runs, and keys are sent *only* when the check
  says the connection is actually down. On a healthy instance the
  supervisor now types nothing at all.
- **Rejected — keep scraping, but anchor the regex to the
  `/remote-control` output.** This fixes the wrong-URL bug (and is in fact
  retained as the fallback for a Claude Code that writes no session file),
  but it cannot fix the real one: it still requires typing into the session
  to learn anything, so it cannot distinguish "connected" from
  "disconnected" without disturbing a conversation that may have a human in
  it.
- **Rejected — detect the connection via the `/rc` indicator in the status
  line.** That indicator comes from the operator's `claude-hud` statusline
  plugin, not from Claude Code, so it would work on exactly one machine.
- **Rejected — reconnect unconditionally on every check.** Simple and
  always-fresh, but every reconnect mints a new `claude.ai/code/...` URL
  (verified live: the id changed across one disconnect/connect cycle on an
  otherwise untouched session), so this would churn the URL every 20
  minutes for no benefit.
  Reconnect only when actually disconnected.
- **Accepted cost:** `bridgeSessionId` is an internal Claude Code detail,
  not a promised interface, verified against 2.1.202. Mitigated three ways:
  the path is configurable (`CLAUDE_SESSIONS_DIR`), the read is
  cross-checked against the instance's own `pid` and tracked
  `claude_session_id` so a reused PID can't return a stranger's session,
  and an unreadable file degrades to the v0.2.0 scrape rather than failing.
- **Consequence for operators:** a reconnect changes the instance's URL, so
  the URL is something to fetch on demand (`claude-guardian url <name>`),
  not to bookmark. Documented in README and DESIGN.

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
