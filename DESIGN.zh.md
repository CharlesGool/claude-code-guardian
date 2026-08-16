# claude-code-guardian — 设计

[English](DESIGN.md) | **简体中文**

> 译自 `DESIGN.md`（unreleased，对应 commit `a46c2f4`）。如有冲突，以英文版为准。

> 本文档的成败标准：另一个人拿着它，在另一台设备上能把项目重建出来。写的时候假设读者看不到你的机器。

## 目标与非目标

**目标**
- 在 Debian 系服务器上，始终保持恰好一个 `claude`（Claude Code CLI）进程存活，运行在一个可分离的终端复用器会话里，让操作者随时可以远程接管——要么通过 Claude Code 自带的 Remote Control（一个 `claude.ai/code/...` 链接，可在网页或手机上控制），要么通过 SSH + `tmux attach`。
- 扛得住重启（服务开机自启）。
- 扛得住 `claude` 进程本身被杀——Ctrl+C、崩溃、`exit`、OOM kill——几秒内自动重新拉起，且不丢失周围的会话环境。
- 在长时间无人值守的情况下依然保持真正可达，而不只是"进程还在跑"：定期清除 `auto` 权限模式可能回退出现的确认弹窗，并在 Remote Control 连接变得陈旧之前主动刷新它（这里涉及的安全权衡见 Known limitations）。
- 每次启动前都跑前置检查：所需 `apt` 包是否存在（缺失自动装）、`claude` 可执行文件是否存在（硬性要求，绝不自动安装）、尽力而为的登录/凭据检查（仅提示，不阻塞启动）。
- 用一套小巧好记的 CLI（`claude-guardian <动词>`）就能操作。

**非目标**
- 安装或更新 Claude Code CLI 本身。操作者需要自行预先安装并完成身份验证（或者通过本工具管理的会话交互式登录）。
- 从零搭建一套远程访问传输层。本工具依赖 Claude Code 自带的 `--remote-control` 功能作为主要远程通道，并以 SSH 访问宿主机作为兜底；它只负责让 `tmux` 会话保持存活，供两者中任意一个接入。
- 同时运行多个命名的并发 Claude 会话。目前只支持一个默认会话（见 `DECISIONS.md`，2026-08-16）。
- 提供图形界面、Web 仪表盘或通知系统。状态通过 `systemctl status` / `journalctl` 查看。

## 架构

两层各自独立的监督机制，使得"`claude` 进程死了"和"整个监督者死了"这两类故障分别由不同机制兜底：

```
                     监督者自身开机自启 / 崩溃重启
                                    |
                                    v
   systemd (Restart=always) ---> claude-guardian run（前台循环）
                                    |
                                    | 每隔 CHECK_INTERVAL_SEC：
                                    | tmux 会话是否存在？pane 是否已死？是否有客户端接入？
                                    | （若无人接管：按各自更长的间隔 nudge Enter / 刷新 /remote-control，见下文）
                                    v
                     tmux 会话 "claude-code"（remain-on-exit on）
                                    |
                                    v
                    claude --permission-mode auto --remote-control
                                    ^                       ^
                                    |                       |
                        操作者：ssh + `claude-guardian        操作者：claude.ai
                        attach`（tmux attach）                网页/手机（Remote Control）
```

