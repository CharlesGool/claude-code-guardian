# Status — updated 2026-08-16

**Version:** unreleased · **Branch:** main
**Notion:** not yet synced
**Repo:** https://github.com/CharlesGool/claude-code-watchdog (private)
**Snapshots:** none yet
**In progress:** implementation complete and installed live on this host (`systemctl is-active claude-guardian` → active). Real end-to-end verification against the actual `claude` binary found and fixed two bugs: (1) `StartLimitIntervalSec` was in the wrong unit section (`[Service]` instead of `[Unit]`, systemd silently ignored it); (2) default `KillMode=control-group` killed the whole tmux session on `systemctl stop`/`restart`, contradicting the intended "stop only pauses supervision" behavior — fixed with explicit `KillMode=process`. Both fixes verified live: `stop`+`start` now leaves the same `claude` PID running; Ctrl+C-based respawn confirmed (Claude Code needs two Ctrl+C to actually exit, not one — docs updated to match).
**Next:** cut v0.1.0 — bump CHANGELOG, retranslate DESIGN.zh.md/README.zh.md, tag, push, export snapshot, sync Notion.
**Known issues:** none currently open. Reboot-survival (setup step 8) not yet independently verified on this host (would require an actual reboot); `enabled` state via `systemctl is-enabled` was confirmed instead.
**Blocked on:** nothing.

<!--
Keep this file short. Current state only — history belongs in CHANGELOG.md and git log.
For public repositories, never write a Notion URL, a local/NAS absolute path, an
internal hostname, or any other maintenance-only identifier here. Those live in
/root/MyGithub_Project/<project>/.local-notes.md — outside repo/, so they are
never committed and never end up in a snapshot.

Update on events, not "before the session ends" (a session never announces its end):
  - a tag was cut
  - a decision was made that affects later work
  - blocked on something
  - the user says "that's enough for now" or similar
  - the step written in Next was completed
-->
