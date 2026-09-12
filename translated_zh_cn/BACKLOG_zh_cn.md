# Backlog

[English](../BACKLOG.md) | **简体中文**

> 译自 `BACKLOG.md`（v0.10.1）。如有冲突，以英文版为准。

需求列表。所有被提出过的要求，按重要程度从高到低排列，做完就打勾。这是那份在两周空档之后回答"接下来该做什么"的文件，也是一个会话结束时手头还有活没干完时，需求该去的地方。

**`STATUS.md` 的 `Next:` 字段是最上面那条未打勾的条目，逐字照抄。** 那一步做完后，在这里把它打勾，并把下一条未打勾的条目提到最上面。两边绝不能对不上：`Next` 是跨项目总表展示的那一行，而这份文件才是恢复工作时真正会去读的内容。

每条都带着加入日期，这样一年前的未完成条目一眼就能看出是陈旧的，而不是悄悄变成永久性的：

```
- [ ] YYYY-MM-DD <要做的事> — <从哪里开始：文件、命令，或悬而未决的问题>
- [x] YYYY-MM-DD <一条已完成的>
```

写条目时要让人能"冷启动"去做。"improve error handling" 只是个备忘，不是一条 backlog 条目；"wrap the mount call in retry — src/mount.py, the bare except at the bottom" 才是。

---

## 条目

