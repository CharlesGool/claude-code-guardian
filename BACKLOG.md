# Backlog

**English** | [简体中文](translated_zh_cn/BACKLOG_zh_cn.md)

The requirement list. Everything that was asked for, most important first,
ticked off as it gets done. This is the file that answers "what was I going to
do next?" after a two-week gap, and the place requirements go when a session
ends with work still on the table.

**`STATUS.md`'s `Next:` field is the topmost unticked item, copied verbatim.**
When that step is done, tick it here and promote the next unticked item up
there. The two must never disagree: `Next` is the single line the cross-project
table shows, this file is what actually gets read when resuming.

Each item carries the date it was added, so a year-old open entry is visibly
stale rather than quietly permanent:

```
- [ ] YYYY-MM-DD <what to do> — <where it starts: file, command, or the open question>
- [x] YYYY-MM-DD <a finished one>
```

Write items so they can be started cold. "improve error handling" is a note,
not a backlog item; "wrap the mount call in retry — src/mount.py, the bare
except at the bottom" is one.

---

## Items

- [ ] 2026-08-23 make the supervisor's Remote Control repair actually repair — today it sends `/remote-control`, which on a session that believes it is connected only opens an informational dialog and rebuilds nothing, then accepts an unchanged `bridgeSessionId` as proof of success and never retries. The working sequence is that dialog's `Disconnect this session` then `/remote-control`, and a real reconnect *changes* the id, so success must be tested as "changed", never as "non-null". Start from `capture_remote_control_url` and the check in bin/claude-guardian.sh, and read the 2026-08-23 DECISIONS.md entry — the withdrawn v0.7.0 already implemented both halves of this, so recovering it from the bundle is likely cheaper than rewriting
- [ ] 2026-08-23 decide whether every instance sharing one tmux server is acceptable — the server is started by whichever unit comes up first, so all later instances run inside *that* unit's cgroup (confirmed: two instances both under `claude-guardian@claude-code.service`). Stopping or restarting that one unit takes every other instance down with it, and per-instance resource accounting is meaningless. Start from `write_unit_template` and the `new-session` call in bin/claude-guardian.sh
- [ ] 2026-09-12 give `resume` a `--workdir` flag — an archive carries the workdir it had, so an instance archived under one session account cannot be resumed under another without hand-editing `meta.env` in the archive directory first (done exactly that during the v0.10.0 migration); start from `cmd_resume` in bin/claude-guardian.sh
- [ ] 2026-09-12 make the trust-prompt answer survive a rewording — `answer_trust_prompt` matches the literal string "trust this folder" and the "❯ No, exit" cursor line, so a Claude Code release that rewrites that screen silently restores the respawn loop it was added to stop, with a log that only says `claude exited`; start from `answer_trust_prompt` in bin/claude-guardian.sh, and consider a positive signal (the session reaching its prompt) instead of a negative one
- [x] 2026-09-12 run the supervised session as an unprivileged account instead of root, with `claude --dangerously-skip-permissions` — shipped in v0.10.0 as `RUN_AS_USER`: root installs and supervises, the tmux server and every `claude` process belong to that account, and the flag is the shipped default because claude refuses it as root
- [x] 2026-09-12 stop one instance from reaching another instance's tmux session — every `-t` target was a bare session name and tmux prefix-matches, so `claude-code` resolved to a live `claude-code-work`, `send-keys` included; all targets are now exact (`=name` / `=name:`), shipped in v0.10.0
- [x] 2026-08-23 leave the running `claude-code` instance idle overnight and record whether it also goes unreachable — **answered: yes.** Both instances dropped simultaneously after ~6h idle, the supervisor's repair was inert, and it recorded success from an unchanged id. Full findings in STATUS.md and the 2026-08-23 DECISIONS.md entry; this is what reopens the v0.7.0 question
- [ ] 2026-09-12 add the `zh_tw` translations — v0.10.0 migrated the Chinese docs to `translated_zh_cn/` and brought all six up to date there, but `translated_zh_tw/` has never existed for this project, so `release-preflight.sh` warns on six missing files at every release
- [ ] 2026-09-12 compact DECISIONS.md — 19 entries / 55 KB is past the 20-entry, 30 KB line the preflight warns at, and 16 entries are over ~1000 bytes each; collapse everything older than the last tag to one line per decision, in its own commit, and move the reasoning that is still load-bearing into DESIGN.md
- [ ] 2026-08-21 confirm the boot floor across a real reboot — v0.9.0 verified it by starting `claude-guardian-floor.service` directly, which is the same code path but not the same conditions (boot ordering, `network-online.target`); deactivate every instance, reboot, expect `claude-code` active
- [ ] 2026-08-21 commit the rest of the isolated test suite — `tests/run-as-user.sh` (32 cases, the session-account layer) went in with v0.10.0, which is the `tests/` directory and the README line; still missing are the Remote Control cases that died with the v0.7.0 withdrawal and the 48-case boot-floor suite, both of which still exist only in scratch directories
- [ ] 2026-08-21 make `run` require an instance config file like every other command — `load_instance` silently no-ops when the file is missing, so a stale enabled unit resurrects an archived instance under global defaults instead of its own workdir/args, while `list`/`url`/`activate` all die on the same missing file; start from `load_instance` in bin/claude-guardian.sh
- [ ] 2026-08-21 decide what to do with the withdrawn v0.7.0/v0.8.0 work once the overnight result is in — the deleted refs are in a bundle kept outside this repo (see ../.local-notes.md); the 2026-08-21 DECISIONS.md entry lists what was in it
- [ ] 2026-08-21 give v0.6.2 a way to repair a session that is unreachable while the host looks healthy — there is none today, so the operator must attach and type `/remote-control` by hand; start from `capture_remote_control_url` in bin/claude-guardian.sh, and read the 2026-08-21 DECISIONS.md entry first because the withdrawn versions already tried two answers to this
- [ ] 2026-08-21 migrate an existing /etc config so it picks up settings added after it was first written — `install` never rewrites it, so a host can silently fall back to built-in defaults and a shipped feature is present but inert; start from the config template heredoc in bin/claude-guardian.sh
- [x] 2026-08-23 fix `claude-guardian attach` dying with `exec: tmux_cmd: not found` — `cmd_attach` in bin/claude-guardian.sh `exec`'d the `tmux_cmd` shell function as if it were a binary on PATH; inlined the `tmux -S "$TMUX_SOCKET" ...` invocation, shipped in v0.9.1
- [x] 2026-08-21 make "at least one session is always available" an enforced property instead of an emergent one — shipped in v0.9.0: `archive`/`deactivate` warn and ask before the boot-enabled count reaches zero, and `claude-guardian-floor.service` recreates the default instance at boot when nothing else would (`ENSURE_DEFAULT_INSTANCE`, on by default)
- [x] 2026-08-21 restore BACKLOG.md as part of the v0.6.2 baseline — it was created during the v0.7.0 work and disappeared when main was force-reset; rewritten from the current open items rather than recovered from the deleted refs
- [x] 2026-08-21 withdraw v0.7.0 and v0.8.0 and return the code baseline to v0.6.2 — tags, the v0.7.0 Release and both snapshots deleted, main force-reset; see the 2026-08-21 DECISIONS.md entry

