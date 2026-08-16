# Status — updated 2026-08-16

**Version:** unreleased · **Branch:** main
**Notion:** not yet synced
**Repo:** not yet created (private, pending `gh repo create`)
**Snapshots:** none yet
**In progress:** initial implementation complete (`bin/claude-guardian.sh`: preflight, tmux/systemd two-layer supervision, install/uninstall/attach/logs/check CLI); smoke-tested locally against a fake `claude` binary (session create, auto-respawn on exit, clean SIGTERM shutdown all verified).
**Next:** commit the initial skeleton, create the private GitHub remote, push. Then a real end-to-end test on this host (`bash bin/claude-guardian.sh install && claude-guardian start && claude-guardian attach`) before cutting v0.1.0.
**Known issues:** not yet tested with the real `claude` binary under a live systemd unit (only the underlying tmux/loop logic was smoke-tested with a stand-in script) — do this before tagging v0.1.0.
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
