# 更新日志

[English](../CHANGELOG.md) | **简体中文**

> 译自 `CHANGELOG.md`（v0.10.1）。如有冲突，以英文版为准。

最新版本在最前。只记录用户能感知到的变更——内部重构不需要记录。先用 `git log <previous-tag>..HEAD --oneline` 起草，再改写成面向用户的表述。

## v0.10.1 — 2026-09-12

无代码变更——`bin/claude-guardian.sh` 与 v0.10.0 逐字节相同。本次发版记录了 v0.10.0 当时无法验证的那一件事，并修复了那个把验证步骤写错的地方。

### Verified
- **在以非特权账号运行会话的宿主机上做了一次真实重启。** 重启后实例恢复为 `active`/`up`，带着它的 Remote Control URL，全程无需手动干预；`claude` 以会话账号身份运行，并用 `--resume` 接上了它先前的对话；`/run/claude-guardian` 在 supervisor 启动前已由 `RuntimeDirectory=` 重新创建为该账号所有、权限为 `drwx------` 的目录——这是链条里唯一只有真实重启才能触发的一环，因为此时 `/run` 是一个空的 tmpfs；首次运行的信任提示已被回答；日志中没有出现 `Permission denied` 或仅限 root 的拒绝信息。

### Fixed
- **README →「验证是否可用」以及 `DESIGN.md` 第 14 步里的重启检查，让你去找一行 `resume` 出来的实例永远不会打印的日志。** 由 `claude-guardian resume` 创建的实例，其配置里固定了 `RESUME_SESSION_ID`，该项优先于 `RESUME_AFTER_RESTART`，所以每次重启记的日志都是 `resuming archived conversation <uuid>`，而不是 `continuing this instance's previous conversation`。两者都表示先前的对话被正确接上了；文档现在把两种日志都列出来，一次正确的启动就不会再被误读成失败。

## v0.10.0 — 2026-09-12

受监管的会话不再以 root 身份运行。`RUN_AS_USER` 指定拥有 tmux 服务器、每一个 `claude` 进程、以及 `claude` 写入的一切内容的账号；root 仍负责安装与监管。这么做的理由不是卫生习惯：`claude` 在以 root 运行时会直接拒绝 `--dangerously-skip-permissions`，而现在这个参数已经是默认值，所以此前根本不可能建立一个绝不因请求权限而停下的会话。

对已有安装没有任何影响。`RUN_AS_USER` 会回退到 `root`，而且 `install` 仍然从不改写既有的配置文件，所以已升级的宿主机会照旧运行。迁移到非特权账号是一次刻意的迁移，而对话记录不会自己跟过去——README →「安装」一节给出了完整步骤。

### Added
- **`RUN_AS_USER`。** 会话账号，由 `install` 从你 `sudo` 之前所在的账号写入配置。systemd 模板里带上了 `User=`；套接字目录通过 `RuntimeDirectory=` 到位（并配有 `RuntimeDirectoryPreserve=yes`，因此 supervisor 重启不再有带走存活套接字的风险），状态目录也 chown 给该账号。`claude` 本身、它的登录环境、以及它的 `~/.claude`，全部**以该账号身份**解析——登录归属于某一个用户，root 已登录这件事本身并不能说明会话实际会用哪个账号。
- **`check` 会汇报会话账号**：是哪个账号、家目录在哪、以及 `CLAUDE_ARGS` 与该账号的搭配是否合法。以非特权身份运行时，它会跳过做不了的检查，而不是让检查失败。
- **首次运行的信任提示会被自动回答。** 当某个账号打开一个它从未打开过的目录时，`claude` 会询问是否信任该目录——且默认选中的是**「No, exit」**。在无人值守的情况下，用于清除引导画面的那个 Enter 恰好会选中这一项，实例便会永远重生回同一个画面。现在这个画面会被识别并回答为*是*；具体在什么情况下这样做是合理的、什么情况下不是，见 `DESIGN.md` →「已知局限」。
- **前一个会话账号留下的 tmux 套接字会在 `install` 时被清理**——如果该账号在该套接字上的服务器仍在运行，则会被拒绝并给出说明，而不是让其会话变成孤儿。

