---
project: claude-code-guardian
version: v0.10.0
status: active
branch: main
updated: 2026-09-12
---

# Status

**English** | [简体中文](translated_zh_cn/STATUS_zh_cn.md)

**Notion:** private mirror (not published)
**Repo:** https://github.com/CharlesGool/claude-code-guardian (public, GPL-3.0)
**Snapshots:** maintained privately (not published)
**Release:** https://github.com/CharlesGool/claude-code-guardian/releases/tag/v0.10.0
**In progress:** nothing — v0.10.0 is released.

In v0.10.0: the supervised session no longer runs as root. `RUN_AS_USER`
names the account that owns the tmux server, every `claude` process and
everything `claude` writes; root still installs and supervises. That split
is what makes `--dangerously-skip-permissions` usable at all — `claude`
refuses the flag as root — and it is now the shipped default, with a root
install getting `--permission-mode auto --remote-control` instead and the
impossible pairing refused by `install`/`new`/`run` rather than left to
respawn forever. An existing install is unaffected: `RUN_AS_USER` falls back
to `root` and `install` still never rewrites a config.

Two defects were found while doing it and fixed in the same release. Every
tmux target was a bare session name, and tmux falls back to prefix matching,
so with `claude-code` and `claude-code-work` both present, commands aimed
at the first landed on the second — `send-keys` included, i.e.
`/remote-control` and bare Enters into another instance's conversation. All
targets are now exact (`=name`, `=name:`), verified against tmux 3.2a. And
`list` printed `inactive` twice for a stopped instance, wrapping the row.

Verified: shellcheck-clean; `tests/run-as-user.sh`, a new 32-case isolated
suite that installs nothing (it is also the first part of the long-standing
"commit the test suite" backlog item to actually land); and live on the
maintainer's host, migrated end to end from root to an unprivileged account
— two instances archived, their transcripts copied across, both resumed on
their original conversations with their original Remote Control URLs, a
supervisor restart leaving the tmux server and `claude` PID untouched
(`RuntimeDirectoryPreserve`), `attach` dropping from root to the session
account, and `run` refusing to start as the wrong one. Not verified: a real
reboot on the migrated host, and a fresh install on a host that has no
unprivileged account to adopt.

Two things the migration taught, both now in DECISIONS.md and BACKLOG.md: a
tmux socket outlives its server, and a root-owned leftover made every
session creation fail with `Permission denied` while the log said only that
`claude` had exited (`install` now clears a stale one and refuses a live
one); and `claude` asks an unanswerable question the first time an account
opens a directory — "do you trust this folder?", with **No, exit**
preselected — which the supervisor now answers, because the blind Enter it
sends for onboarding screens was selecting exactly that.

Previously, in v0.9.1 and earlier: the "unreachable while the host looks
healthy" failure was reproduced and understood — the supervisor's repair is
a no-op (sending `/remote-control` to a session that believes it is
connected only opens an informational dialog) and it then accepts an
unchanged `bridgeSessionId` as proof of success, so one failed repair
silences every future one. The working sequence is that dialog's `Disconnect
this session` followed by `/remote-control`, which mints a new id; success
must be tested as a *change*, never as "non-null". The withdrawn v0.7.0
already implemented both halves, and the operator confirmed the repaired URL
drives its session from a remote client, so recovering that work is
unblocked — it is the top backlog item. Full evidence: DECISIONS.md
(2026-08-23). v0.9.1 fixed `attach` dying with `exec: tmux_cmd: not found`;
v0.9.0 made "at least one session is always available" an enforced property
(`archive`/`deactivate` warn before the boot-enabled count reaches zero, and
`claude-guardian-floor.service` recreates the default instance at boot).
v0.7.0 and v0.8.0 were withdrawn on 2026-08-21; v0.6.2 is the baseline all
later work starts from.

**Next:** 2026-08-23 make the supervisor's Remote Control repair actually repair — today it sends `/remote-control`, which on a session that believes it is connected only opens an informational dialog and rebuilds nothing, then accepts an unchanged `bridgeSessionId` as proof of success and never retries. The working sequence is that dialog's `Disconnect this session` then `/remote-control`, and a real reconnect *changes* the id, so success must be tested as "changed", never as "non-null". Start from `capture_remote_control_url` and the check in bin/claude-guardian.sh, and read the 2026-08-23 DECISIONS.md entry — the withdrawn v0.7.0 already implemented both halves of this, so recovering it from the bundle is likely cheaper than rewriting
**Known issues:**
- Changing `RUN_AS_USER` on a live host is a migration, not a setting. The
  conversations stay in the old account's `~/.claude`, which the new one
  cannot read, and `resume` has no `--workdir`, so an archive made under the
  old account needs its `meta.env` edited by hand before it can be resumed
  under the new one. README → Install has the sequence.
- The first-run trust prompt is answered *for* you (**No, exit** is
  preselected, so leaving it alone would respawn the instance into that
  screen forever). The detection matches that screen's current wording — if
  Claude Code rewords it, the loop comes back and the log will only say
  `claude exited`.
- `--dangerously-skip-permissions` being the default means the session has
  the session account's full privileges, including root if that account has
  passwordless `sudo`. The root-safe alternative is one config line, and
  `check` reports which pairing a host is on.
- The boot floor is a `oneshot`: it runs at boot, not continuously. Archiving
  the last instance mid-session still leaves the host with nothing running
  until the next reboot or a manual `claude-guardian ensure-floor`. That is
  the deliberate tradeoff (a continuous floor would make `archive`
  unusable), and the new warning covers the interactive case.
- With `ENSURE_DEFAULT_INSTANCE=1`, deactivating the *last* instance is
  undone at the next boot, contradicting `deactivate`'s own "won't restart
  at boot". Deliberate — the guarantee wins — and `deactivate` says so
  before acting; a host meant to boot idle needs the setting at `0`.
- A session can go unreachable from claude.ai while everything on this host
  looks healthy, and there is still no command that repairs it. As of
  2026-08-23 this is a **settled defect, not an open question** — see the
  six numbered findings above. Two things matter for anyone hitting it now:
  attaching and typing `/remote-control` **does not fix it** (it only opens
  an informational dialog on a session that believes it is connected); the
  repair that works is that dialog's `Disconnect this session` followed by
  `/remote-control`, which mints a new URL. The old URL is dead afterwards.
  The supervisor performs the useless half of that automatically and then
  records success, which is why the state persists silently.
- An instance parked on a confirmation dialog with nobody around now stays parked until a human answers it. That is the v0.6.0 tradeoff, not a defect, but it does mean an abandoned instance can sit idle indefinitely; set `UNATTENDED_NUDGE_SEC` above `0` to opt back into self-unsticking, and re-read DESIGN.md → Known limitations before doing so.
- Resume-after-reboot depends on Claude Code's transcript directory naming (working directory with every non-alphanumeric replaced by `-`), verified against 2.1.202. If that convention changes, every reboot silently starts a fresh conversation again — nothing errors, so the symptom is the only signal.
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
