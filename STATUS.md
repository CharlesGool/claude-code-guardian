# Status — updated 2026-08-16

**Version:** unreleased · **Branch:** main
**Notion:** not yet synced
**Repo:** https://github.com/CharlesGool/claude-code-guardian (public, GPL-3.0)
**Snapshots:** none yet
**In progress:** implementation complete and installed live on this host (`systemctl is-active claude-guardian` → active). Core behavior: `claude --permission-mode auto --remote-control` supervised via systemd+tmux, with an unattended-only keepalive (double-Enter nudge + `/remote-control` refresh), a `purge` command for full teardown, and `install` now hard-refusing if `claude auth status` reports not logged in (`run` stays non-blocking on login so an already-working service that later loses auth keeps retrying). Full bug history is in DECISIONS.md — several real issues were only found via actual deployment (this host and a second host), not code review alone: systemd unit `KillMode`/`StartLimitIntervalSec` placement, `CLAUDE_BIN` not resolving under systemd's PATH, unattended timers firing prematurely, a stale line-range bug in `usage()`.
**Next:** cut v0.1.0 — bump CHANGELOG, tag, push, export snapshot, sync Notion. (README.zh.md/DESIGN.zh.md are kept fully translated on every commit so far, ahead of the usual tag-time-only cadence, per explicit user request — full retranslation will still happen at v0.1.0 to catch anything missed.)
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
