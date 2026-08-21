---
project: claude-code-guardian
version: v0.6.2
status: active
branch: main
updated: 2026-08-21
---

# Status

**Notion:** private mirror (not published)
**Repo:** https://github.com/CharlesGool/claude-code-guardian (public, GPL-3.0)
**Snapshots:** maintained privately (not published)
**Release:** https://github.com/CharlesGool/claude-code-guardian/releases/tag/v0.6.2
**In progress:** v0.7.0 and v0.8.0 were withdrawn on 2026-08-21 — tags, the
v0.7.0 Release and both snapshots deleted, `main` force-reset here — after
supervised instances kept going unreachable from claude.ai. v0.6.2 is the
baseline all later work starts from. Read DECISIONS.md (2026-08-21) before
touching Remote Control: it records the evidence that argued against this
call, the deciding experiment that had not been run yet, and what the
withdrawal cost. v0.6.2 released. v0.6.1 tried to fix the reconnect-timer seeding and only patched two of its three occurrences; the third (loop start, so every restart and every boot) shipped broken and was caught by re-running the same live test. v0.6.2 patches it and the isolated suite now has a case that fails against v0.6.1. The underlying v0.6.1 defect: the reconnect backoff timer was seeded as though a reconnect had just happened, so the first drop after a supervisor restart waited out a backoff window that was protecting nothing (25s instead of 5s in the live test). v0.6.0 itself: Two changes, both from running v0.4.0 in production for an afternoon (see DECISIONS.md, 2026-08-17, "watch the connection on every tick, and stop answering dialogs by default"). (1) The Remote Control connection check moved from every 20 minutes to every supervision tick — `REMOTE_CONTROL_CHECK_SEC`, default 5s — because the check is a passive file read that types nothing, while the old cadence meant an instance could be alive but unreachable from claude.ai for up to 20 minutes; that is exactly what the operator hit with two instances at once. Reconnects, which do type `/remote-control`, are rate-limited on their own timer (`REMOTE_CONTROL_RECONNECT_BACKOFF_SEC`, 60s; 1200s in the degenerate case where no session file exists to confirm success). `REMOTE_CONTROL_REFRESH_SEC` is gone, with a startup warning if a config still sets it. (2) `UNATTENDED_NUDGE_SEC` now defaults to `0`: the supervisor no longer answers confirmation dialogs on anyone's behalf unless explicitly turned on. The v0.4.0 `waiting`-only guard was not enough — an operator reading a dialog on claude.ai is indistinguishable from an abandoned session, and it was observed answering real dialogs. Verified: shellcheck-clean; 11 isolated cases against a stub `claude` on a private tmux socket (silent while connected, no state churn, drop noticed within a tick, reconnect sent once then backed off, recovery re-recorded the new URL, a `waiting` dialog left untouched at the default, and the no-session-file slow path).

Previously, in v0.5.0: ships `skills/claude-session/`, the Agent Skill that drives these commands from plain language.

Previously, in v0.4.0: Clears both known issues left by v0.3.0 (see DECISIONS.md, 2026-08-17, the "resume the conversation across a reboot" and "nudge only a session that is actually parked" entries). An instance now comes back from a reboot on the conversation it already had, via `claude --resume` gated on the transcript still existing under `$CLAUDE_PROJECTS_DIR` (`RESUME_AFTER_RESTART=0` opts out), falling back to a new conversation — once, not in a loop — if `claude` rejects the resume. The unattended Enter is now gated on Claude Code's own `status` field: only a session reporting `waiting` (parked on a confirmation dialog) for a full `UNATTENDED_NUDGE_SEC` is typed into, so `busy`/`idle` sessions, including ones being driven from claude.ai, are left alone. `MAX_SESSIONS` now defaults to `0` = no limit. Verified three ways before tagging: shellcheck-clean; 38 isolated cases with a stub `claude` on a private tmux socket (transcript found/missing/wrong-workdir, resume vs fresh vs opted-out, a rejected resume falling back instead of looping, status parsing with PID and sessionId mismatches, and the nudge across `busy`/`idle`/fresh-dialog/stale-dialog/no-session-file); and live on the maintainer's host with the real binary on a throwaway third instance — a simulated reboot brought back the marker turn from before it (and, incidentally, the same claude.ai URL), and a real confirmation dialog left unanswered for 16s was cleared by the supervisor at the 15s mark it was configured with, with the two production instances untouched throughout.
**Next:** 2026-08-21 leave an instance idle overnight and record whether v0.6.2 also goes unreachable — that result decides whether the withdrawn Remote Control work is recovered
**Known issues:**
- A session can go unreachable from claude.ai while everything on this host
  looks healthy, and v0.6.2 has no command that repairs it: attach and type
  `/remote-control` by hand. Observed on supervised instances and on a plain
  `claude` this tool was not supervising, so the trigger is not known to be
  local. This is the open question above, not a settled defect.
- An instance parked on a confirmation dialog with nobody around now stays parked until a human answers it. That is the v0.6.0 tradeoff, not a defect, but it does mean an abandoned instance can sit idle indefinitely; set `UNATTENDED_NUDGE_SEC` above `0` to opt back into self-unsticking, and re-read DESIGN.md → Known limitations before doing so.
- Resume-after-reboot depends on Claude Code's transcript directory naming (working directory with every non-alphanumeric replaced by `-`), verified against 2.1.202. If that convention changes, every reboot silently starts a fresh conversation again — nothing errors, so the symptom is the only signal.
**Blocked on:** nothing.

<!--
Keep this file short. Current state only — history belongs in CHANGELOG.md and git log.
For public repositories, never write a Notion URL, a local/NAS absolute path, an
internal hostname, or any other maintenance-only identifier here. Those live in
the maintainer's local .local-notes.md file outside this repo, so they are
never committed and never end up in a snapshot.

Update on events, not "before the session ends" (a session never announces its end):
  - a tag was cut
  - a decision was made that affects later work
  - blocked on something
  - the user says "that's enough for now" or similar
  - the step written in Next was completed
-->
