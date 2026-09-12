# 更新日志

[English](../CHANGELOG.md) | **简体中文**

> 译自 `CHANGELOG.md`（v0.10.0）。如有冲突，以英文版为准。

最新版本在最前面。只记录用户能感知到的变化——内部重构不需要写条目。先用
`git log <previous-tag>..HEAD --oneline` 打草稿，再改写成面向用户的说法。

## v0.10.0 — 2026-09-12

受监督的会话不再以 root 身份运行。`RUN_AS_USER` 指定拥有 tmux server、
每一个 `claude` 进程、以及 `claude` 写入的一切内容的账号；root 仍负责
安装和监督。这么改的理由不是"讲卫生"：`claude` 在以 root 身份运行时会
直接拒绝 `--dangerously-skip-permissions`，所以一个绝不能停下来等权限
确认的会话根本无法存在——而这个参数现在已是默认值。

对已有安装来说没有任何变化。`RUN_AS_USER` 会回退到 `root`，而 `install`
仍然从不改写已有的配置文件，所以升级后的主机会照原样继续运行。迁移到非
特权账号是一次刻意的迁移，对话记录不会自动跟过去——README → Install
一节写了具体步骤。

### 新增
- **`RUN_AS_USER`**。会话所使用的账号，由 `install` 从你 `sudo` 时所在的
  那个账号写入配置。systemd 模板带上了 `User=`；socket 目录通过
  `RuntimeDirectory=` 分配（并配合 `RuntimeDirectoryPreserve=yes`，因此
  监督进程重启不会再有把正在使用的 socket 一并带走的风险），状态目录也
  会 chown 给该账号。`claude` 本身、它的登录环境、以及它的 `~/.claude`
  都以**该账号**为准来解析——登录属于某一个用户，root 已登录并不能说明
  会话实际会用哪个账号。
- **`check` 会报告会话账号**：是哪个账号、哪个 home 目录，以及
  `CLAUDE_ARGS` 和该账号搭配是否合法。以非特权身份运行时，它会跳过那些
  做不了的检查，而不是把它们判为失败。
- **首次运行的信任提示现在会被应答**。当一个账号打开它此前从未打开过的
  目录时，`claude` 会询问是否信任它——且默认选中的是**否，退出**。在无人
  值守的情况下，之前用来清除引导界面的那个 Enter 恰好选中了这一项，于是
  实例就一遍遍地重生回同一个界面。这个界面现在会被识别出来并应答为
  *是*；具体为什么这样处理是合理的、以及什么情况下这不是你想要的结果，
  见 `DESIGN.md` → Known limitations。
- **前一个会话账号遗留下来的 tmux socket 会被清理**——在 `install` 时。
  如果该账号的 server 仍在这个 socket 上运行，则会被拒绝并给出说明，而
  不是让它的会话变成孤儿。

### 变更
- **`CLAUDE_ARGS` 默认改为 `--dangerously-skip-permissions
  --remote-control`**。root 身份的安装则改为默认
  `--permission-mode auto --remote-control`；那种不可能的组合（该参数
  加上 root 会话）会被 `install`、`new` 和 `run` 直接拒绝，而不是任由它
  永远重生下去。已有配置不受影响。
- **`WORKDIR`、`CLAUDE_SESSIONS_DIR` 和 `CLAUDE_PROJECTS_DIR` 现在默认
  取自会话账号的 home 目录及其 `~/.claude`**，读的是 `passwd`，而不是
  `$HOME`——在 `sudo` 之下，`$HOME` 是 root 的，这几项本来都会指向错误
  账号的文件。
- **`install` 需要 `sudo`，而 `attach` 会降级到会话账号**，而不是以 root
  身份 attach。
- **当运行账号不对时，`run` 会拒绝启动**，这意味着已安装的 unit 早于
  当前配置。照旧启动的话，就会以错误的用户把 tmux server 和这段对话都
  建起来。
- **Preflight 只在以 root 身份运行时才安装 apt 包**；非特权的监督循环
  现在会说明缺了哪些包、该运行什么命令，而不是败在 apt 自身的权限错误
  上。

### 修复
- **一个实例曾经能把按键打进另一个实例的对话里**。每个 tmux 目标此前都
  是裸的会话名，而 tmux 会退化成前缀匹配：当 `claude-code` 和
  `claude-code-work` 同时存在时，冲着前者去的命令会落到后者头上——包括
  `send-keys`，也就是 `/remote-control` 和一个裸 Enter 都可能打进别人的
  会话。现在所有目标都改成精确匹配。
