# Status

[English](../STATUS.md) | **简体中文**

> 译自 `STATUS.md`（v0.10.1）。如有冲突，以英文版为准。

**Notion:** 私有镜像（未发布）
**Repo:** https://github.com/CharlesGool/claude-code-guardian（public，GPL-3.0）
**Snapshots:** 私下维护（未发布）
**Release:** https://github.com/CharlesGool/claude-code-guardian/releases/tag/v0.10.1
**In progress:** 无 —— v0.10.1 已发布。

在 v0.10.1 中（仅文档变动，代码与 v0.10.0 逐字节相同）：v0.10.0 未能验证的那次真实重启，如今已在迁移后的主机上发生并通过验证——该实例以 `active`/`up` 状态及其 URL 恢复，`claude` 以会话账户身份对其此前的对话执行了 `--resume`，`/run/claude-guardian` 也被 `RuntimeDirectory=` 重建为归属该账户的 `drwx------`，这唯有一次真实的启动才能验证到这一环。同一次测试还表明，文档中记录的重启检查方式对一个已 `resume` 的实例是错的：它记录的是 `resuming archived conversation`，而不是 `continuing this instance's previous conversation`，因为固定的 `RESUME_SESSION_ID` 优先级更高。README 和 DESIGN.md 现在把两行日志都列了出来。

在 v0.10.0 中：受监督的会话不再以 root 身份运行。`RUN_AS_USER` 指定拥有 tmux server、每个 `claude` 进程以及 `claude` 写入的一切内容的账户；root 仍然负责安装和监督。正是这个拆分，才让 `--dangerously-skip-permissions` 得以真正可用——`claude` 以 root 身份运行时会拒绝该参数——如今这已是出厂默认配置，而 root 安装则改用 `--permission-mode auto --remote-control`，这种不可能的组合会被 `install`/`new`/`run` 直接拒绝，而不是留给它无限重生。已有安装不受影响：`RUN_AS_USER` 会回退到 `root`，且 `install` 依旧从不改写既有配置。

在做这项工作时发现了两个缺陷，并在同一版本中修复。此前每个 tmux 目标都是裸会话名，而 tmux 会回退到前缀匹配，所以当 `claude-code` 和 `claude-code-work` 同时存在时，指向前者的命令会落到后者身上——`send-keys` 也不例外，也就是说 `/remote-control` 和裸回车会打进另一个实例的对话里。现在所有目标都是精确匹配（`=name`、`=name:`），已在 tmux 3.2a 上验证。此外，对于已停止的实例，`list` 会把 `inactive` 打印两遍，导致该行换行。

已验证：shellcheck 干净；`tests/run-as-user.sh`——一个不安装任何东西的、全新的 32 用例隔离测试套件（这也是长期挂在 backlog 里的"提交测试套件"这一项首次真正落地）；以及在维护者本人主机上进行的实机验证，完整端到端地将 root 迁移到无特权账户——两个实例被归档，其对话记录被复制过去，两者都在各自原有的对话上以各自原有的 Remote Control URL 恢复，一次监督进程重启没有动到 tmux server 和 `claude` 的 PID（`RuntimeDirectoryPreserve`），`attach` 从 root 正确降级到会话账户，`run` 拒绝以错误账户启动。未验证：在一台没有可供接管的无特权账户的主机上进行全新安装（迁移主机上的真实重启已在 v0.10.1 中验证）。

这次迁移带来了两点认知，均已写入 DECISIONS.md 和 BACKLOG.md：tmux socket 的存活期长于其 server，一个残留的 root 属主 socket 会导致每次创建会话都以 `Permission denied` 失败，而日志只会显示 `claude` 已退出（`install` 现在会清理陈旧的残留 socket，并拒绝清理一个仍在使用中的）；以及 `claude` 在某个账户首次打开一个目录时会问一个无法预先回答的问题——"do you trust this folder?"，并预先选中 **No, exit**——现在由监督进程来回答这个问题，因为此前它为引导界面盲发的回车，选中的恰恰就是这一项。

此前，在 v0.9.1 及更早版本中："主机看起来健康，但会话却无法从外部连通"这一故障已被复现并弄清原因——监督进程的修复动作是个空操作（向一个自认为已连接的会话发送 `/remote-control` 只会弹出一个提示性对话框），随后它又把不变的 `bridgeSessionId` 当作修复成功的证据，导致一次失败的修复会让此后所有修复都失声。真正有效的操作序列是先在那个对话框里执行 `Disconnect this session`，再执行 `/remote-control`，这会生成一个新 id；判断成功与否必须以"是否发生了*变化*"为准，绝不能以"是否非空"为准。已撤回的 v0.7.0 其实已经实现了这两半逻辑，且该操作员已确认修复后的 URL 能从远程客户端驱动其会话，因此找回那部分工作已不再受阻——这是 backlog 里的头号事项。完整证据见 DECISIONS.md（2026-08-23）。v0.9.1 修复了 `attach` 因 `exec: tmux_cmd: not found` 而崩溃的问题；v0.9.0 把"始终至少有一个会话可用"变成了一个强制保证的属性（`archive`/`deactivate` 会在开机启动数量降到零之前发出警告，`claude-guardian-floor.service` 会在开机时重建默认实例）。v0.7.0 和 v0.8.0 已于 2026-08-21 撤回；v0.6.2 是此后一切工作的基线。

