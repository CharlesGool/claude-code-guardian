# Status — updated 2026-08-17

**Version:** v0.4.0 · **Branch:** main
**Notion:** private mirror (not published)
**Repo:** https://github.com/CharlesGool/claude-code-guardian (public, GPL-3.0)
**Snapshots:** maintained privately (not published)
**In progress:** v0.4.0 released. Clears both known issues left by v0.3.0 (see DECISIONS.md, 2026-08-17, the "resume the conversation across a reboot" and "nudge only a session that is actually parked" entries). An instance now comes back from a reboot on the conversation it already had, via `claude --resume` gated on the transcript still existing under `$CLAUDE_PROJECTS_DIR` (`RESUME_AFTER_RESTART=0` opts out), falling back to a new conversation — once, not in a loop — if `claude` rejects the resume. The unattended Enter is now gated on Claude Code's own `status` field: only a session reporting `waiting` (parked on a confirmation dialog) for a full `UNATTENDED_NUDGE_SEC` is typed into, so `busy`/`idle` sessions, including ones being driven from claude.ai, are left alone. `MAX_SESSIONS` now defaults to `0` = no limit. Verified three ways before tagging: shellcheck-clean; 38 isolated cases with a stub `claude` on a private tmux socket (transcript found/missing/wrong-workdir, resume vs fresh vs opted-out, a rejected resume falling back instead of looping, status parsing with PID and sessionId mismatches, and the nudge across `busy`/`idle`/fresh-dialog/stale-dialog/no-session-file); and live on the maintainer's host with the real binary on a throwaway third instance — a simulated reboot brought back the marker turn from before it (and, incidentally, the same claude.ai URL), and a real confirmation dialog left unanswered for 16s was cleared by the supervisor at the 15s mark it was configured with, with the two production instances untouched throughout.
**Next:** nothing scheduled.
**Known issues:**
- A human on claude.ai who opens a confirmation dialog and then leaves it unanswered for longer than `UNATTENDED_NUDGE_SEC` still gets it answered on their behalf — from the outside that is indistinguishable from an abandoned session. Raising the interval is the only knob. See DESIGN.md → Known limitations.
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