<!--
Tick, do not delete. A ticked item is the evidence that the requirement was
heard and handled -- deleting it makes the list look like it was always short,
and leaves no way to tell "never asked for" from "asked for and done".

Scope, so this file does not become a second copy of everything:

  here            every requirement, open or ticked
  DECISIONS.md    considered and rejected, with the reason -- otherwise the same
                  idea gets re-proposed and re-rejected every few weeks
  CHANGELOG.md    what shipped in each version, written for whoever uses the
                  project; this file is the working list behind it
  STATUS.md       the topmost unticked item, plus current state
  the todo tool   steps inside today's session; those are gone tomorrow, which
                  is exactly why they are not written here

Update on events, not "before the session ends" (a session never announces its
end):
  - the user asks for something that is not being worked on right now -- write
    it down at that moment, not at the end
  - an item is finished -- tick it, and move STATUS.md's Next to the next
    unticked one
  - an item stops being wanted -- move it to DECISIONS.md with the reason;
    dropping it silently is how it comes back as a proposal in two weeks

Keep it to work that is actually intended. A backlog nobody trusts to be real
gets skimmed once and then ignored.

In a public repository the same redaction rule as STATUS.md applies: no Notion
URLs, no local/NAS absolute paths, no internal hostnames. Those live in
../.local-notes.md, outside repo/.
-->