- [ ] 2026-08-23 让 supervisor 的 Remote Control repair 真正起到修复作用——目前它发送 `/remote-control`，而在一个自认为已连接的会话上，这只会弹出一个提示对话框，什么都不重建，随后又把一个未变化的 `bridgeSessionId` 当作成功的证据，从不重试。真正有效的流程是先在那个对话框里点 `Disconnect this session`，再执行 `/remote-control`；真正的重连会*改变*这个 id，所以成功与否必须以"是否变化"来判定，而不是"是否非空"。从 `capture_remote_control_url` 和 bin/claude-guardian.sh 里的检查入手，并阅读 2026-08-23 那条 DECISIONS.md 记录——已撤回的 v0.7.0 已经实现了这两半逻辑，从打包文件里恢复它大概率比重写更省事
- [ ] 2026-08-23 决定"所有实例共用一个 tmux server"这件事是否可以接受——这个 server 由最先启动的那个 unit 拉起，所以之后所有实例都跑在*那个* unit 的 cgroup 里（已确认：两个实例都挂在 `claude-guardian@claude-code.service` 下）。停掉或重启那一个 unit 会把其他所有实例一并带下去，按实例统计资源也就失去意义了。从 `write_unit_template` 和 bin/claude-guardian.sh 里的 `new-session` 调用入手
- [ ] 2026-09-12 给 `resume` 加一个 `--workdir` 参数——归档保留的是它归档时的 workdir，所以一个在某个会话账户下归档的实例，换到另一个账户下时无法直接恢复，得先手动改归档目录里的 `meta.env`（v0.10.0 迁移时就是这么干的）；从 bin/claude-guardian.sh 里的 `cmd_resume` 入手
- [ ] 2026-09-12 让 trust-prompt 的应答能扛住文案改动——`answer_trust_prompt` 匹配的是字面字符串 "trust this folder" 和 "❯ No, exit" 那一行光标提示，一旦 Claude Code 某次发布改写了这个屏幕，当初为了阻止的重生循环就会悄无声息地重新出现，日志里只会写着 `claude exited`；从 bin/claude-guardian.sh 里的 `answer_trust_prompt` 入手，考虑改用一个正向信号（会话到达它的提示符）而不是负向信号
- [x] 2026-09-12 让被监督的会话以非特权账户运行，而不是 root，配合 `claude --dangerously-skip-permissions`——已在 v0.10.0 中以 `RUN_AS_USER` 的形式发布：root 负责安装和监督，tmux server 及每一个 `claude` 进程都归属那个账户，且该参数是随版本发布的默认值，因为 claude 在 root 下会拒绝这个参数
- [x] 2026-09-12 阻止一个实例访问到另一个实例的 tmux 会话——此前每个 `-t` 目标都是一个裸的会话名，而 tmux 会做前缀匹配，导致 `claude-code` 会解析到一个正在运行的 `claude-code-work`，`send-keys` 也不例外；现在所有目标都改为精确匹配（`=name` / `=name:`），已在 v0.10.0 中发布
- [x] 2026-08-23 让正在运行的 `claude-code` 实例整夜闲置，记录它是否也会变得不可达——**已有结论：会。** 两个实例在闲置约 6 小时后同时掉线，supervisor 的修复毫无作用，还从一个未变化的 id 里记录下了"成功"。完整发现见 STATUS.md 及 2026-08-23 那条 DECISIONS.md 记录；正是这一点让 v0.7.0 的问题重新被提出
- [ ] 2026-09-12 补上 `zh_tw` 翻译——v0.10.0 把中文文档迁移到了 `translated_zh_cn/` 并在那里把全部六份都更新到了最新，但这个项目从未有过 `translated_zh_tw/`，所以每次发版 `release-preflight.sh` 都会针对六份缺失文件发出警告
- [ ] 2026-09-12 精简 DECISIONS.md——19 条 / 55 KB 已经超过了 preflight 发出警告的 20 条、30 KB 这条线，其中 16 条各自超过约 1000 字节；把上一次打 tag 之前的所有条目都压缩成每条一行，单独提交，并把仍然有支撑作用的推理内容移进 DESIGN.md
- [ ] 2026-08-21 在真实重启中确认 boot floor 的效果——v0.9.0 是通过直接启动 `claude-guardian-floor.service` 来验证的，这走的是同一条代码路径，但条件并不相同（启动顺序、`network-online.target`）；把所有实例都停用，重启，预期 `claude-code` 是 active 的
- [ ] 2026-08-21 提交剩余的隔离测试套件——`tests/run-as-user.sh`（32 个用例，覆盖会话账户那一层）已随 v0.10.0 一并提交，也就是 `tests/` 目录和 README 里那一行；仍然缺失的是随 v0.7.0 撤回而消失的 Remote Control 用例，以及那套 48 个用例的 boot-floor 套件，两者目前都只存在于草稿目录里
- [ ] 2026-08-21 让 `run` 像其他所有命令一样，要求必须有实例配置文件——`load_instance` 在文件缺失时会悄悄地什么都不做，导致一个陈旧的、已启用的 unit 会用全局默认值而不是它自己的 workdir/参数把一个已归档的实例复活，而 `list`/`url`/`activate` 在同样缺失文件时都会直接报错退出；从 bin/claude-guardian.sh 里的 `load_instance` 入手
- [ ] 2026-08-21 等整夜测试结果出来后，决定如何处理已撤回的 v0.7.0/v0.8.0 那部分工作——被删除的 ref 保存在一个放在本仓库之外的打包文件里（见 ../.local-notes.md）；2026-08-21 那条 DECISIONS.md 记录列出了里面都有什么
- [ ] 2026-08-21 给 v0.6.2 加一种方法，能在宿主机看起来健康、但会话不可达时修复它——目前完全没有这种手段，操作者只能手动 attach 并敲 `/remote-control`；从 bin/claude-guardian.sh 里的 `capture_remote_control_url` 入手，并先读 2026-08-21 那条 DECISIONS.md 记录，因为已撤回的版本已经针对这个问题尝试过两种方案
- [ ] 2026-08-21 迁移已存在的 /etc 配置，使其能拿到写好之后才新增的设置项——`install` 从不重写它，所以宿主机可能会悄悄退回内置默认值，导致一个已发布的功能实际存在却处于不生效状态；从 bin/claude-guardian.sh 里的配置模板 heredoc 入手
- [x] 2026-08-23 修复 `claude-guardian attach` 因 `exec: tmux_cmd: not found` 而挂掉的问题——bin/claude-guardian.sh 里的 `cmd_attach` 把 `tmux_cmd` 这个 shell 函数当成 PATH 上的一个二进制文件来 `exec`；已内联为 `tmux -S "$TMUX_SOCKET" ...` 调用，随 v0.9.1 发布
- [x] 2026-08-21 把"始终至少有一个会话可用"变成一条强制保证的属性，而不是一个偶然产生的结果——已在 v0.9.0 中发布：当已启用的会话数即将降到零时，`archive`/`deactivate` 会先警告并征求确认；`claude-guardian-floor.service` 会在没有其他会话时于开机时重新创建默认实例（`ENSURE_DEFAULT_INSTANCE`，默认开启）
- [x] 2026-08-21 把 BACKLOG.md 恢复为 v0.6.2 基线的一部分——它是在 v0.7.0 的工作中创建的，随着 main 被强制重置而消失；是根据当前的未完成条目重新写出的，而不是从已删除的 ref 中恢复的
- [x] 2026-08-21 撤回 v0.7.0 和 v0.8.0，把代码基线还原到 v0.6.2——tag、v0.7.0 的 Release 以及两份快照均已删除，main 已强制重置；详见 2026-08-21 那条 DECISIONS.md 记录

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