- **`claude-guardian list` 对一个已停止的实例把 `inactive` 打印了两遍**，
  并把该行余下的内容折到了第二行。

## v0.9.1 — 2026-08-23

### 修复
- **`claude-guardian attach` 现在能正常工作了**。此前它会立即以
  `exec: tmux_cmd: not found` 退出而不是完成 attach：该命令试图把一个
  内部 shell helper 当作 `PATH` 上的程序去 `exec`。现在 attach 会把你
  带入该会话的终端，与 `DESIGN.md` 的操作说明一致。其他命令
  （`url`、`logs`、`list`……）均未受影响——问题只出在 `attach` 上。

## v0.9.0 — 2026-08-21

这个工具最初的承诺——"至少有一个会话始终可用"——此前其实从未被真正强制
执行过。它之所以成立，只是因为 `install` 启用了默认实例，而此后没人把
它归档过。只要归档或停用你最后一个实例，主机重启后就会完全没有对话，
且不会有任何提示。这次发布让这个承诺从两端都变成现实。

版本号跳过了 `v0.7.0` 和 `v0.8.0`：这两个版本都曾发布，随后在
2026-08-21 撤回（见 `DECISIONS.md`），复用一个别人可能已经拉取过的 tag
会让他们在同一个名字下拿到不同的代码。

### 新增
- **一道启动兜底**。新增的 `claude-guardian-floor.service` 每次开机运行
  一次：如果压根不会有任何实例启动，它就会创建并启动默认的
  `claude-code` 实例。已经有启用实例的主机则完全不受影响。由新配置项
  `ENSURE_DEFAULT_INSTANCE` 控制，默认开启——如果你希望这样的主机开机后
  什么都不跑，就在 `/etc/claude-guardian/config.env` 里把它设为 `0`。
  注意 `install` 不会改写已有的配置文件，所以升级之后该配置项不会自动
  出现在文件里，在你自己添加之前会一直沿用内置默认值。
- **`claude-guardian ensure-floor`**，同一项检查的按需版本——用于修复一台
  已经变成什么都没在跑的主机，而不必等下一次重启。
- **`deactivate` 支持 `--yes`**，与 `archive` 保持一致。

### 变更
- **当你要移除的是开机时唯一会启动的那个实例时，`archive` 和
  `deactivate` 会发出警告**，并在未传 `--yes` 时先询问再执行。警告会
  说明下次开机实际会发生什么，这取决于 `ENSURE_DEFAULT_INSTANCE`。对
  脚本而言这是一处行为变化：在非交互式 shell 中执行
  `deactivate <last-instance>` 现在会拒绝而不是直接执行——需要传
  `--yes`。停用一个本就已禁用的实例，或者停用任何非最后一个的实例，
  行为不变，仍是静默执行。
- `uninstall` 和 `purge` 现在也会一并移除启动兜底那个 unit，这样两者
  都不会留下一个指向自己刚刚删掉的二进制文件的 unit。

## v0.6.2 — 2026-08-17

### 修复
- **v0.6.1 的修复只覆盖了重连计时器被播种的三处中的两处**。实践中最
  关键的那一处——循环启动时，也就是每次 `systemctl restart` 和每次开机
  ——仍然被当作"刚刚重连过"来播种，所以重启后的第一次断线要等完整的
  退避时间才会处理。这次做了实机验证：一次刻意的断线在几秒内就被修复，
  独立测试套件也新增了一个能在 v0.6.1 上失败的用例。

## v0.6.1 — 2026-08-17

### 修复
- **重启后第一次掉线会立即被修复，而不是最多等一分钟**。重连退避计时器
  此前被当作"刚尝试过重连"来播种，所以一个在监督进程刚启动后不久就掉线
  的实例（或者重启后，此时所有实例同时启动的情况）要白等一段本来毫无
  意义的退避窗口。这是在对 v0.6.0 做实机测试时发现的：在实例创建 40
  秒后刻意断线，结果修复用了 25 秒而不是 5 秒。首次尝试之后的重试不受
  影响。

## v0.6.0 — 2026-08-17

实例现在能保持可达：一次断开的 Remote Control 连接会在几秒内被发现，
而不是最多要等二十分钟。监督进程也不再擅自替你回答确认对话框，除非你
要求它这么做。这两处都是在生产环境跑了 v0.4.0 一个下午之后发现的。

