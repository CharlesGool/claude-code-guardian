# Status — updated 2026-08-17

**Version:** v0.3.0 (unreleased) · **Branch:** main
**Notion:** private mirror (not published)
**Repo:** https://github.com/CharlesGool/claude-code-guardian (public, GPL-3.0)
**Snapshots:** maintained privately (not published)
**In progress:** v0.3.0 in the working tree, not yet committed or tagged. Fixes three production bugs the operator hit after v0.2.0 (see DECISIONS.md, 2026-08-17 "read Remote Control state from claude's own session file"): the unattended keepalive never actually repaired a dropped Remote Control connection, the URL scrape could record another instance's URL, and the supervisor injected `/remote-control` into sessions a human was driving from claude.ai. Remote Control state now comes from `$CLAUDE_SESSIONS_DIR/<pid>.json` (`bridgeSessionId`), with the old terminal scrape kept as an anchored fallback. Verified: shellcheck-clean; five isolated guard cases (PID mismatch, sessionId mismatch, `bridgeSessionId: null`, happy path, missing file) plus an anchored-fallback case that reproduces the wrong-URL bug and shows it fixed; and live on this host — all instances reported their own correct URL, a real disconnect was detected and auto-reconnected with the new URL recorded, and a healthy instance was confirmed to receive zero keystrokes. Deployed to `/usr/local/bin/claude-guardian` and both live supervisors restarted (tmux pane PIDs unchanged).
**Next:** commit the v0.3.0 work to `main`, then run the release checklist (retranslate README.zh/DESIGN.zh, tag v0.3.0, snapshot, Notion).
**Known issues:**
- `UNATTENDED_NUDGE_SEC` still sends a double Enter every 300s to instances with no tmux client, including ones a human is actively driving from claude.ai — Remote Control is not a tmux client, so those look unattended. Harmless at an idle prompt, but it can auto-accept a confirmation dialog on the operator's behalf. Not addressed in v0.3.0; the same `bridgeSessionId` read now available could gate it.
- Every reboot starts each instance on a brand-new conversation (`create_session` always generates a fresh `--session-id`); the pre-reboot conversation is left behind and is only recoverable by hand via `claude --resume`. Reported by the operator as "a new conversation after boot".
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
