# Status — updated 2026-08-17

**Version:** v0.2.0 · **Branch:** main
**Notion:** private mirror (not published)
**Repo:** https://github.com/CharlesGool/claude-code-guardian (public, GPL-3.0)
**Snapshots:** maintained privately (not published)
**In progress:** v0.2.0 released — multi-instance support (`new`/`list`/`url`/`activate`/`deactivate`/`archive`/`archives`/`resume`/`rm-archive`), reversing the 2026-08-16 single-session decision (see DECISIONS.md, 2026-08-17). Verified three ways before tagging: shellcheck-clean; an isolated test harness (fake `claude` binary) covering session create/respawn, URL regex extraction, and the archive→resume→rm-archive round trip; and live on this host with the real `claude` binary — `install` migrated the production `claude-code` instance in place (tmux pane PID/liveness unchanged throughout), then a real second instance (`new`→`list`→`url`→`archive`→`resume`→`archive`→`rm-archive`) was created, captured a working remote-control URL, resumed its conversation via `claude --resume`, and was fully cleaned up. One real limitation surfaced by the migration and documented in DESIGN.md: a migrated pre-existing session has no tracked `claude_session_id` until genuinely recreated. `feat/multi-session` merged to `main`.
**Next:** tag v0.2.0, export a snapshot, sync to Notion.
**Known issues:** none currently open.
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
