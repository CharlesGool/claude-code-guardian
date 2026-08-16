# Status — updated 2026-08-16

**Version:** unreleased · **Branch:** main
**Notion:** not yet synced
**Repo:** https://github.com/CharlesGool/claude-code-guardian (private)
**Snapshots:** none yet
**In progress:** implementation complete and installed live on this host (`systemctl is-active claude-guardian` → active), now launching `claude --permission-mode auto --remote-control` by default with an unattended-only keepalive (auto-Enter + `/remote-control` refresh) so the session stays remotely controllable through long idle stretches. Real end-to-end verification against the actual `claude` binary found and fixed three bugs: (1) `StartLimitIntervalSec` in the wrong unit section; (2) default `KillMode=control-group` killing the whole tmux session on `stop`/`restart`, fixed with `KillMode=process`; (3) the new unattended timers starting from epoch 0 instead of loop-start time, causing an immediate spurious nudge/refresh on every restart of an already-unattended session. The auto-Enter mechanism was flagged live by Claude Code's own auto-mode classifier as defeating the human-in-the-loop fallback; user was shown the tradeoff explicitly and confirmed proceeding (see DECISIONS.md 2026-08-16).
**Next:** cut v0.1.0 — bump CHANGELOG, tag, push, export snapshot, sync Notion. (README.zh.md/DESIGN.zh.md are already fully translated as of this commit, ahead of the usual tag-time-only cadence, per explicit user request — they'll still get the normal full retranslation at v0.1.0 to pick up anything that changes before then.)
**Known issues:** none currently open. Reboot-survival not yet independently verified on this host (would require an actual reboot; `systemctl is-enabled` was confirmed instead). Whether an idle-but-network-healthy Remote Control session can go stale on its own (vs. only after real connectivity loss) is undocumented upstream — `REMOTE_CONTROL_REFRESH_SEC` refreshes proactively regardless, so this is a residual unknown rather than a blocking gap.
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
