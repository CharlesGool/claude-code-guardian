# Status — updated 2026-08-17

**Version:** v0.1.0 released · v0.2.0 in progress · **Branch:** feat/multi-session
**Notion:** private mirror (not published)
**Repo:** https://github.com/CharlesGool/claude-code-guardian (public, GPL-3.0)
**Snapshots:** maintained privately (not published)
**In progress:** v0.2.0 — multi-instance support (`new`/`list`/`url`/`activate`/`deactivate`/`archive`/`resume`/`rm-archive`), reversing the 2026-08-16 single-session decision (see DECISIONS.md, 2026-08-17). `bin/claude-guardian.sh` rewrite is done, shellcheck-clean, verified in an isolated test harness, and now also verified live: `install` was run against this host's own production instance with explicit user go-ahead — the migrated tmux pane's PID and liveness were confirmed unchanged before/after, and supervision was restarted successfully. `claude-guardian@claude-code.service` is active+enabled; `/etc/claude-guardian/config.env` topped up with `MAX_SESSIONS`/`uuid-runtime` to match. One real limitation surfaced by this migration and documented in DESIGN.md: a migrated pre-existing session has no tracked `claude_session_id` until it's genuinely recreated (respawn only replays the original pre-v0.2.0 command). README.md/DESIGN.md/CHANGELOG.md/DECISIONS.md/.env.example/`claude-session` skill/memory pointer are all in place. Not yet done: Chinese doc retranslation (deferred to tag time per project-management skill) and the release checklist itself.
**Next:** retranslate README.zh.md/DESIGN.zh.md against the final English text, then release v0.2.0 per the project-management checklist (sensitive/license review, tag, snapshot, Notion sync).
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