- **systemd 层**兜底：重启、监督脚本自身崩溃、整个 tmux server 消失。`Restart=always` 加上有上限的 `StartLimitBurst`，避免 `claude` 确实缺失时无限重启（见 Known limitations）。设置了 `KillMode=process`，使得 `stop`/`restart` 只信号被追踪的循环 PID，绝不波及 tmux server 或 `claude`（这是实测验证过的——systemd 默认的 `KillMode=control-group` 会把整个会话一起杀掉，所以这里必须显式写明，不能留给 systemd 默认值）。
- **tmux 层**兜底：`claude` 进程本身因任何原因退出，而*会话*（其滚动记录、其 pty）被保留下来。这正是为什么可以放心在会话里发 Ctrl+C 而不丢失状态——只有 `claude` 退出并被重新拉起，tmux 会话本身不受影响。（备注：Claude Code 自身把单次 Ctrl+C 当作"打断当前轮次"，而不是退出——要连按两次，或者输入 `/exit`，才会真正终止进程；这是对着真实二进制验证过的。）
- **无人值守保活机制**（见 `DECISIONS.md` 2026-08-16 "始终可远程控制"）：当 `tmux list-clients` 显示无人接入时，循环会定期 (a) 发送 Enter——间隔一秒发两次——清除 `--permission-mode auto` 在多次被分类器拦截后可能回退出现的确认弹窗；(b) 重新执行 `/remote-control` 刷新连接，抢在 Anthropic 文档所述的约 30 分钟"无法连接到 Remote Control 服务器"阈值被真正触发之前。这两者一旦有客户端接入就立刻停止（每个 tick 都会检查）。`create_session` 在启动 `claude` 之后也会发送同样的两次 Enter，原因一样：真正第一次运行时可能出现引导/信任确认界面，需要按两次 Enter 才能清掉，不应该非要等到第一次无人值守 nudge 的间隔才处理。如果 `claude` 已经在正常的输入提示符上，多按一次 Enter 也是无害的空操作——所以干脆总是发两次，而不是费力去判断当前到底是哪个界面。
- 这两层是刻意独立的：`systemctl stop claude-guardian` 只停止*监督循环*本身，不会杀掉存活的 tmux 会话，因此一次日常运维操作不会打断正在对话中的操作者。彻底拆除是一个单独的、显式的步骤——`uninstall`（只动 systemd，配置和会话不受影响，用于日常运维）对比 `purge`（全部清除：会话、socket、配置目录、已安装的二进制——一个明确的、刻意的"全部移除"命令，见 README）。

## 技术栈

| 层 | 选型 | 版本 | 原因 |
|---|---|---|---|
| 进程监督者 | systemd | （Debian 默认） | 每台目标系统上都已经有；原生支持开机自启和重启策略，不需要额外再照看一个守护进程。 |
| 会话复用器 | tmux | Debian 稳定版软件包 | 有可脚本化的存活信号（`#{pane_dead}`）和 `respawn-pane`，不像 `screen` 那样需要轮询进程表。 |
| 实现语言 | 类 POSIX Bash | bash（Debian 默认的 `/bin/bash`） | 整个工具就是进程编排，外加对 `tmux`/`systemctl`/`apt-get` 的调用；换一个脚本运行时只会多引入一个依赖，没有任何好处。 |

被否决的替代方案及其理由都记在 `DECISIONS.md` 里——这里不重复。

## 复现要求

### 环境

- 操作系统：Debian 或其衍生发行版（Ubuntu 等），PID 1 是 `systemd`，有 `apt`/`dpkg`。
- 运行时：`bash`（默认已有）、`tmux`（前置检查会在缺失时自动装）。
- 权限：必须以 root 运行——它要管理一个系统级 systemd unit、安装 apt 包、写入 `/etc` 和 `/run`。
- 硬件：几乎可忽略；就是一个每隔几秒醒一次的空闲 bash 循环。
- 依赖恢复命令：无——本项目没有包管理器依赖，只有 `bin/` 下的这一个 shell 脚本。

### 外部依赖

| 项目 | 来源 | 存放位置 |
|---|---|---|
| `claude`（Claude Code CLI） | 由操作者预先安装并完成身份验证——本工具不负责安装它 | root 用户 `PATH` 上的任意位置，或者把 `CLAUDE_BIN` 指向一个绝对路径 |

### 路径与挂载点

下面每一个路径都可以在 `/etc/claude-guardian/config.env`（由 `claude-guardian install` 首次运行时写入）里配置；脚本里不写死任何一个。