### Changed
- **`CLAUDE_ARGS` 默认值改为 `--dangerously-skip-permissions --remote-control`。** root 安装则会得到 `--permission-mode auto --remote-control`；而那个不可能成立的组合（该参数加上 root 会话）会被 `install`、`new` 和 `run` 拒绝，而不是任其无限重生。已有配置不受影响。
- **`WORKDIR`、`CLAUDE_SESSIONS_DIR` 和 `CLAUDE_PROJECTS_DIR` 现在默认取自会话账号的家目录及其 `~/.claude`**，读取自 `passwd` 而非 `$HOME`——在 `sudo` 之下，`$HOME` 是 root 的，这几项原本都会指向错误账号的文件。
- **`install` 需要 `sudo`，而 `attach` 会降级为会话账号**，而不是以 root 身份 attach。
- **`run` 在以错误账号运行时会拒绝启动**，这意味着已安装的 unit 早于当前配置。若仍然启动，会在错误的用户下建立 tmux 服务器和对话。
- **Preflight 仅在以 root 身份运行时才安装 apt 包**；非特权的监管循环现在会指出缺少哪些包、该运行什么命令，而不是让 apt 自身的权限错误直接失败。

### Fixed
- **一个实例曾能够打字进另一个实例的对话里。** 每个 tmux 目标都是裸的会话名，而 tmux 会回退到前缀匹配：当 `claude-code` 和 `claude-code-work` 同时存在时，本应发往前者的命令会落到后者身上——包括 `send-keys`，也就是说 `/remote-control` 和一次裸 Enter 都会打进别人的会话里。现在所有目标都改为精确匹配。
- **`claude-guardian list` 对一个已停止的实例打印了两次 `inactive`**，并把该行剩余部分换到了第二行。

## v0.9.1 — 2026-08-23

### Fixed
- **`claude-guardian attach` 现在可以正常工作了。** 此前它会立即报 `exec: tmux_cmd: not found` 而不是完成 attach：该命令试图把一个内部的 shell 辅助函数当作 `PATH` 上的程序去 `exec`。现在 attach 会正确把你带入该会话的终端，与 `DESIGN.md` 走查文档描述的一致。其他所有命令（`url`、`logs`、`list`……）都未受影响——故障仅限于 `attach`。

## v0.9.0 — 2026-08-21

这个工具最初的承诺——「至少有一个会话始终可用」——此前从未被真正强制执行过。它之所以成立，仅仅是因为 `install` 启用了默认实例，而此后一直没人把它归档。只要归档或停用你的最后一个实例，宿主机重启后就会完全没有对话可用，且不会有任何警告。这次发版从两端把这个承诺变成了实打实的保证。

版本号跳过了 `v0.7.0` 和 `v0.8.0`：这两个版本都在 2026-08-21 发布后又被撤回（见 `DECISIONS.md`），若重用某个可能已被人拉取过的 tag，会让同一个名字对应不同的代码。

### Added
- **一个开机兜底。** 新增的 `claude-guardian-floor.service` 每次开机运行一次：如果根本没有任何实例会启动，它就会创建并启动默认的 `claude-code` 实例。已经有启用实例的宿主机则完全不受影响。由新增设置 `ENSURE_DEFAULT_INSTANCE` 控制，默认开启——如果你希望这类宿主机在什么都没有的情况下启动，可在 `/etc/claude-guardian/config.env` 中将其设为 `0`。注意 `install` 不会改写已有的配置文件，所以升级后该设置不会自动出现在配置里，在你自己添加之前会一直沿用内置默认值。
- **`claude-guardian ensure-floor`**，同一项检查的按需版本——用来修复一台被落下、什么都没运行的宿主机，而不用等下一次重启。
- **`deactivate` 支持 `--yes`**，与 `archive` 保持一致。

### Changed
- **`archive` 和 `deactivate` 在你即将移除开机时唯一会启动的实例时会发出警告**，并在未传 `--yes` 时先询问再执行。该警告会说明下一次开机实际会发生什么，这取决于 `ENSURE_DEFAULT_INSTANCE`。对脚本而言这是一个行为变更：在非交互式 shell 中对 `deactivate <last-instance>` 现在会拒绝而不是直接执行——需传入 `--yes`。停用一个已经被禁用的实例，或停用任何非最后一个的实例，行为不变，依旧静默执行。
- `uninstall` 和 `purge` 现在也会移除开机兜底 unit，因此两者都不会留下一个指向刚被自己删除的二进制文件的 unit。

## v0.6.2 — 2026-08-17

### Fixed
- **v0.6.1 的修复只覆盖了重连计时器被播种的三处中的两处。** 实际最要紧的那一处——循环启动时，也就是每次 `systemctl restart` 和每次开机——仍然被当作「刚刚重连过」来播种，导致重启后的第一次断连要等满整个退避周期才会被处理。这次做了真实验证：一次故意的断连在数秒内就被修复了，隔离测试套件也新增了一个针对 v0.6.1 会失败的用例。

## v0.6.1 — 2026-08-17