**Next:** 2026-08-23 让监督进程的 Remote Control 修复动作真正起到修复作用——目前它发送的是 `/remote-control`，而这在一个自认为已连接的会话上只会弹出一个提示性对话框、什么也不会重建，随后又把不变的 `bridgeSessionId` 当作修复成功的证据，此后也不再重试。真正有效的操作序列是先在那个对话框里执行 `Disconnect this session`，再执行 `/remote-control`，而一次真正的重连会*改变*这个 id，因此判断成功必须以"是否发生了变化"为准，绝不能以"是否非空"为准。从 `capture_remote_control_url` 和 `bin/claude-guardian.sh` 里的检查逻辑入手，并阅读 2026-08-23 那条 DECISIONS.md 条目——已撤回的 v0.7.0 已经实现了这两半逻辑，从旧版本包里把它找回来，大概率比重写更省事
**Known issues:**
- 在一台在用的主机上更改 `RUN_AS_USER` 是一次迁移，而不是改一个设置项。对话记录仍留在旧账户的 `~/.claude` 下，新账户读不到它，而 `resume` 没有 `--workdir` 参数，所以在旧账户下建立的归档，要先手动编辑其 `meta.env`，才能在新账户下被 resume。README 的 Install 一节写了具体步骤。
- 首次运行的信任提示会*被代为回答*（预选的是 **No, exit**，所以放任不管会让实例无限重生进这个界面）。这个检测逻辑匹配的是该界面当前的措辞——如果 Claude Code 改了措辞，这个循环就会重新出现，而日志只会显示 `claude exited`。
- `--dangerously-skip-permissions` 作为默认配置，意味着该会话拥有会话账户的全部权限，如果该账户拥有免密 `sudo`，甚至包括 root 权限。root 安全的替代方案只需一行配置，`check` 会报告某台主机当前所处的配对状态。
- boot floor 是一个 `oneshot`：它只在开机时运行一次，而不是持续运行。在会话中途归档掉最后一个实例，主机上就会没有任何实例在运行，直到下次重启或手动执行 `claude-guardian ensure-floor`。这是刻意的权衡（持续运行的 floor 会让 `archive` 变得无法使用），交互场景下新增的警告已经覆盖了这种情况。
- 在 `ENSURE_DEFAULT_INSTANCE=1` 下，停用*最后一个*实例的操作会在下次开机时被撤销，这与 `deactivate` 自身"不会在开机时重启"的说法相矛盾。这是刻意为之——这个保证优先——且 `deactivate` 会在执行前说明这一点；如果一台主机需要以空闲状态开机，就需要把这个设置项调成 `0`。
- 一个会话可能在这台主机上一切看起来都健康的情况下，从 claude.ai 端变得无法连通，而目前仍没有能修复它的命令。截至 2026-08-23，这已是一个**已查清的缺陷，而不是悬而未决的问题**——见上面那六条编号发现。对眼下遇到这个问题的人，有两点最要紧：attach 后敲 `/remote-control` **修不好它**（它只会在一个自认为已连接的会话上弹出一个提示性对话框）；真正有效的修复是先在那个对话框里执行 `Disconnect this session`，再执行 `/remote-control`，这会生成一个新 URL。旧 URL 之后就失效了。监督进程会自动执行那没用的一半，然后记录成功，这就是为什么这个状态会悄无声息地持续存在。
- 一个卡在确认对话框上、且当时无人在场的实例，现在会一直卡着，直到有人来回答它。这是 v0.6.0 的权衡取舍，不是缺陷，但确实意味着一个被遗弃的实例可能无限期地闲置下去；把 `UNATTENDED_NUDGE_SEC` 设为大于 `0` 的值即可重新启用自动脱困，启用前请先重读 DESIGN.md 的 Known limitations 一节。
- 重启后能否恢复取决于 Claude Code 对话记录目录的命名方式（工作目录中所有非字母数字字符都被替换为 `-`），已在 2.1.202 上验证。如果这个约定发生变化，每次重启都会悄悄开启一段全新对话——不会报任何错，所以症状本身就是唯一的信号。
**Blocked on:** 无。

<!--
保持这份文件简短。只写当前状态——历史记录属于 CHANGELOG.md 和 git log。
对公开仓库而言，这里绝不要写 Notion URL、本地/NAS 绝对路径、内部主机名，
或任何其他仅供维护使用的标识符。这些信息保存在维护者本地、仓库之外的
.local-notes.md 文件中，因此永远不会被提交，也永远不会进入快照。

按事件更新，而不是"在会话结束前"更新（会话从不会宣布自己结束）：
  - 打了一个 tag
  - 做出了会影响后续工作的决定
  - 被某事卡住
  - 用户说"先到这里"或类似的话
  - Next 里写的那一步已经完成
-->