| 路径 | 由谁提供 | 用途 |
|---|---|---|
| `/etc/claude-guardian/config.env` | 本工具，首次 `install` 时 | 运行时配置（见下文） |
| `/etc/systemd/system/claude-guardian.service` | 本工具，`install` 时 | systemd unit 定义 |
| `/usr/local/bin/claude-guardian` | 本工具，`install` 时（从 `bin/claude-guardian.sh` 拷贝而来） | 安装好的 CLI 入口 |
| `$TMUX_SOCKET`（默认 `/run/claude-guardian/tmux.sock`） | 本工具，运行时创建 | 专用的 tmux server socket，与任何交互式管理员自己在 `/tmp` 上的 tmux server 隔离 |
| `$WORKDIR`（默认 `/root`） | 操作者，通过配置指定 | `claude` 启动时的工作目录 |

### 配置参考

所有变量都存在 `/etc/claude-guardian/config.env` 里，是一个纯 `KEY="value"` 的 shell 文件，由脚本 source。仓库里的 `.env.example` 记录了同样的默认值作为参考（本项目没有独立的应用层 `.env`——安装好的这个配置文件本身就是运行时配置）。

| 变量 | 含义 | 默认值 | 必填 |
|---|---|---|---|
| `SESSION_NAME` | 承载 `claude` 的 tmux 会话名 | `claude-code` | 否 |
| `TMUX_SOCKET` | 专用 tmux server 的 socket 路径 | `/run/claude-guardian/tmux.sock` | 否 |
| `WORKDIR` | `claude` 启动时的工作目录 | `/root` | 否 |
| `CLAUDE_BIN` | `claude` 可执行文件名或绝对路径 | `claude` | 否 |
| `CLAUDE_ARGS` | 每次（重）启动时传给 claude 的额外参数 | `--permission-mode auto --remote-control` | 否 |
| `CHECK_INTERVAL_SEC` | 存活检查的间隔秒数 | `5` | 否 |
| `REQUIRED_APT_PKGS` | 缺失时自动安装的 apt 包（空格分隔） | `tmux` | 否 |
| `UNATTENDED_NUDGE_SEC` | 仅无人接管时：无接入的 tmux 客户端持续这么多秒后发送裸 Enter 清除卡住的确认弹窗；`0` 关闭 | `300` | 否 |
| `REMOTE_CONTROL_REFRESH_SEC` | 仅无人接管时：无接入的 tmux 客户端持续这么多秒后重新执行 `/remote-control` 刷新连接；`0` 关闭 | `1200` | 否 |

## 从零搭建

1. 在目标 Debian 服务器上以 root 身份克隆仓库（克隆 tag，不要克隆分支尖端）——验证：`git clone ...` 退出码为 0，且 `bin/claude-guardian.sh` 存在。
2. `bash bin/claude-guardian.sh check`——验证：打印出三个检查区块（`apt dependencies`、`claude CLI`、`login state`），带有 `[ok]`/`[missing]`/`[warn]` 标记，且不做任何改动。
3. `bash bin/claude-guardian.sh install`——验证：以 `install complete` 结尾；`systemctl is-enabled claude-guardian` 输出 `enabled`。
4. `claude-guardian start`——验证：`systemctl is-active claude-guardian` 输出 `active`。
5. `claude-guardian attach`——验证：把你带进 tmux 里一个实时的 `claude` 终端，且该 pane 显示一行 `/remote-control is active ... https://claude.ai/code/session_...`——这个链接可以在网页或手机上控制，独立于这个 SSH 会话。退出用 tmux 前缀键（默认 `Ctrl+b`）再按 `d`——**不要**用 Ctrl+C。
6. 从第二个终端，真正退出会话里的 `claude`，验证自动重新拉起——例如 `tmux -S /run/claude-guardian/tmux.sock send-keys -t claude-code C-c C-c`（Claude Code 把单次 Ctrl+C 当作"打断当前轮次"，跟大多数 REPL 一样，要快速连按两次才会真正退出，等同于输入 `/exit`）。验证：`CHECK_INTERVAL_SEC` 内 `claude-guardian logs` 出现一行 `respawning automatically`，`claude` 的 PID（`pgrep -f 'claude --permission-mode'`）已经变化，再次 `claude-guardian attach` 能看到一个存活的会话（带一个新的 remote-control 链接）。
7. `systemctl stop claude-guardian`，然后检查 `pgrep -f 'claude --permission-mode'`——验证：进程仍在运行（stop 只是暂停监督，见 Known limitations 里关于 `KillMode` 的说明）。再执行 `claude-guardian start`——验证：还是同一个 `claude` PID（监督恢复对已有会话的监视，而不是重新创建）。
8. 分离会话，无人值守超过 `UNATTENDED_NUDGE_SEC`——验证：`claude-guardian logs` 在到点时出现一行 `sending Enter in case a prompt is stuck`，超过 `REMOTE_CONTROL_REFRESH_SEC` 后出现一行 `refreshing remote control connection`，且在你重新 attach 再分离一次之后，这两者不会立刻再次触发（定时器在有客户端接入时会重置）。
9. `reboot` 宿主机——验证：开机后 `systemctl is-active claude-guardian` 自动变回 `active`，不需要人工干预。

