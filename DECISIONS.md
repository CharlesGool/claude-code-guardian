# Decisions

Newest first. Append only — never delete or rewrite an entry. To reverse a past
decision, add a new entry that says so explicitly.

**Read this file before proposing any technical approach.** Without it, an
already-rejected option gets recommended again two weeks later.

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