### Fixed
- **重启后第一次断连会被立即修复，而不是最多等一分钟。** 重连退避计时器此前被当作「刚刚尝试过重连」来播种，导致一个在 supervisor 刚启动后不久就断连的实例（或者重启后所有实例同时启动的情形）要白白等一段本来毫无保护意义的退避窗口期。这是在对 v0.6.0 做真实测试时发现的：实例创建 40 秒后的一次故意断连，原本要 25 秒才能修复，而不是 5 秒。首次尝试之后的重试不受影响。

## v0.6.0 — 2026-08-17

现在实例会保持可达：一次断连会在数秒内被发现，而不是最多要等二十分钟。supervisor 也不再未经你要求就替你回答确认对话框。这两点都来自把 v0.4.0 投入生产运行一下午所得到的经验。

### Changed
- **断连现在会在数秒内被修复，而不是几分钟。** 连接检查现在每次监管周期（`REMOTE_CONTROL_CHECK_SEC`，默认 5 秒）都会运行，而不是每 20 分钟一次。这项检查本身一直是被动的——只是一次文件读取，不会往会话里打任何字——所以之前那个缓慢的节奏没有带来任何好处，反而让一个实例可能存活却在 claude.ai 一侧无法访问长达 20 分钟。重连尝试则单独限速（`REMOTE_CONTROL_RECONNECT_BACKOFF_SEC`，默认 60 秒），因为重连才是真正会往会话里打字的那部分。
- **无人值守 Enter 默认关闭。** `UNATTENDED_NUDGE_SEC` 现在默认是 `0`。Enter 会直接确认确认对话框当前高亮的选项，而系统没有办法区分「这个会话已被放弃」和「操作者此刻正看着这个对话框、只是还没决定」——v0.4.0 缩小了这个区别，但没能完全消除它，而且确实出现过它替维护者回答了一个真实对话框的情况。要重新启用，把它设成一个具体的秒数即可；启用后 v0.4.0 引入的「仅限 `waiting` 状态」规则依旧适用。
- **`REMOTE_CONTROL_REFRESH_SEC` 已被 `REMOTE_CONTROL_CHECK_SEC` + `REMOTE_CONTROL_RECONNECT_BACKOFF_SEC` 取代。** 配置中若仍设置旧名称，启动时会记一条警告日志，并且该设置会被忽略——请从 `/etc/claude-guardian/config.env` 中删掉那一行。

### Fixed
- 存储的 remote-control URL 现在只在真正发生变化时才会被重写，因此 `remote_url_updated_at` 依旧表示「这个 URL 是何时建立的」，而不会变成一个每五秒刷新一次的心跳时间戳。

## v0.5.0 — 2026-08-17

`claude-session` Agent Skill 现在随本工具一起发布。

### Added
- `skills/claude-session/`，通过 `cp -r skills/claude-session ~/.claude/skills/` 安装。有了它，Claude Code 就能用大白话驱动这些命令——「开一个常驻对话」、「list my sessions」、「give me the link for that one」、「archive this」——而不用你去记 CLI 命令。它同时也带上了针对破坏性命令的规则：`archive` 和 `purge` 会杀掉正在运行的 `claude` 进程，因此该 skill 在你没有明确点名要执行这个动作之前不会执行任何一个，会先展示它即将归档的是哪个实例，并且拒绝把「pause」/「取消激活」理解为结束对话的请求。完全可选。

### Changed
- `bin/claude-guardian.sh` 没有任何变化——supervisor 与 v0.4.0 逐字节相同。本次发版只是这个 skill 本身，以及两份 README 中为它新增的安装说明。

## v0.4.0 — 2026-08-17

重启后的实例现在会接回它原本正在进行的那个对话，无人值守的 Enter 也不再发送给不需要它的会话。这两点都来自生产环境的实际反馈，并且在 v0.3.0 中都被列为已知问题。参见 `DECISIONS.md`，2026-08-17 条目（「跨重启接续对话」和「只 nudge 真正被搁置的会话」）。

### Fixed
- **重启不再丢弃对话。** 此前每次开机都会让每个实例开始一段全新的对话，而先前的对话原封不动地留在磁盘上，只能靠手动执行 `claude --resume` 才能找到。只要该对话的转录文件仍然存在，实例现在就会接回原来的对话。设置 `RESUME_AFTER_RESTART=0` 可恢复旧行为。如果某个对话已无法再被接续，会自动回退到开启一个新对话，而不会让实例卡在不断重生的状态里。
- **无人值守的 Enter 不再打进有人正在使用的会话里。** 此前它单纯按已经过去的时间触发，而 Remote Control 又不是一个 tmux 客户端，因此一个正被 claude.ai 远程操作的会话看起来会像被放弃了一样，其确认对话框就有可能被替操作者回答掉。现在 supervisor 会先向 `claude` 询问该会话实际在做什么，只会向那种已经停在某个确认对话框上、且持续无人回应满 `UNATTENDED_NUDGE_SEC` 的会话打字。

