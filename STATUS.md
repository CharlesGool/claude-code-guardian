# Status — updated 2026-08-16

**Version:** v0.1.0 · **Branch:** main
**Notion:** private mirror (not published)
**Repo:** https://github.com/CharlesGool/claude-code-guardian (public, GPL-3.0)
**Snapshots:** maintained privately (not published)
**In progress:** v0.1.0 released — tagged, pushed, snapshot exported, Notion synced. Core behavior: `claude --permission-mode auto --remote-control` supervised via systemd+tmux, with an unattended-only keepalive (double-Enter nudge + `/remote-control` refresh), a `purge` command for full teardown, and `install` hard-refusing if `claude auth status` reports not logged in. Independently verified working on a second host by the user. Full bug history is in DECISIONS.md — several real issues were only found via actual deployment, not code review alone.
**Next:** nothing queued. Future work would be a v0.2+ feature or bugfix as one comes up.
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
