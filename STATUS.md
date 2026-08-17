# Status — updated 2026-08-17

**Version:** v0.1.0 released · v0.2.0 in progress · **Branch:** feat/multi-session
**Notion:** private mirror (not published)
**Repo:** https://github.com/CharlesGool/claude-code-guardian (public, GPL-3.0)
**Snapshots:** maintained privately (not published)
**In progress:** v0.2.0 — multi-instance support (`new`/`list`/`url`/`activate`/`deactivate`/`archive`/`resume`/`rm-archive`), reversing the 2026-08-16 single-session decision (see DECISIONS.md, 2026-08-17). `bin/claude-guardian.sh` rewrite is done, shellcheck-clean, and verified in an isolated test harness (fake `claude` binary, separate tmux socket/state dirs) covering session create/respawn, remote-control URL regex extraction, and the full archive→resume→rm-archive round trip. README.md/DESIGN.md/CHANGELOG.md/DECISIONS.md/.env.example updated for the new architecture. Not yet done: the `claude-session` skill + memory pointer for hands-off lifecycle management from another Claude Code session, the Chinese doc retranslation (deferred to tag time per project-management skill), and running `install`'s legacy-unit migration against this host's own live production instance — deliberately not run yet since this host's default `claude-code` instance is the very session driving this work; needs an explicit go-ahead before touching it live.
**Next:** build the `claude-session` skill, retranslate README.zh.md/DESIGN.zh.md against the final English text, get a go-ahead to run `install` against production, then release v0.2.0 per the project-management checklist.
**Known issues:** none currently open.
**Blocked on:** explicit user go-ahead before running `claude-guardian install` (legacy-unit migration) against this host's live production `claude-code` instance.

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