### Changed
- `MAX_SESSIONS` 现在默认是 `0`，即无限制；要恢复上限则设为一个正数。此前它默认是 `3`，读起来像是这个工具本身的硬性限制，而不是它原本要起到的成本护栏作用。已有安装会保留 `/etc/claude-guardian/config.env` 中已存在的任何值。
- `UNATTENDED_NUDGE_SEC` 现在的含义是「一个确认对话框最多可以在无人回应的情况下停留多久才会被清除」，而不再是「这个会话最多可以多久不被碰」。默认值不变（`300`）。
- 新增配置项 `RESUME_AFTER_RESTART` 和 `CLAUDE_PROJECTS_DIR`。两者都有可用的默认值，因此已有的 `config.env` 不需要任何改动；`install` 一如既往地不会改写已有配置。

## v0.3.0 — 2026-08-17

Remote Control 现在在断连时真的会被修复，而实例上报的 URL 也保证一定是它自己的。这两处是如何被发现、以及为何改变思路，见 `DECISIONS.md`，2026-08-17 条目（「从 claude 自身的会话文件读取 Remote Control 状态」）。

### Fixed
- **实例不会再一直断连着，直到有人碰巧注意到。** 无人值守的保活机制此前会按定时器重复运行 `/remote-control`，以为这样就能刷新连接；实际并不会——对于一个已经连接的会话，这个命令只会弹出一个提示对话框。因此一次断连的 Remote Control 连接永远不会被真正修复。supervisor 现在会先检查连接是否真的处于连通状态，只有在确认断开时才会重连。
- **`url` / `list` 有可能报出另一个实例的 URL。** 此前查找 URL 的方式是在终端里搜索任意一个 `claude.ai/code/session_...` 链接，因此哪怕只是恰好出现在屏幕上的一个链接——另一个实例的、某条 commit message 里的、或者被某条命令回显出来的——都可能被误记为当前实例自己的 URL。这个问题在生产环境中被实际观察到过。URL 现在来自该会话自身的状态，终端兜底方案也被限定在 `/remote-control` 命令的输出范围内。
- **supervisor 不再往健康的会话里打字。** Remote Control 不是一个 tmux 客户端，因此一个正被 claude.ai 远程操作的会话看起来像是无人值守的，每隔 `REMOTE_CONTROL_REFRESH_SEC` 就会收到一行作为用户输入发送的 `/remote-control`。现在连接检查只是一次文件读取；只有在确实需要重连时才会发送按键。

### Changed
- `REMOTE_CONTROL_REFRESH_SEC` 现在的含义是「多久检查一次 Remote Control 是否仍然连通」，而不是「多久重新运行一次 `/remote-control`」。默认值不变（`1200`）；它现在限定的是一次断连最多可以多久不被发现。
- `url <name>` 和 `list` 上报的是该实例*当前*的 URL，而不是上一次存储的那个。重连会生成一个新的 URL，所以请在需要时现取，而不要收藏起来；当实例处于断连状态时，`url` 会警告它手上的链接很可能已经失效。

### Added
- `CLAUDE_SESSIONS_DIR`（默认 `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/sessions`）：Claude Code 写入其每会话文件的位置。只读，仅当 Claude Code 使用非默认配置目录时才需要设置。

## v0.2.0 — 2026-08-17

`claude-guardian` 现在监管多个具名、并发的 Claude Code 实例，而不再是只监管唯一一个。原因见 `DECISIONS.md`，2026-08-17 条目。

### Added
- `new <name> [--workdir D] [--args "..."] [--claude-bin PATH]`：创建、启用并启动一个新的并发监管实例。超过 `MAX_SESSIONS`（默认 3）会被拒绝。
- `list`：一张表格，列出每个实例——systemd 状态、tmux 状态、是否有人已 attach、工作目录，以及它捕获到的 remote-control URL。
- `url <name>`：打印已存储的 `claude.ai/code/...` remote-control URL，而不需要 attach。会在实例创建时自动捕获，并在每次无人值守的 `/remote-control` 刷新时重新捕获。
- `activate <name>` / `deactivate <name>`：仅启用+启动 / 禁用+停止监管——无论哪种情况，存活的 tmux 会话都会继续运行，因此暂停监管永远不会中断一段正在进行的对话。
- `archive <name> [--yes]`：先停用，保存完整的滚屏记录和该实例的 `claude` 对话 id，再杀掉 tmux 会话——这是一个刻意的、默认需要确认的破坏性步骤。
- `resume <archive-id> [new-name]`：从一份归档重新创建一个实例，并通过 `claude --resume` 接续其对话。
- `archives` / `rm-archive <id> [--yes]`：列出 / 永久删除已归档的实例。
- 每个实例都以自己的 `claude --session-id`（如果是从归档恢复的则是 `--resume`）创建，因此崩溃后的重生始终会接续同一段对话，而不会悄无声息地开启一段新对话。
- `MAX_SESSIONS` 配置变量限定并发实例数量（默认 `3`）；默认的 `REQUIRED_APT_PKGS` 中新增了 `uuid-runtime`。