本项目不使用 Docker 部署；以上步骤就是完整的部署流程。

## 数据模型 / 文件布局

```
repo/
├── bin/claude-guardian.sh   # 整个工具——自包含，没有其他源码文件
├── README.md / README.zh.md
├── DESIGN.md / DESIGN.zh.md
├── .env.example             # 记录 config.env 的各个变量（见 Configuration reference）
└── ...
```

仓库里没有单独签入的 systemd unit 文件或配置模板：`claude-guardian install` 会从 `bin/claude-guardian.sh` 里内嵌的 heredoc 生成这两者，所以这一个文件本身就是一个完整、自包含的部署产物——拷贝到任何地方跑一下 `install` 就够了，不需要仓库的其余部分。

## 已知限制与坑

- **`UNATTENDED_NUDGE_SEC`（自动按 Enter）是一个刻意做出、已经明确经用户确认的安全权衡，不是一个中性的便利功能。** `--permission-mode auto` 在分类器连续拦截 3 次（或累计拦截 20 次）后会回退到交互式确认——这个兜底机制存在的意义就是让人来对分类器无法自动清除的情况做判断。无人值守时发送一个裸 Enter，会接受当前高亮/默认的那个选项，**但并不知道那个默认选项对那个具体的弹窗来说是不是安全的选择。** 这一点在 guardian 第一次尝试以这个行为重启时，被 Claude Code 自己的 auto-mode 分类器当场拦截并标记出来（"绕过了人工确认的安全兜底"），部署前需要用户明确确认（见 `DECISIONS.md`，2026-08-16）。如果这个权衡在某次部署里不可接受，把 `UNATTENDED_NUDGE_SEC` 设为 `"0"` 即可关闭——文档记载的替代方案是 `--permission-mode dontAsk` 配合显式的 `permissions.allow` 名单，未在名单里的操作会被静默拒绝而不是去猜一个确认弹窗（更可预测，但前期配置工作更多）。
- **`claude-guardian install` 会非交互式地自动安装缺失的 apt 包**（`DEBIAN_FRONTEND=noninteractive apt-get install -y`）。默认情况下只有 `tmux`。如果你扩大了 `REQUIRED_APT_PKGS`，请先想清楚你在无人值守的情况下要求它装的是什么。
- **`claude` 可执行文件缺失时，服务会失败重启循环大约一分钟，然后停止。** `preflight_enforce` 在找不到 `claude` 时会硬性失败（这是设计如此——本工具绝不负责安装它）。unit 里的 `StartLimitBurst=10` / `StartLimitIntervalSec=60` 会阻止 systemd 无限重启；之后服务会停在 `failed` 状态，直到你装好 `claude` 并执行 `systemctl reset-failed claude-guardian && systemctl start claude-guardian`。
- **`systemctl stop claude-guardian` 不会杀掉存活的会话——这需要在 unit 里显式写 `KillMode=process`，并且是对着真实二进制验证过的。** systemd 的*默认* `KillMode` 是 `control-group`，会在 stop/restart 时对整个 cgroup 发 SIGTERM，包括 tmux server 和 `claude` 本身（这是实测抓到的：unit 最初版本没有显式写 `KillMode`，一次 `systemctl restart` 就悄悄把会话杀掉又重建了）。用了 `KillMode=process` 之后，只有被追踪的循环 PID 会收到信号，所以 `claude` 和它的 tmux 会话能扛过监督者的一次 `stop`/`restart`。一个副作用：systemd 会在下一次 `start` 时打印一条无害的 `Found left-over process ... in control group` 提示，因为之前的 `claude` 进程还留在那个 cgroup 里——这是预期行为，不是错误。要彻底拆除，执行 `claude-guardian purge`（或手动执行：`tmux -S $TMUX_SOCKET kill-session -t $SESSION_NAME`）。
- **退出请用 tmux 前缀键，不要用 Ctrl+C——而且单次 Ctrl+C 本来就杀不死 `claude`。** 对着真实 CLI 验证过：Claude Code 把单次 Ctrl+C 当作"打断当前轮次"（跟大多数 REPL 一样），而不是退出——pane 会继续存活，也不会触发任何重新拉起。要连按两次 Ctrl+C（或者 `/exit`）才会真正终止进程，此时 pane 才会死掉，guardian 才会把它重新拉起来——这正好对应最初的需求：手动杀掉也必须保证还有实例在跑。不管需要按几次 Ctrl+C 才能退出，它都不是一种干净的"离开会话"方式——请始终使用 tmux 前缀键 + `d`。
- **如果你的工作副本位于挂载参数固定了 `file_mode` 的 CIFS/SMB 文件系统上（NAS 挂载的开发环境常见这种情况），对 `bin/claude-guardian.sh` 执行 `chmod +x` 可能是静默无效的**（退出码 0，权限位没有变化——开发过程中实际遇到过）。可执行位改为在提交时直接写进 git 树：`git update-index --chmod=+x bin/claude-guardian.sh`，所以在支持真实权限位的文件系统上正常 `git clone` 出来的文件都会是可执行的，不受影响。如果你本地的工作副本没法保留可执行位，请显式用 `bash bin/claude-guardian.sh ...` 而不是 `./bin/claude-guardian.sh`。
- **登录状态从不被强制要求。** 如果 `claude` 没有有效凭据，会话依然会启动；`claude` 自己会在第一次有人 attach 时显示它正常的交互式登录流程。前置检查只会记一条警告日志，让操作者心里有数。
- **`REMOTE_CONTROL_REFRESH_SEC` 默认 1200 秒是基于已有文档做出的主动预防性猜测，不是对某个已知精确阈值的复现。** Anthropic 的文档里写的是，一个"无法连接到 Remote Control 服务器持续约 30 分钟"的会话需要手动执行一次 `/remote-control` 才能重连；至于一个网络本身健康、只是长期无人操作的会话是否会按自己的节奏变得陈旧，在做这个功能的调研时被明确标记为文档未覆盖、无法确认。不管怎样，20 分钟去刷新，都稳稳落在文档所述的 30 分钟失败窗口以内。
- **无人值守 nudge/refresh 这两个定时器，只从监督循环本身（重新）启动的那一刻开始计时，而不是从会话真正最后一次有人接管的时刻开始。** 这是一个实测抓到的真实 bug：最初的版本把两个定时器都初始化为 `0`（epoch），导致任何一次针对已经无人值守的会话执行的 `systemctl restart`，都会立刻触发一次多余的 nudge 和 refresh，而不是先等满配置的间隔。修复方式是让两个定时器都在循环启动时用当前时间做种子。

## 如何扩展

- **新增前置检查**：同时改 `preflight_report`（只报告，不改动）和 `preflight_enforce`（可能改动系统状态 / 硬性失败）——保持两者同步，这样 `check` 才能准确预览 `run`/`install` 实际会做的事。
- **支持一个以上的命名会话**：意味着要把 systemd unit 改成模板（`claude-guardian@%i.service`），以会话名为 key，配置放在 `/etc/claude-guardian/<name>.env`。目前刻意没有做（见 `DECISIONS.md`，2026-08-16）——只有在真的出现并发会话的实际需求时才加，不要提前做。
- **新增配置变量**：同时扩展 `bin/claude-guardian.sh` 顶部的默认值区块和 `write_default_config` 里的 heredoc，再在本文档的 Configuration reference 表格和 `.env.example` 里各加一行。
