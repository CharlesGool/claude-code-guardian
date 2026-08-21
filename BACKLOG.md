# Backlog

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

- [ ] 2026-08-21 start an instance and leave it idle overnight to record whether v0.6.2 also goes unreachable — begins with `claude-guardian new`, since every instance was archived on 2026-08-21 and nothing is running; the result is what decides whether the withdrawn Remote Control work is recovered
- [ ] 2026-08-21 decide what to do with the withdrawn v0.7.0/v0.8.0 work once the overnight result is in — the deleted refs are in a bundle kept outside this repo (see ../.local-notes.md); the 2026-08-21 DECISIONS.md entry lists what was in it
- [ ] 2026-08-21 give v0.6.2 a way to repair a session that is unreachable while the host looks healthy — there is none today, so the operator must attach and type `/remote-control` by hand; start from `capture_remote_control_url` in bin/claude-guardian.sh, and read the 2026-08-21 DECISIONS.md entry first because the withdrawn versions already tried two answers to this
- [ ] 2026-08-21 migrate an existing /etc config so it picks up settings added after it was first written — `install` never rewrites it, so a host can silently fall back to built-in defaults and a shipped feature is present but inert; start from the config template heredoc in bin/claude-guardian.sh
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
