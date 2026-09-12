# Backlog

[English](../BACKLOG.md) | **简体中文**

> 译自 `BACKLOG.md`（v0.10.0）。如有冲突，以英文版为准。

需求清单。所有被提出过的需求，按重要性从高到低排列，做完就打勾。这份文件回答的是"隔了两周之后，接下来该做什么"，也是一次会话结束时仍有未完工作时，需求该去的地方。

**`STATUS.md` 的 `Next:` 字段就是最上面那条未勾选的条目，逐字照抄。** 那一步做完后，在这里打勾，并把下一条未勾选的条目提到 `STATUS.md` 里。两处绝不能不一致：`Next` 是跨项目总表展示的那一行，这份文件才是续接工作时真正要读的内容。

每条都带上加入日期，这样一年前就开着的条目会一眼看出陈旧，而不是悄悄地一直挂着：

```
- [ ] YYYY-MM-DD <要做什么> — <从哪里入手：文件、命令，或尚待厘清的问题>
- [x] YYYY-MM-DD <已完成的一条>
```

写条目时要让人能"冷启动"直接上手。"改进错误处理"是一句备注，不是一条 backlog 条目；"给 mount 调用包一层重试 —— src/mount.py，最底下那个裸 except"才是。

---

## Items

- [ ] 2026-08-23 让 supervisor 的 Remote Control 修复真正起到修复作用 —— 目前它发送 `/remote-control`，而在一个自认为已连接的会话上，这只会打开一个提示对话框、什么都不重建，随后把一个未变化的 `bridgeSessionId` 当作成功的证据，从不重试。可行的操作序列是先在那个对话框里点 `Disconnect this session`，再发 `/remote-control`；真正的重连会*改变*这个 id，所以判断成功必须以"变了"为准，绝不能以"非空"为准。从 `capture_remote_control_url` 和 bin/claude-guardian.sh 里的那处检查入手，并读一下 2026-08-23 DECISIONS.md 那条记录 —— 已撤回的 v0.7.0 曾经把这两半都实现过，从那批 bundle 里把它捞回来大概率比重写更省事
- [ ] 2026-08-23 决定"所有实例共用一个 tmux server"这件事能不能接受 —— 这个 server 是由最先起来的那个 unit 启动的，所以后起的所有实例都跑在*那个* unit 的 cgroup 里（已确认：两个实例同时挂在 `claude-guardian@claude-code.service` 下）。停掉或重启那一个 unit 会把其他所有实例一起带下去，按实例统计资源也就没有意义了。从 `write_unit_template` 和 bin/claude-guardian.sh 里的 `new-session` 调用入手
- [ ] 2026-09-12 给 `resume` 加一个 `--workdir` 参数 —— 归档保留的是它归档时的 workdir，所以在某个会话账号下归档的实例，换一个账号就无法直接 resume，得先手动改归档目录里的 `meta.env`（v0.10.0 迁移时就是这么干的）；从 bin/claude-guardian.sh 里的 `cmd_resume` 入手
- [ ] 2026-09-12 让 trust 提示的应答逻辑经得起改文案 —— `answer_trust_prompt` 匹配的是字面字符串 "trust this folder" 和 "❯ No, exit" 那一行光标，一旦 Claude Code 某次发布改写了那个界面，之前为了阻止的重生循环就会悄悄恢复，而日志只会显示 `claude exited`；从 bin/claude-guardian.sh 里的 `answer_trust_prompt` 入手，并考虑改用正向信号（会话到达提示符）而不是负向信号
- [x] 2026-09-12 让被监督的会话以非特权账号而非 root 运行，配合 `claude --dangerously-skip-permissions` —— 已在 v0.10.0 中以 `RUN_AS_USER` 形式发布：root 负责安装和监督，tmux server 以及每一个 `claude` 进程都归属该账号，且该参数是随包附带的默认值，因为 claude 在 root 下会拒绝这个 flag
- [x] 2026-09-12 阻止一个实例连到另一个实例的 tmux 会话 —— 之前每个 `-t` 目标都是裸的会话名，而 tmux 会做前缀匹配，导致 `claude-code` 会解析到一个正在运行的 `claude-code-work`，`send-keys` 也包含在内；现在所有目标都改成精确匹配（`=name` / `=name:`），已在 v0.10.0 中发布
- [x] 2026-08-23 让运行中的 `claude-code` 实例整夜空闲，并记录它是否也变得不可达 —— **已有答案：会。** 两个实例在闲置约 6 小时后同时掉线，supervisor 的修复没有起效，并且它从一个未变化的 id 就记录了"成功"。完整发现见 STATUS.md 和 2026-08-23 DECISIONS.md 那条记录；这就是重新打开 v0.7.0 那个问题的原因
- [ ] 2026-09-12 补上 `zh_tw` 译版 —— v0.10.0 把中文文档迁到了 `translated_zh_cn/` 并把六份全部更新到位，但这个项目从来没有过 `translated_zh_tw/`，所以 `release-preflight.sh` 每次发版都会因六个文件缺失而报警告
- [ ] 2026-09-12 压缩 DECISIONS.md —— 19 条 / 55 KB 已经超过 preflight 报警告的 20 条、30 KB 那条线，其中 16 条各自超过约 1000 字节；把上一个 tag 之前的所有条目都压成每条一行，单独一次 commit 完成，并把仍然有价值的推理内容搬进 DESIGN.md
- [ ] 2026-08-21 通过一次真实重启确认 boot floor 逻辑 —— v0.9.0 是靠直接启动 `claude-guardian-floor.service` 来验证的，代码路径相同，但条件不同（启动顺序、`network-online.target`）；把所有实例都停用，重启，预期 `claude-code` 处于 active 状态
- [ ] 2026-08-21 提交剩余的独立测试套件 —— `tests/run-as-user.sh`（32 个用例，覆盖会话账号那一层）已随 v0.10.0 提交，即 `tests/` 目录和 README 里那一行；仍然缺失的是随 v0.7.0 撤回一起消失的 Remote Control 用例，以及那套 48 个用例的 boot-floor 套件，这两者目前都只存在于草稿目录里
- [ ] 2026-08-21 让 `run` 像其他命令一样，要求必须有实例配置文件 —— 目前 `load_instance` 在文件缺失时会悄悄地什么都不做，所以一个过期但仍处于 enabled 状态的 unit 会用全局默认值而不是自己的 workdir/参数，把一个已归档的实例重新救活，而 `list`/`url`/`activate` 在遇到同样缺失的文件时则会直接报错退出；从 bin/claude-guardian.sh 里的 `load_instance` 入手
- [ ] 2026-08-21 一旦整夜测试的结果出来，决定如何处理已撤回的 v0.7.0/v0.8.0 那批工作 —— 被删除的 ref 保存在本仓库之外的一个 bundle 里（见 ../.local-notes.md）；2026-08-21 DECISIONS.md 那条记录列出了里面都有什么
- [ ] 2026-08-21 给 v0.6.2 加一种手段，能在宿主机看起来健康、但某个会话不可达时修复它 —— 目前没有任何手段，操作者只能手动 attach 进去敲 `/remote-control`；从 bin/claude-guardian.sh 里的 `capture_remote_control_url` 入手，并先读一下 2026-08-21 DECISIONS.md 那条记录，因为已撤回的那几个版本已经对这个问题给出过两种答案
- [ ] 2026-08-21 迁移一份已存在的 /etc 配置，使其能吸收首次写入之后新增的设置项 —— `install` 从不重写它，所以宿主机可能悄悄地退回内置默认值，一个已发布的功能实际存在却处于失效状态；从 bin/claude-guardian.sh 里配置模板的 heredoc 入手
- [x] 2026-08-23 修复 `claude-guardian attach` 报 `exec: tmux_cmd: not found` 而崩溃的问题 —— bin/claude-guardian.sh 里的 `cmd_attach` 把 `tmux_cmd` 这个 shell 函数当成 PATH 上的一个二进制来 `exec`；已改为内联 `tmux -S "$TMUX_SOCKET" ...` 调用，已在 v0.9.1 中发布
- [x] 2026-08-21 把"始终至少有一个会话可用"从一个自发出现的现象变成一条强制生效的属性 —— 已在 v0.9.0 中发布：当启用开机自启的会话数即将降到零时，`archive`/`deactivate` 会发出警告并要求确认；而 `claude-guardian-floor.service` 会在开机时、若没有其他会话可用的情况下重建默认实例（`ENSURE_DEFAULT_INSTANCE`，默认开启）
- [x] 2026-08-21 把 BACKLOG.md 作为 v0.6.2 基线的一部分恢复回来 —— 它是在 v0.7.0 那批工作期间创建的，main 被强制重置后随之消失；这次是根据当前的未完成条目重写的，而不是从被删除的 ref 中恢复的
- [x] 2026-08-21 撤回 v0.7.0 和 v0.8.0，把代码基线还原到 v0.6.2 —— 已删除相关 tag、v0.7.0 的 Release 以及两份快照，main 已强制重置；见 2026-08-21 DECISIONS.md 那条记录