### 变更
- **一次断线会在几秒内修复，而不是几分钟**。连接检查现在每次监督
  tick（`REMOTE_CONTROL_CHECK_SEC`，默认 5 秒）都会执行，而不是每 20
  分钟一次。这项检查本来就是被动的——只读一个文件，不往会话里打任何
  字——所以之前那个慢节奏没带来任何好处，代价却是实例明明活着、却最长
  可能有 20 分钟在 claude.ai 上不可达。重连尝试则单独限速
  （`REMOTE_CONTROL_RECONNECT_BACKOFF_SEC`，默认 60 秒），因为重连才是
  真正会往里打字的那部分。
- **无人值守的 Enter 默认关闭**。`UNATTENDED_NUDGE_SEC` 现在默认为
  `0`。Enter 会应答确认对话框当前高亮的任何选项，而"这个会话已被弃置"
  和"操作者此刻正看着这个对话框、只是还没决定"这两种情况没有任何区别
  ——v0.4.0 缩小了这个差距，但没能彻底消除它，而且确实曾被观察到替
  维护者回答了一个真实的对话框。想重新启用的话，把它设成一个具体的秒数
  即可；启用后，v0.4.0 那条"只在 `waiting` 状态下才生效"的规则依然适用。
- **`REMOTE_CONTROL_REFRESH_SEC` 被 `REMOTE_CONTROL_CHECK_SEC` +
  `REMOTE_CONTROL_RECONNECT_BACKOFF_SEC` 取代**。配置里如果还设着旧的
  名字，启动时会记一条警告并被忽略——请从
  `/etc/claude-guardian/config.env` 里删掉那一行。

### 修复
- 存储的 remote-control URL 只有在真正发生变化时才会被重写，这样
  `remote_url_updated_at` 才还是"这个 URL 是何时建立的"，而不会变成一个
  每五秒跳一次的心跳。

## v0.5.0 — 2026-08-17

`claude-session` Agent Skill 现在随本工具一同发布。

### 新增
- `skills/claude-session/`，用
  `cp -r skills/claude-session ~/.claude/skills/` 安装。有了它，Claude
  Code 就能用大白话来驱动这些命令——"开一个常驻对话"、"list my
  sessions"、"给我那个的链接"、"archive this"——而不用你记 CLI 命令。它
  也带上了破坏性命令的规则：`archive` 和 `purge` 会杀掉正在运行的
  `claude` 进程，所以这个 skill 在没有你明确点名这个动作之前，两者都不
  会执行，执行前会先展示它即将归档的是哪一个实例，也拒绝把"pause" /
  "取消激活"理解成结束对话的请求。完全可选。

### 变更
- `bin/claude-guardian.sh` 没有任何改动——这个监督脚本和 v0.4.0 逐字节
  相同。这次发布就是这个 skill，再加上两份 README 里为它补的安装说明。

## v0.4.0 — 2026-08-17

重启后的实例现在会回到它原来所在的那段对话，无人值守的 Enter 也不再
发到不需要它的会话里。这两个问题都是在生产使用中报告出来的，也都已在
v0.3.0 中被列为已知问题。见 `DECISIONS.md`，2026-08-17（"resume the
conversation across a reboot" 和 "nudge only a session that is
actually parked" 两条）。

### 修复
- **重启不再丢掉对话**。此前每次开机都会让每个实例开始一段全新的对话，
  而之前那段对话原封不动地留在磁盘上，只能靠手动 `claude --resume` 去
  找回来。现在，只要那段对话的 transcript 文件还在，实例重启后就会
  回到它原本所在的对话。想恢复旧行为可以设置 `RESUME_AFTER_RESTART=0`。
  如果一段对话已经无法恢复，则会回退到新建一段，而不是让实例卡在反复
  重生上。
- **无人值守的 Enter 不再落到有人正在使用的会话里**。此前它只按经过的
  时间触发，而 Remote Control 又不是一个 tmux 客户端，所以一个正在
  claude.ai 上被操作的会话看起来就像被弃置了，可能会有一个确认对话框
  被替操作者回答掉。监督进程现在会去问 `claude` 这个会话实际在做什么，
  只对那些确实已经停在一个未被应答的对话框上、并且已经超过完整
  `UNATTENDED_NUDGE_SEC` 的会话才会打字进去。

### 变更
- `MAX_SESSIONS` 现在默认是 `0`，即不限制；想恢复上限就设成一个正数。
  它此前默认是 `3`，读起来像是这个工具的硬性限制，而它本意其实是一道
  成本护栏。已有安装会照旧沿用
  `/etc/claude-guardian/config.env` 里已经写好的任何值。