### Changed
- systemd unit 现在是一个模板（`claude-guardian@<name>.service`），而不再是单一固定的 unit。`attach`/`logs`/`start`/`stop`/`restart`/`status` 在不带名称参数时依旧都能正常工作，默认指向 `claude-code` 实例，以兼容已有的肌肉记忆式命令。
- 在已有 v0.1.0 的宿主机上运行 `install`，现在会原地把旧的单一 unit 迁移到新的模板，且针对的是同一个存活的 tmux 会话——`KillMode=process` 意味着这次迁移绝不会触碰到正在运行的 `claude` 进程。
- `SESSION_NAME` 不再是一个配置变量——实例名本身*就是* tmux 会话名。
- `purge` 的影响范围从「一个会话」扩大到了「每一个存活实例」：它现在会先报告存活实例的数量，并在继续之前要求交互式确认（或传入 `--yes`），并且刻意从不删除 `/var/lib/claude-guardian/archive/`——要删除归档请显式使用 `rm-archive`。
- `refresh_remote_control`（定期的无人值守重连）现在也会重新捕获并存储该实例的 remote-control URL，并在结束后用一次 Enter 关掉随之出现的屏幕浮层。

## v0.1.0 — 2026-08-16

首个版本。`claude-guardian` 在一台由 root 管理的 Debian 服务器上，让至少一个可远程 attach 的 Claude Code 会话保持存活。

### Added
- `bin/claude-guardian.sh`：一个单文件、自包含的脚本，涵盖 `install`、`uninstall`、`purge`、`start`/`stop`/`restart`/`status`、`attach`、`logs`、`check`，以及 `run`（systemd 的 `ExecStart` 目标）。
- systemd + tmux 双层监管：tmux 会话在 `claude` 因任何原因退出时（Ctrl+C、崩溃、`exit`）都能存活；systemd（`Restart=always`，开机自启）则在 supervisor 自身挂掉或宿主机重启时保持存活。
- 默认启动 `claude --permission-mode auto --remote-control`——可以从网页版 claude.ai 或手机上远程操控，而不仅限于 SSH+tmux。
- 仅在无人值守时生效的保活机制：清除卡住的确认提示，并在 Anthropic 约 30 分钟的断连阈值到来之前主动刷新 Remote Control 连接，使长时间空闲的部署保持可达。可通过 `UNATTENDED_NUDGE_SEC` / `REMOTE_CONTROL_REFRESH_SEC` 配置；文档中将其记为一项明确的安全权衡（见 `DESIGN.md`）。
- Preflight 检查：自动安装缺失的 `apt` 包，要求 `claude` 二进制文件必须已经存在（绝不会自动安装它），并要求 `claude` 在 `install` 继续执行之前已经完成登录（通过 `claude auth status` 检查）。
- `purge` 命令用于彻底拆除（会话、套接字、配置、已安装的二进制文件），与日常维护中安全的 `uninstall` 区分开来。
- 双语 README/DESIGN 文档，GPL-3.0 许可证。

### Fixed
以下几项只有通过真实部署测试（本机以及另一台独立宿主机）才发现，仅靠代码审查并不足以发现：
- `StartLimitIntervalSec` 被放在了错误的 systemd unit 分区里。
- systemd 默认的 `KillMode=control-group` 会在 `stop`/`restart` 时把存活的 tmux 会话一并杀掉——已通过 `KillMode=process` 修复。
- `CLAUDE_BIN` 在 systemd 的最小化 `PATH` 下解析不出来，尽管交互式环境下能正常解析——现在在安装时会固化为一个绝对路径，并为已安装的宿主机提供运行时自愈兜底。
- 无人值守保活计时器在每次重启后会立即触发，而不是等满其配置的间隔时间。
- `usage()` 中一处写死的行号范围，在更早的一次提交于其上方加入许可证头之后被悄悄破坏。