<!--
打勾，不要删除。打了勾的条目是"这条需求被听到并处理过"的证据 —— 删掉它会让这份清单看起来一直很短，也就没法区分"从没被提出过"和"提出过并且做完了"。

范围划分，避免这份文件变成另一份"什么都记一遍"的清单：

  这里              所有需求，无论开着还是已打勾
  DECISIONS.md      考虑过并否决掉的方案，附带理由 —— 否则同一个点子会每隔几周被重新提一次、
                    再被重新否决一次
  CHANGELOG.md      每个版本实际发布了什么，写给使用这个项目的人看；这份文件是它背后的工作清单
  STATUS.md         最上面那条未打勾的条目，加上当前状态
  todo 工具         今天这次会话里的步骤；这些第二天就没了，这正是它们不写进这里的原因

按事件更新，而不是"等会话结束前再更新"（一次会话从不会宣布自己要结束了）：
  - 用户提出了一个当下没有在做的需求 —— 当场写下来，不要等到最后
  - 一条需求做完了 —— 打勾，并把 STATUS.md 的 Next 挪到下一条未打勾的条目
  - 一条需求不再需要了 —— 把它连同理由一起移到 DECISIONS.md；悄悄丢掉的话，
    两周后它就会作为一个"新提案"再冒出来一次

保持这份清单只记真正打算要做的工作。一份没人信得过是真实的 backlog，看一次就会被无视。

在公开仓库中，与 STATUS.md 相同的脱敏规则同样适用：不放 Notion URL、不放本地/NAS
绝对路径、不放内部主机名。这些内容放在 repo/ 之外的 ../.local-notes.md 里。
-->