- `UNATTENDED_NUDGE_SEC` 现在的含义是"一个确认对话框最多可以无人应答
  多久才会被清除"，而不是"这个会话最多可以多久无人碰"。默认值不变
  （`300`）。
- 新增配置项 `RESUME_AFTER_RESTART` 和 `CLAUDE_PROJECTS_DIR`。两者都有
  可用的默认值，所以已有的 `config.env` 不需要改动；`install` 一如既往
  不会改写已有配置。

## v0.3.0 — 2026-08-17

Remote Control 掉线后现在会被真正修复，而一个实例报出的 URL 也确保就是
它自己的。这两处是怎么被发现的、思路又是为什么变了，见
`DECISIONS.md`，2026-08-17（"read Remote Control state from claude's own
session file"）。

### 修复
- **实例不会再一直断线到有人发现为止**。无人值守的 keepalive 此前会
  定时重新执行 `/remote-control`，以为这样就能刷新连接；实际上并不能
  ——在一个已经连接的会话上，这个命令只会打开一个信息提示对话框。因此
  一次真正的 Remote Control 断线从来都不会被修复。监督进程现在会检查
  连接是否真的还在，只有在确实断开时才会重连。
- **`url` / `list` 曾经可能报出另一个实例的 URL**。此前 URL 是靠在终端
  里 grep 任何 `claude.ai/code/session_...` 链接得到的，所以只要屏幕上
  恰好出现了这样一个链接——不管是另一个实例的、commit message 里的、还是
  某个命令回显出来的——都可能被当成这个实例自己的 URL 记录下来。这在
  生产环境中被实际观察到过。现在 URL 来自该会话自身的状态，终端兜底方案
  也被限定在 `/remote-control` 的输出范围内。
- **监督进程不再往健康的会话里打字**。Remote Control 不是一个 tmux
  客户端，所以一个正在被 claude.ai 操作的会话看起来就像无人值守，于是
  每隔 `REMOTE_CONTROL_REFRESH_SEC` 就会收到一行 `/remote-control` 作为
  用户输入。现在连接检查只是读一个文件；只有在确实需要执行重连时才会
  发送按键。

### 变更
- `REMOTE_CONTROL_REFRESH_SEC` 现在的含义是"多久检查一次 Remote
  Control 是否仍处于连接状态"，而不是"多久重新执行一次
  `/remote-control`"。默认值不变（`1200`）；它现在限定的是一次断线最多
  能有多久不被发现。
- `url <name>` 和 `list` 报告的是该实例*当前*的 URL，而不是上次存下来的
  那个。重连会产生一个新的 URL，所以需要用的时候再去取，而不要把它当作
  书签收藏；当一个实例处于断开状态时，`url` 会给出警告，说明手上这个
  链接大概率已经失效。

### 新增
- `CLAUDE_SESSIONS_DIR`（默认为
  `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/sessions`）：Claude Code 写入其
  每个会话文件的位置。只读，只有当 Claude Code 使用非默认的配置目录时
  才需要设置。

## v0.2.0 — 2026-08-17

`claude-guardian` 现在可以同时监督多个具名的、并发的 Claude Code 实例，
而不再只能监督恰好一个。原因见 `DECISIONS.md`，2026-08-17。

### 新增
- `new <name> [--workdir D] [--args "..."] [--claude-bin PATH]`：创建、
  启用并启动一个新的、可与其他实例并发受监督的实例。超过
  `MAX_SESSIONS`（默认 3）个实例时会被拒绝。
- `list`：列出每个实例的表格——systemd 状态、tmux 状态、是否有人已
  attach、工作目录，以及它捕获到的 remote-control URL。
- `url <name>`：打印保存下来的 `claude.ai/code/...` remote-control
  URL，而不需要 attach。该 URL 会在实例创建时自动捕获，并在每次无人
  值守的 `/remote-control` 刷新时重新捕获。
- `activate <name>` / `deactivate <name>`：仅做启用+启动 / 禁用+停止
  监督——无论哪种情况，正在运行的 tmux 会话本身都会保持运行，所以暂停
  监督绝不会切断一段正在进行的对话。
- `archive <name> [--yes]`：先停用，再保存完整的滚屏记录和该实例的
  `claude` 对话 id，然后杀掉 tmux 会话——这是一个刻意的、默认需要确认
  的破坏性步骤。
- `resume <archive-id> [new-name]`：从一份归档重新创建一个实例，并通过
  `claude --resume` 继续其对话。
