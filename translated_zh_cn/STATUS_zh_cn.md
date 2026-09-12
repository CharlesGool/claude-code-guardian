# 状态

[English](../STATUS.md) | **简体中文**

> 译自 `STATUS.md`（v0.10.0）。如有冲突，以英文版为准。

**Notion：** 私有镜像（未发布）
**仓库：** https://github.com/CharlesGool/claude-code-guardian（公开，GPL-3.0）
**快照：** 私下维护（未发布）
**发布：** https://github.com/CharlesGool/claude-code-guardian/releases/tag/v0.10.0
**进行中：** 无 —— v0.10.0 已发布。

在 v0.10.0 中：被监督的会话不再以 root 身份运行。`RUN_AS_USER` 指定拥有
tmux server、每个 `claude` 进程以及 `claude` 写出的一切内容的账户；root
仍负责安装和监督。正是这个拆分才使 `--dangerously-skip-permissions` 得以
使用——`claude` 以 root 身份运行时会拒绝该参数——现在它已成为出厂默认值，
而 root 身份安装则改为使用 `--permission-mode auto --remote-control`，且
`install`/`new`/`run` 会直接拒绝那种不可能成立的组合，而不是任其永远重生。
现有安装不受影响：`RUN_AS_USER` 会回退到 `root`，`install` 依旧从不改写
已有配置。

在完成这项工作的过程中发现了两个缺陷，并在同一版本中一并修复。此前每个
tmux 目标都是裸会话名，而 tmux 会退回前缀匹配，因此当 `claude-code` 和
`claude-code-work` 同时存在时，指向前者的命令会落到后者身上——`send-keys`
也不例外，即 `/remote-control` 和裸回车键会误入另一个实例的对话中。现在
所有目标都改为精确匹配（`=name`、`=name:`），已针对 tmux 3.2a 验证。另
外，`list` 对已停止的实例会把 `inactive` 打印两次，导致该行换行错位。

已验证：shellcheck 检查通过；`tests/run-as-user.sh`，一套全新的、不安装
任何东西的 32 用例隔离测试套件（这同时也是长期挂在待办清单上的"提交测试
套件"这一项首次真正落地）；以及在维护者本机上的实机验证——从 root 到无
特权账户的端到端迁移：两个实例被归档，其对话记录被复制过去，两者都在各
自原来的对话上、用各自原来的 Remote Control URL 恢复运行；supervisor 重启
时 tmux server 和 `claude` 进程 PID 均保持不变（`RuntimeDirectoryPreserve`）；
`attach` 能从 root 正确降级到会话账户；`run` 会拒绝以错误账户启动。
未验证：迁移后主机的一次真实重启，以及在没有可采用的无特权账户的主机上
进行全新安装。

这次迁移带来的两点教训都已写入 DECISIONS.md 和 BACKLOG.md：一是 tmux
socket 的存活时间会超过其 server 本身，一个属主为 root 的残留 socket 会
导致每次创建会话都以 `Permission denied` 失败，而日志里却只显示 `claude`
已退出（`install` 现在会清理陈旧的残留 socket，并拒绝清理仍在使用中的）；
二是当某个账户首次打开一个目录时，`claude` 会问一个当时无法回答的问题——
"do you trust this folder?"，且默认预选的是 **No, exit**——现在由 supervisor
负责回答这个问题，因为此前它为引导界面盲发的回车键，恰好选中的就是这个
预选项。

此前，在 v0.9.1 及更早版本中：已经复现并弄清了"主机看起来健康，但会话却
无法从 claude.ai 连接"这一故障——supervisor 的修复动作其实是空操作（向一个
自认为已连接的会话发送 `/remote-control`，只会弹出一个提示性对话框），而
它随后又把未发生变化的 `bridgeSessionId` 当作修复成功的证据，导致一次失败
的修复会让此后每一次修复都保持沉默。真正有效的操作序列是先在那个对话框里
选择 `Disconnect this session`，再发送 `/remote-control`，这样才会生成一个
新的 id；判断修复是否成功必须以"是否发生了变化"为准，绝不能以"是否非空"
为准。已撤回的 v0.7.0 其实已经实现了这两部分逻辑，而操作者也已确认修复后
的 URL 能够从远程客户端驱动其会话，因此把那部分工作找回来是可以立即着手
的事——这是待办清单上的第一项。完整证据见 DECISIONS.md（2026-08-23）。
v0.9.1 修复了 `attach` 因 `exec: tmux_cmd: not found` 而崩溃的问题；v0.9.0
把"至少始终有一个会话可用"变成了一条强制保证的属性（`archive`/`deactivate`
会在开机自启数量将降为零之前发出警告，`claude-guardian-floor.service` 会
在开机时重新创建默认实例）。v0.7.0 和 v0.8.0 已于 2026-08-21 撤回；v0.6.2
是此后所有工作的基线起点。

