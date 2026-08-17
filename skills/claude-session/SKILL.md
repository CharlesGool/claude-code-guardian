---
name: claude-session
description: 'Manage remotely-attachable, root-managed Claude Code sessions on this host via claude-guardian. Use when the user asks to create/open a new persistent remote-controllable Claude conversation ("开一个常驻对话", "新建一个远程对话"), list active sessions ("有哪些常驻对话", "列一下我的对话"), get a session''s claude.ai remote-control URL without attaching, pause/deactivate a session without killing it ("取消激活", "暂停这个对话"), permanently archive a session ("归档这个对话", "存档并结束"), resume an archived conversation ("恢复归档的对话", "继续之前归档的那个"), or fully tear down claude-guardian. Do NOT use for ordinary git/deploy/systemd tasks unrelated to claude-guardian-managed sessions.'
allowed-tools: Bash
---

# claude-session

Operates `claude-guardian` (this repository's `bin/claude-guardian.sh`,
installed system-wide as `/usr/local/bin/claude-guardian`), which supervises
one or more named, concurrently-running Claude Code (`claude`) instances via
systemd + tmux. Each instance is independently remotely-controllable from
claude.ai on the web or a phone — the whole point of this tool is that the
user should never need to SSH in or open a terminal to create, find, pause,
or archive one of these sessions.

**Prerequisite check before using any command below:** confirm
`claude-guardian` is actually installed (`command -v claude-guardian` or
`systemctl list-unit-files 'claude-guardian@*'`). If it isn't yet (e.g. this
host is still on an unreleased branch of the tool), say so instead of
guessing at command output — do not fabricate `list`/`url` results.

## Command reference

| User intent | Command |
|---|---|
| "开一个常驻对话" / new persistent session | `claude-guardian new <name> [--workdir DIR] [--args "..."] [--claude-bin PATH]` |
| "有哪些常驻对话" / list sessions | `claude-guardian list` |
| "给我这个对话的链接" / get remote-control URL without attaching | `claude-guardian url <name>` |
| "取消激活" / pause supervision, keep it running | `claude-guardian deactivate <name>` |
| "重新激活" / resume supervision | `claude-guardian activate <name>` |
| "归档这个对话" / archive (destructive: kills the process) | `claude-guardian archive <name>` |
| "有哪些归档" / list archives | `claude-guardian archives` |
| "恢复归档的对话" / continue an archived conversation | `claude-guardian resume <archive-id> [new-name]` |
| "删除这个归档" / permanently delete an archive | `claude-guardian rm-archive <id>` |
| attach over SSH (rarely what the user wants — they want the URL instead) | `claude-guardian attach <name>` |
| follow logs | `claude-guardian logs <name>` |
| full teardown of the tool itself | `claude-guardian purge` — see hard rules below |

`<name>` defaults to `claude-code` (the default instance) if omitted on
commands that accept it optionally (`url`, `activate`, `deactivate`,
`attach`, `logs`, `start`, `stop`, `restart`, `status`).

## Hard rules

- **Never run `archive` or `purge` without the user explicitly asking for
  that specific destructive action in this turn.** Both kill a live
  `claude` process. A vague "clean this up" or "我不需要了" from the user
  about something unrelated does not authorize archiving a session.
- **Before `archive`, run `list` (or `url <name>`) first and show the user
  which instance/URL you're about to archive**, so they can confirm it's
  the right one — instance names alone are easy to confuse. Then call
  `archive <name> --yes` only after they've confirmed in this turn (or
  pass no `--yes` and let the tool's own interactive confirmation handle
  it, if running in a context where that prompt will actually reach the
  user).
- **`deactivate` is not `archive`.** If the user says "取消激活" or "暂停"
  (pause) without saying "归档"/"结束"/"删除" (end/delete), use
  `deactivate` — it never kills the live process. Only escalate to
  `archive` if they confirm they want the conversation actually ended.
- **Never run `purge` autonomously, ever**, regardless of phrasing — it
  tears down every instance on the host. Only run it if the user
  explicitly names the `purge` command or unambiguously asks to
  completely uninstall/remove claude-guardian itself (not just one
  session), and confirm the instance count/impact with them first via
  `list`.
- **Be extra careful with the instance you yourself are currently running
  in.** If this conversation is itself a claude-guardian-managed session
  (commonly the default `claude-code` instance), deactivating, archiving,
  or purging it will disrupt or end the very conversation the user is
  having with you. Point this out explicitly before acting on that
  specific instance, even if the user's request technically covers it.
- **`new` costs real money per additional instance** (a separate `claude`
  process, separate token spend). Since v0.4.0 nothing stops you by
  default: `MAX_SESSIONS` defaults to `0` = no limit, so `new` keeps
  creating instances until somebody notices the token spend. Say what
  another instance costs before creating one. If a ceiling *is* configured
  (`MAX_SESSIONS` > 0 in `/etc/claude-guardian/config.env`) and the host is
  already near it, mention that rather than silently hitting the refusal.
- **Report `url <name>` output verbatim** — the `https://claude.ai/code/...`
  link is what the user actually wants when they ask "怎么远程连上那个对
  话" or similar; don't just say "it's running."
- **If `resume` reports no recorded `claude_session_id`**, don't guess —
  tell the user only the raw scrollback in the archive directory is
  available, per the tool's own refusal message.

## Notes

- Full command semantics, config variables, and the reasoning behind the
  archive-kills-the-process design are in this repository's `DESIGN.md` and
  `DECISIONS.md` (2026-08-17 entry) — read those if a command's exact
  behavior matters and isn't covered above.
- This skill only means anything on a host where claude-guardian is
  installed; it drives that command and nothing else.