- `archives` / `rm-archive <id> [--yes]`：列出 / 永久删除已归档的实例。
- 每个实例创建时都带有自己的 `claude --session-id`（如果是从归档恢复的
  则是 `--resume`），所以崩溃后的重生总会继续同一段对话，而不会悄悄
  开始一段新的。
- 新增 `MAX_SESSIONS` 配置变量，限制并发实例数量（默认 `3`）；默认的
  `REQUIRED_APT_PKGS` 中新增了 `uuid-runtime`。

### 变更
- systemd unit 现在是一个模板（`claude-guardian@<name>.service`），
  而不再是单一的固定 unit。`attach`/`logs`/`start`/`stop`/`restart`/
  `status` 在不带名字参数时仍然照常工作，默认指向 `claude-code` 这个
  实例，以兼容已有的肌肉记忆式命令。
- 在已有的 v0.1.0 主机上执行 `install`，现在会把它原来的单一 unit
  原地迁移到新的模板形式，针对的还是同一个正在运行的 tmux 会话——
  `KillMode=process` 意味着这次迁移完全不会碰到正在运行的 `claude`
  进程。
- `SESSION_NAME` 不再是一个配置变量——实例名本身*就是* tmux 会话名。
- `purge` 的影响范围从"一个会话"扩大到了"每一个正在运行的实例"：现在它
  会报告存活的数量，并在继续之前要求交互式确认（或传 `--yes`），而且
  刻意从不删除 `/var/lib/claude-guardian/archive/`——需要删除归档请
  显式使用 `rm-archive`。
- `refresh_remote_control`（周期性的无人值守重连）现在也会重新捕获并
  存储该实例的 remote-control URL，并在完成后用一个 Enter 关掉随之
  出现的屏幕提示。

## v0.1.0 — 2026-08-16

首个版本。`claude-guardian` 在一台 Debian 服务器上保持至少一个可远程
attach 的 Claude Code 会话存活，由 root 管理。

### 新增
- `bin/claude-guardian.sh`：一个自包含的单文件脚本，涵盖 `install`、
  `uninstall`、`purge`、`start`/`stop`/`restart`/`status`、`attach`、
  `logs`、`check`，以及 `run`（systemd 的 `ExecStart` 目标）。
- systemd + tmux 双层监督：tmux 会话能在 `claude` 因任何原因退出
  （Ctrl+C、崩溃、`exit`）后继续存活，而 systemd（`Restart=always`，
  开机自启）能在监督进程本身挂掉或主机重启后继续存活。
- 默认启动 `claude --permission-mode auto --remote-control`——可以从网页版
  claude.ai 或手机上远程控制，而不只是通过 SSH+tmux。
- 仅在无人值守时才生效的 keepalive：清除卡住的确认提示，并在
  Anthropic 大约 30 分钟的断线阈值之前主动刷新 Remote Control 连接，
  让长时间空闲的部署保持可达。可通过 `UNATTENDED_NUDGE_SEC` /
  `REMOTE_CONTROL_REFRESH_SEC` 配置；作为一项明确的安全权衡记录在案
  （见 `DESIGN.md`）。
- Preflight 检查：自动安装缺失的 `apt` 包，要求 `claude` 二进制文件必须
  已经存在（绝不自动安装），并要求 `claude` 在 `install` 继续之前必须
  已经登录（通过 `claude auth status` 检查）。
- `purge` 命令用于彻底拆除（会话、socket、配置、已安装的二进制文件），
  与日常维护安全的 `uninstall` 相区分。
- 双语 README/DESIGN 文档，GPL-3.0 许可证。

### 修复
以下几项只是通过真实部署测试（本机和另一台独立主机）才发现的，单靠
代码审查发现不了：
- `StartLimitIntervalSec` 被放在了错误的 systemd unit 小节里。
- systemd 默认的 `KillMode=control-group` 会在 `stop`/`restart` 时把正在
  运行的 tmux 会话一并杀掉——改用 `KillMode=process` 修复。
- `CLAUDE_BIN` 在 systemd 极简的 PATH 下无法解析，尽管在交互式 shell
  下能正常解析——现在会在安装时固化为一个绝对路径，并为已安装的主机
  提供运行时自愈兜底。
- 无人值守的 keepalive 计时器会在每次重启时立即触发，而不是等待其配置
  的间隔时间过去。
- `usage()` 里一处写死的行号范围，在更早的某次提交在它上方加入许可证
  头之后被悄悄弄错了。
