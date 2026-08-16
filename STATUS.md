# Status — updated 2026-08-16

**Version:** v0.1.0 (releasing now) · **Branch:** main
**Notion:** not yet synced
**Repo:** https://github.com/CharlesGool/claude-code-guardian (public, GPL-3.0)
**Snapshots:** none yet
**In progress:** cutting the v0.1.0 tag. Implementation is complete and installed live on this host (`systemctl is-active claude-guardian` → active). Core behavior: `claude --permission-mode auto --remote-control` supervised via systemd+tmux, with an unattended-only keepalive (double-Enter nudge + `/remote-control` refresh), a `purge` command for full teardown, and `install` hard-refusing if `claude auth status` reports not logged in. Independently verified working on a second host by the user. Full bug history is in DECISIONS.md — several real issues were only found via actual deployment, not code review alone.
**Next:** after the tag: export snapshot, sync Notion, record the URL/snapshot path back here.
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