**下一步：** 2026-08-23 让 supervisor 的 Remote Control 修复动作真正起到
修复作用——目前它发送 `/remote-control`，而对一个自认为已连接的会话来说，
这只会弹出一个提示性对话框、不会重建任何东西，随后它又把未发生变化的
`bridgeSessionId` 当作修复成功的证据，此后再也不会重试。真正有效的操作
序列是先在那个对话框里选择 `Disconnect this session`，再发送
`/remote-control`；一次真正的重新连接会*改变*这个 id，因此判断是否成功
必须以"是否发生变化"为准，绝不能以"是否非空"为准。从
`capture_remote_control_url` 和 bin/claude-guardian.sh 里的相应检查入手，
并阅读 2026-08-23 那条 DECISIONS.md 条目——已撤回的 v0.7.0 已经实现了这
两部分逻辑，从旧版本包里找回它大概率比重写更省事

**已知问题：**
- 在一台正在运行的主机上更改 `RUN_AS_USER` 属于迁移操作，而不是设置项的
  调整。对话记录仍留在旧账户的 `~/.claude` 下，新账户读不到；而 `resume`
  没有 `--workdir` 参数，因此在旧账户下建立的归档，在能被新账户恢复之前，
  需要手动编辑其 `meta.env`。README → Install 一节给出了具体步骤。
- 首次运行时的信任确认提示会被*代为*回答（默认预选 **No, exit**，若放任
  不管，实例就会被永远重生进这个界面）。这个检测逻辑匹配的是该界面当前
  的措辞——一旦 Claude Code 改了措辞，这个循环就会重新出现，而日志里只会
  显示 `claude exited`。
- `--dangerously-skip-permissions` 成为默认值意味着该会话拥有会话账户的
  全部权限，如果该账户拥有免密码的 `sudo`，甚至包括 root 权限。更安全的
  root 方案只需改一行配置，`check` 会报告某台主机当前用的是哪种组合。
- boot floor 是一个 `oneshot`：只在开机时运行一次，而非持续运行。若在
  会话过程中归档掉最后一个实例，主机上就不会有任何实例在运行，直到下次
  重启或手动执行 `claude-guardian ensure-floor`。这是刻意的取舍（持续运行
  的 floor 会让 `archive` 变得没法用），新增的警告则覆盖了交互式场景。
- 当 `ENSURE_DEFAULT_INSTANCE=1` 时，停用*最后一个*实例的效果会在下次开机
  时被撤销，这与 `deactivate` 自身"不会在开机时重启"的说法相矛盾。这是
  刻意为之——保证优先——`deactivate` 会在执行前说明这一点；如果希望主机
  开机后保持空闲，需要把这个设置项改为 `0`。
- 一个会话可能在本机看起来一切正常的情况下，从 claude.ai 端变得无法连接，
  而目前仍没有能修复它的命令。截至 2026-08-23，这是一个**已定性的缺陷，
  不再是悬而未决的问题**——见上面编号的六条发现。对目前遇到这个问题的人
  来说，有两点最关键：attach 上去输入 `/remote-control` **并不能修复它**
  （对一个自认为已连接的会话，它只会弹出一个提示性对话框）；真正有效的
  修复方式是先在那个对话框里选择 `Disconnect this session`，再执行
  `/remote-control`，这样会生成一个新的 URL，旧 URL 之后即失效。supervisor
  目前只会自动执行那个无效的那一半动作，然后就记录为成功，这正是问题会
  悄无声息持续存在的原因。
- 一个停在确认对话框上、周围又没人处理的实例，现在会一直停在那里，直到
  有人回答那个提示。这是 v0.6.0 的取舍，不是缺陷，但确实意味着一个被搁置
  的实例可能无限期地闲置下去；把 `UNATTENDED_NUDGE_SEC` 设为大于 `0` 的值
  即可重新启用自我解困机制，启用前请先重读 DESIGN.md → Known limitations
  一节。
- 重启后的恢复依赖 Claude Code 的对话记录目录命名规则（工作目录中所有非
  字母数字字符替换为 `-`），已针对 2.1.202 验证过。如果这一命名约定发生
  变化，每次重启都会悄悄地重新开始一段新对话——不会报任何错，因此症状本身
  就是唯一的信号。

**阻塞于：** 无。

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
