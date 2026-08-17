# claude-code-guardian — 设计文档

[English](DESIGN.md) | **简体中文**

> 译自 `DESIGN.md`（v0.6.0）。如有冲突，以英文版为准。

> 本文档的成败标准：另一个人，在另一台机器上，能照着它把这个项目重建出来。写的时候假设读者看不到你的机器。

## 目标与非目标

**目标**
- 在 Debian 系服务器上，并发地常驻一个或多个命名的 `claude`（Claude Code CLI）实例，每个都跑在自己的可分离终端复用会话里，让操作者随时可以从远程接管其中任意一个——既可以通过 Claude Code 自带的 Remote Control（一个 `claude.ai/code/...` 链接，可在网页或手机上控制），也可以走 SSH + `tmux attach`。这为什么会取代最初的单会话设计，见 `DECISIONS.md`，2026-08-17。
- 让每个实例的远程控制链接都能在不接管它的情况下取到——创建时自动捕获，之后每次无人值守的刷新也会捕获，按实例存下来，由 `list`/`url` 打印。这样做的意义在于：操作者可以完全从另一个驱动这个工具 CLI 的 Claude Code 会话里创建、发现、接入一个会话，永远不需要自己的终端。
- 让实例可以被**暂停**（`deactivate`/`activate`：停止/恢复监督，tmux 会话继续跑），这与被**归档**（`archive`/`resume`：保存滚动记录和对话 id，再杀掉进程；之后用 `claude --resume` 重建）是两件刻意区分开的、影响范围完全不同的操作。
- 扛得住重启（每个被启用的实例的 service 都会开机自启）。
- 扛得住 `claude` 进程本身被杀——Ctrl+C、崩溃、`exit`、OOM kill——在几秒内自动重启它，且不丢失周围的会话。
- 在长时间无人值守的情况下依然保持真正可达，而不只是"进程还在跑"：在几秒内发现掉线的 Remote Control 连接并修复它，让一个实例不会出现「活着但够不着」超过一个 tick 的情况。清除 `auto` 权限模式回退出现的确认弹窗这件事也仍然提供，但默认关闭——回答一个弹窗是在做决定，而这个工具的职责到「保持会话可达」为止（见 Known limitations）。
- 跑前置检查：确认所需的 `apt` 包已就位（缺失则自动安装）、`claude` 二进制已就位（硬性要求，永远不会自动安装）。登录状态通过 `claude auth status` 检测（这是权威判断，不是靠猜文件是否存在）——`install`/`new` 如果未登录会拒绝继续（一个从未登录过的实例只会白白重启一个没人能用的会话），而 `run` 只会警告，这样一个后来丢失登录状态的实例会继续重试，而不是直接拒绝启动。
- 对资源/成本增长提供一道护栏，但不强加：并发实例数达到 `MAX_SESSIONS` 后，`new` 会拒绝——每个实例都是一个独立的 `claude` 进程，也是一份独立的 token 花费。默认值是 `0`（不限制），因为一个操作者想同时开多少段对话是工作流层面的决定，不是这个工具能猜出来的；这个旋钮是留给确实想设上限的人的。
- 用一套小巧、好记的 CLI 来操作（`claude-guardian <动词> [<name>]`）。

**非目标**
- 安装或更新 Claude Code CLI 本身。操作者需要自行安装并完成认证（或者通过本工具管理的某个会话交互式完成认证）。
- 从零搭建一套远程访问传输层。本工具依赖 Claude Code 自带的 `--remote-control` 功能作为主要的远程路径，并假定 SSH 可作为兜底；它只负责让 `tmux` 会话保持存活，供两者接入。
- 提供用于远程管理实例的生命周期控制 API（HTTP/REST 或其他形式）。生命周期管理只走 CLI，要么通过 SSH，要么从本工具自己管理的某个 Claude Code 会话内部驱动（见 `DECISIONS.md`，2026-08-17，"Rejected"）。
- GUI、网页看板或通知系统。状态通过 `claude-guardian list` / `systemctl status` / `journalctl` 查看。

## 架构

每个命名实例都跑着和最初单会话设计一样的两层独立监督，只是按实例名参数化了——每个 `claude-guardian <name>` 对应一个 systemd unit 实例和一个 tmux 会话，所有 tmux 会话共用同一个 tmux 服务器：

```
                     boot / crash of one instance's supervisor
                                    |
                                    v
   systemd (Restart=always) ---> claude-guardian run <name>  (foreground loop)
   claude-guardian@<name>.service    |
   (one instance per name,           | every CHECK_INTERVAL_SEC:
    from a template unit)            | tmux has-session? / pane_dead? / client attached?
                                      | (if unattended: check every tick that
                                      |  Remote Control is still connected and
                                      |  reconnect it if not; optionally, and
                                      |  off by default, clear a dialog nobody
                                      |  answered — see below)
                                      v
                     tmux session "<name>" (remain-on-exit on)
                     — one of possibly several, all on the same
                       tmux server / $TMUX_SOCKET
                                    |
                                    v
        claude --permission-mode auto --remote-control --session-id <uuid>
        (or --resume <uuid> instead of --session-id: an instance created
         via `claude-guardian resume <archive-id>`, or one coming back
         from a reboot onto the conversation it already had)
                                    ^                       ^
                                    |                       |
                        operator: ssh + `claude-guardian     operator: claude.ai
                        attach <name>` (tmux attach)          web/phone (Remote Control) —
                                                               URL read from claude's own
                                                               session file and stored, so
                                                               `claude-guardian url <name>`
                                                               prints it without ever
                                                               attaching
```

- **systemd 层**负责从以下情况恢复：重启、某个实例的监督脚本崩溃、该实例 tmux 服务端状态消失。`Restart=always` 加上有上限的 `StartLimitBurst`，防止 `claude` 真的缺失时无限重启（见 Known limitations）。`KillMode=process` 使得 `stop`/`restart`/`deactivate` 只信号给被跟踪的循环 PID，绝不波及 tmux 服务器或 `claude`（这一点是实测验证过的——systemd 默认的 `KillMode=control-group` 会把整个会话一起杀掉，所以这里必须显式设置，不能留给系统默认值）。因为它是一个*模板* unit（`claude-guardian@.service`），每个实例都是一个独立的 systemd unit 实例（`claude-guardian@work.service`、`claude-guardian@personal.service`……），可以单独启动、停止、启用或禁用，互不影响。
- **tmux 层**负责从以下情况恢复：`claude` 进程本身因任何原因退出，而*会话*（其滚动记录、其 pty）被保留下来。这正是为什么在会话里发 Ctrl+C 是安全的、不会丢状态——只有 `claude` 退出并被重新拉起，tmux 会话本身始终存活。（注：经对真实二进制验证，Claude Code 把单次 Ctrl+C 视为"中断当前这一轮"，而不是退出——要连按两次，或者输入 `/exit`，才会真正终止进程。）所有实例共用一个 tmux 服务器（一个 `$TMUX_SOCKET`），每个实例一个以实例名命名的会话——tmux 原生就支持多会话复用，所以每个实例单独起一个服务器只会增加运维负担而没有任何好处（见 `DECISIONS.md`，2026-08-17）。
- **会话身份**：创建时，每个实例要么拿到一个全新的 `claude --session-id <uuid>`（通过 `uuidgen` 生成），要么拿到一个指向已有对话的 `claude --resume <uuid>`。无论哪种情况，这个 id 都会被固化进 tmux pane 的原始启动命令里，所以每次崩溃后的 `respawn-pane` 都会自动复用同一个 id——一次重生延续的是同一段对话，绝不会悄悄分叉出一段新的。这个 id 会记录在按实例区分的状态文件里（`/var/lib/claude-guardian/state/<name>.state`），这样 `archive` 能保存它、`resume` 能复用它，实例本身也能在重启之后找回同一段对话。
- **在重启之后保住对话**：`respawn-pane` 只覆盖 `claude` 死掉、而它的 tmux 会话还活着的情况。一次重启会把整个 tmux 服务器一起带走，会话得从零重建——而在 v0.4.0 之前，这意味着每次开机都是一段崭新的空对话，之前那段虽然还留在磁盘上，却只能靠手工才能找回来。现在 `create_session` 会按以下顺序优先选择：一个显式的 `RESUME_SESSION_ID`（由 `resume <archive-id>` 设置）；实例自己状态里最近一次的 `claude_session_id`，前提是 `RESUME_AFTER_RESTART=1` 且它的 transcript 还在磁盘上；否则用 `uuidgen` 新生成一个 id。transcript 检查是让这套机制诚实的关键——它区分的正是"继续那段对话"和"把一个 `claude` 压根没听说过的 id 塞给它"。如果 `claude` 仍然拒绝这次恢复，它会立刻退出；与其让监督循环每隔 `CHECK_INTERVAL_SEC` 就把那条注定失败的命令重建一遍、永无止境，`create_session` 会在发现一次会话已死（或已消失）之后，改用一段新对话重试。
- **无人值守保活**（见 `DECISIONS.md` 2026-08-16 "always remotely controllable"）：当 `tmux list-clients` 显示某个实例的会话无人接管时，它的循环会（a）检查 Remote Control 是否仍处于连接状态，若已断开则重新连上；以及（b）——仅当操作者把 `UNATTENDED_NUDGE_SEC` 设成大于 `0` 的值主动开启后——发送 Enter，间隔一秒发两次，清除一个没人回答的确认弹窗。只要有客户端接管，两者都会立即停止（每个 tick 都会检查一次）。这两件事跑在完全不同的时钟上，而 v0.6.0 刻意把它们拆开是有原因的（见 `DECISIONS.md`，2026-08-17，"watch the connection on every tick"）：（a）是被动的——只读一个文件，不敲任何键——所以它每 `REMOTE_CONTROL_CHECK_SEC`（默认 5 秒，也就是每个 tick）跑一次，因为掉线从 claude.ai 上是看不出来的，而掉线的每一秒都是操作者够不着一个本来好端端的会话的一秒。只有重连会敲键，它由 `REMOTE_CONTROL_RECONNECT_BACKOFF_SEC`（默认 60 秒）单独限速。（b）按定义就是要敲键、要替操作者做决定，所以默认关闭。对它来说，"无人接管"是必要条件但不充分：循环还会问 `claude` 这个会话正在干什么，只有对一个确实停在弹窗上的会话才会敲键——见下文**什么时候才允许 nudge 敲键**。`create_session` 在启动 `claude` 之后仍然会发送同样的双击 Enter，且不受这个开关影响：一次真正的首次运行可能会出现需要两次 Enter 才能清除的引导/信任屏幕，而那时还不存在任何会被这次 Enter 影响到的对话内容——然后它会同步记录一次链接，这样 `new` 就能立刻打印出来，不用等最多 `REMOTE_CONTROL_CHECK_SEC` 那么久。如果 `claude` 此时已经在正常的提示符上，多发一次 Enter 也只是一次无害的空操作，所以与其去检测到底显示的是哪个屏幕，不如始终发两次。
- **"是否还连着"这个问题是怎么回答的**（见 `DECISIONS.md`，2026-08-17，"read claude's session file"）：Claude Code 会为每个正在运行的会话在 `$CLAUDE_SESSIONS_DIR`（`${CLAUDE_CONFIG_DIR:-$HOME/.claude}/sessions`）下写一个 JSON 文件，文件名就是该会话的 PID，其中的 `bridgeSessionId` 字段在连接期间保存 Remote Control 会话 id，一旦断开就变成 `null`。一个实例的 `claude` *就是*它的 tmux pane 命令，所以 `#{pane_pid}` 直接就指出了文件名。读这个文件同时回答了两个问题："Remote Control 还在线吗？"和"当前的 `claude.ai/code/...` 链接是什么？"，而且完全不用往会话里敲任何东西——这一点很关键，因为此刻很可能正有人通过 Remote Control 在这个会话里干活；Remote Control 不是一个 tmux 客户端，所以一个正在被使用的实例在这里看起来仍然是无人值守的。文件是按文本匹配解析的（不依赖 `jq`/`python`），并且会和实例自己的 `pid` 以及被跟踪的 `claude_session_id` 交叉核对，这样一个被复用的 PID 就不会把别人的会话交回来。只有重连这一步会发送按键：`/remote-control` 在 Remote Control 关闭时把它打开，而在已经开着的时候只是弹出一个信息性对话框（"Disconnect this session" / "Show QR code" / "Continue"），末尾补一个 Escape 就能关掉，什么都不会选中。**对一个自认为还连着的会话重新执行 `/remote-control`，什么都刷新不了**——v0.2.0 的保活机制整个建立在这个错误假设之上，这也是现在要先检查再动手的原因。
- **什么时候才允许 nudge 敲键**（见 `DECISIONS.md`，2026-08-17，"nudge only a session that is actually parked" 与 "stop answering dialogs by default"）：首先，只有在操作者主动开启之后——`UNATTENDED_NUDGE_SEC` 默认为 `0`，在 `0` 的情况下，任何正在运行的会话都不会收到 Enter，没有例外。开启之后，同一个会话文件里还带着一个 `status` 字段，循环是照着它来 nudge 的，而不是照着墙上时钟。它有三个取值，三个都在 2.1.202 上实地观察到了：`busy`（正在处理一轮）、`idle`（停在一个空提示符上）、`waiting`（停在一个确认弹窗上）。只有 `waiting` 才构成发送 Enter 的理由，而且还要它保持这个状态满 `UNATTENDED_NUDGE_SEC`——这个时长是从 `statusUpdatedAt` 读出来的，所以倒计时从弹窗出现的那一刻开始算，而不是从监督进程碰巧看了一眼的时刻算。其他情况一律不碰，这才终于让一个有人正在从 claude.ai 上驱动的会话变得安全：它没有 tmux 客户端，所以看起来像被遗弃了，但它读出来是 `busy` 或 `idle`，除非真的有个弹窗没人回答，否则永远不会是 `waiting`。`updatedAt` 是最先试过并被否决的：它跟踪的是状态*转换*，所以一个已经忙了二十分钟的会话，其时间戳仍然是二十分钟前的，读起来就像被遗弃了（这是在维护者自己那个正处于处理中的实时会话上观察到的）。当找不到可用的会话文件时，循环会退回到 v0.2.0 的行为，仅凭经过的时间来 nudge。
- 两层监督在每个实例内部都是刻意独立的：`claude-guardian deactivate <name>`（即 `systemctl disable --now`）只会停掉该实例的*监督循环*；它不会杀掉其存活的 tmux 会话，所以一个正在对话中的操作者不会被例行维护打断——`activate <name>` 会针对同一个仍在运行的会话恢复监督。彻底结束单个实例是另一个独立的、明确的、破坏性的步骤：`archive <name>`（见下文）。而彻底拆除*整个工具*则是 `uninstall`（只动 systemd 模板，每个实例的配置/会话都保持不动）相对于 `purge`（一切都清：每个会话、socket、每份配置、安装的二进制文件——但绝不碰 `/var/lib/claude-guardian/archive/`，见 README）。
- **归档 / 恢复**：`archive <name>` 先停止监督，把完整的滚动记录（`tmux capture-pane -pS -`）和该实例的 `claude_session_id` 保存到 `/var/lib/claude-guardian/archive/<name>-<ts>/`，然后杀掉 tmux 会话——这是一个刻意的、默认需要确认的破坏性操作（见 `DECISIONS.md`，2026-08-17，"archive kills the process"）。`resume <archive-id> [new-name]` 会带着设好的 `RESUME_SESSION_ID` 从那个归档重建一个实例，使得 `create_session` 传的是 `--resume <uuid>` 而不是重新铸造一个新的——操作者就此接回同一段对话。

## 技术栈

| 层 | 选型 | 版本 | 为什么 |
|---|---|---|---|
| 进程监督器 | systemd | （Debian 默认） | 每个目标操作系统上都已自带；原生的开机集成和重启策略，不需要额外照看一个守护进程。 |
| 会话复用器 | tmux | Debian 稳定版软件包 | 有可脚本化的存活信号（`#{pane_dead}`）和 `respawn-pane`，不像 `screen` 那样需要轮询进程表。 |
| 实现语言 | 类 POSIX 的 Bash | bash（Debian 默认的 `/bin/bash`） | 整个工具就是进程编排，外加对 `tmux`/`systemctl`/`apt-get` 的调用；引入一个脚本运行时不会带来任何好处，只会多一个依赖。 |

被否决的方案以及每个选型背后的理由都记录在 `DECISIONS.md` 里——这里不重复。

## 复现要求

### 环境

- 操作系统：Debian 或其衍生发行版（Ubuntu 等），`systemd` 作为 PID 1，`apt`/`dpkg` 可用。
- 运行时：`bash`（默认自带）、`tmux`（前置检查缺失时自动安装）。
- 权限：必须以 root 运行——它管理一个系统级 systemd unit，安装 apt 包，并写入 `/etc` 和 `/run`。
- 硬件：可忽略不计；一个每隔几秒醒一次的空闲 bash 循环。
- 依赖恢复命令：无——本项目没有包管理器依赖，只有 `bin/` 下的这一个 shell 脚本。

### 外部依赖

| 项目 | 来源 | 放置位置 |
|---|---|---|
| `claude`（Claude Code CLI） | 由操作者预先安装并完成认证——本工具不负责安装它 | root 的 `PATH` 上任意位置，或将 `CLAUDE_BIN` 指向其绝对路径 |
| `uuidgen`（`uuid-runtime` 软件包） | 缺失时由前置检查自动安装，和 `tmux` 一样 | 每次创建/恢复实例时用一次，用来铸造或复用一个 `claude --session-id`/`--resume` 的值 |
| Claude Code 的按会话文件（`$CLAUDE_SESSIONS_DIR/<pid>.json`，字段 `bridgeSessionId`、`status`、`statusUpdatedAt`） | 会话运行期间由 `claude` 自己写出——没有什么要安装的 | 读它来判断某个实例的 Remote Control 是否还连着、取得它当前的 `claude.ai/code/...` 链接，以及判断它是在干活、空闲，还是停在一个确认弹窗上。已针对 Claude Code **2.1.202** 验证；这是内部细节，不是有承诺的接口，别的版本可能不提供——那时工具会退回到从终端读取链接，以及按墙上时钟 nudge（见「已知局限」） |
| Claude Code 的对话 transcript（`$CLAUDE_PROJECTS_DIR/<slugged-workdir>/<session-id>.jsonl`） | 由 `claude` 自己写出——没有什么要安装的 | 在重启之后恢复一段对话前，会检查它是否存在；目录名就是工作目录，其中每一个不在 `[A-Za-z0-9]` 范围内的字符都被替换成 `-`。已针对 **2.1.202** 验证，注意事项同上：找不到只是意味着会开一段新对话 |

### 路径与挂载

下面每一个路径都只能通过 `bin/claude-guardian.sh` 顶部附近的常量来配置（不是运行时配置——这些是部署拓扑，不是按实例的行为）；脚本其他地方都没有硬编码。

| 路径 | 由谁提供 | 用途 |
|---|---|---|
| `/etc/claude-guardian/config.env` | 本工具，首次 `install` 时 | 全局运行时配置，由每个实例共享（见下文） |
| `/etc/claude-guardian/instances/<name>.env` | 本工具，`new`/`resume` 时 | 按实例的覆盖项：`WORKDIR`、`CLAUDE_ARGS`、`CLAUDE_BIN`，以及（如果是恢复出来的）`RESUME_SESSION_ID` |
| `/etc/systemd/system/claude-guardian@.service` | 本工具，`install` 时 | systemd **模板** unit——每个正在运行的实例对应一个 `claude-guardian@<name>.service` 实例 |
| `/var/lib/claude-guardian/state/<name>.state` | 本工具，运行时 | 按实例的运行时状态：`claude_session_id`、`workdir`、`created_at`、`remote_url`、`remote_url_updated_at` |
| `/var/lib/claude-guardian/archive/<name>-<timestamp>/` | 本工具，`archive` 时 | 每个被归档的实例一个目录：`scrollback.txt`、`meta.env`、`instance.env` |
| `/usr/local/bin/claude-guardian` | 本工具，`install` 时（从 `bin/claude-guardian.sh` 拷贝） | 安装后的 CLI 入口 |
| `$TMUX_SOCKET`（默认 `/run/claude-guardian/tmux.sock`） | 本工具，运行时创建 | 每个实例共享的一个专用 tmux 服务器 socket，与任何交互式管理员自己在 `/tmp` 上的 tmux 服务器隔离 |
| `$WORKDIR`（默认 `/root`，可按实例覆盖） | 操作者，通过配置或 `new --workdir` | `claude` 启动时所在的工作目录 |
| `$CLAUDE_SESSIONS_DIR`（默认 `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/sessions`） | Claude Code，不是本工具 | 只读：每个运行中的 `claude` 会话一个 JSON 文件，文件名是它的 PID；既是 Remote Control 连接/断开检查的数据来源，也是 nudge 所依据的 busy/idle/waiting 检查的数据来源 |
| `$CLAUDE_PROJECTS_DIR`（默认 `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects`） | Claude Code，不是本工具 | 只读：对话 transcript，每个工作目录一个目录；在重启之后恢复一段对话前会检查它是否存在 |

### 配置参考

全局变量放在 `/etc/claude-guardian/config.env`，是一个纯粹的 `KEY="value"` shell 文件，最先被 source。按实例的覆盖项（`WORKDIR`、`CLAUDE_ARGS`、`CLAUDE_BIN`）放在 `/etc/claude-guardian/instances/<name>.env`，只对该实例在其之上再 source 一次——见 `new --workdir`/`--args`/`--claude-bin`。仓库里的 `.env.example` 作为参考记录了全局默认值（本项目没有单独的应用层 `.env`——安装后的那份配置文件本身就是运行时配置）。

| 变量 | 含义 | 默认值 | 作用域 | 是否必填 |
|---|---|---|---|---|
| `TMUX_SOCKET` | 共享的 tmux 服务器 socket 路径 | `/run/claude-guardian/tmux.sock` | 全局 | 否 |
| `WORKDIR` | `claude` 启动时所在的工作目录 | `/root` | 全局，可按实例覆盖 | 否 |
| `CLAUDE_BIN` | `claude` 可执行文件名或绝对路径 | `claude` | 全局，可按实例覆盖 | 否 |
| `CLAUDE_ARGS` | 每次（重）启动时附带的额外 CLI 参数 | `--permission-mode auto --remote-control` | 全局，可按实例覆盖 | 否 |
| `CHECK_INTERVAL_SEC` | 存活检查的间隔秒数 | `5` | 全局 | 否 |
| `REQUIRED_APT_PKGS` | 缺失时自动安装的 apt 包，空格分隔 | `tmux uuid-runtime` | 全局 | 否 |
| `UNATTENDED_NUDGE_SEC` | 仅无人值守时生效：在没有 tmux 客户端接管的情况下，一个确认弹窗可以无人回答多久，超过之后才发送一次裸 Enter 替操作者回答它；`0`（默认值）表示永不发送。无论哪种设置，一个正在干活或停在空提示符上的会话都不会被敲键 | `0` | 全局 | 否 |
| `REMOTE_CONTROL_CHECK_SEC` | 仅无人值守时生效：每隔这么多秒检查一次连接状态。检查是被动的——读会话文件，不敲任何键——所以默认是每个监督 tick 检查一次；`0` 表示禁用 | `5` | 全局 | 否 |
| `REMOTE_CONTROL_RECONNECT_BACKOFF_SEC` | 同一个实例两次重连尝试之间的最小间隔。重连是唯一会敲键的一步（`/remote-control`），所以这个值限定了一个连不回来的实例最多多久被敲一次 | `60` | 全局 | 否 |
| `CLAUDE_SESSIONS_DIR` | Claude Code 写入其按会话 JSON 文件的位置；只读，连接/断开检查和 busy/idle/waiting 检查全靠它 | `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/sessions` | 全局 | 否 |
| `CLAUDE_PROJECTS_DIR` | Claude Code 存放对话 transcript 的位置；只读，在重启之后恢复一段对话前会检查它 | `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects` | 全局 | 否 |
| `RESUME_AFTER_RESTART` | `1`：在一次把 tmux 会话一并带走的重启之后，让实例回到它原本那段对话上；`0`：总是开一段新的 | `1` | 全局，可按实例覆盖 | 否 |
| `MAX_SESSIONS` | 实例数达到这个值后 `new`/`resume` 会拒绝；`0` = 不限制 | `0` | 全局 | 否 |

## 从零搭建

1. 以 root 身份，把仓库（克隆一个 tag，不是分支尖端）克隆到目标 Debian 服务器上——验证：`git clone ...` 退出码为 0，且 `bin/claude-guardian.sh` 存在。
2. `bash bin/claude-guardian.sh check`——验证：打印出三个检查区块（`apt dependencies`、`claude CLI`、`login state`），带有 `[ok]`/`[missing]`/`[warn]` 标记，且不做任何改动。
3. `bash bin/claude-guardian.sh install`——验证：以 `install complete` 结尾；`systemctl is-enabled claude-guardian@claude-code` 输出 `enabled`（默认实例已被自动创建并启用）。
4. `claude-guardian start`——验证：`systemctl is-active claude-guardian@claude-code` 输出 `active`。
5. `claude-guardian attach`——验证：把你带进 tmux 里一个存活的 `claude` 终端（名字默认是 `claude-code`），且 pane 里会显示一行 `/remote-control is active ... https://claude.ai/code/session_...`——这个链接可以脱离这次 SSH 连接、独立地在网页或手机上控制，也可以完全不接管、直接用 `claude-guardian url claude-code` 打印出来。用 tmux 前缀键（默认 `Ctrl+b`）接 `d` 分离——**不要**用 Ctrl+C。
6. `claude-guardian new second-instance`——验证：`claude-guardian list` 显示两行（`claude-code`、`second-instance`），各自带着自己的 `SYSTEMD`/`TMUX`/`URL` 列，确认两者被独立监督、都能远程控制。
7. 从另一个终端，在会话里真正退出 `claude`，验证重生——例如 `tmux -S /run/claude-guardian/tmux.sock send-keys -t claude-code C-c C-c`（Claude Code 把单次 Ctrl+C 当作"中断当前这一轮"，和大多数 REPL 一样；要快速连按两次才会真正退出，和输入 `/exit` 效果一样）。验证：在 `CHECK_INTERVAL_SEC` 之内，`claude-guardian logs claude-code` 会打印一行 `respawning automatically`，该实例的 `claude` PID（`pgrep -f 'claude --permission-mode'`）已经变化，`claude-guardian attach` 再次显示一个存活的会话（带着新重新捕获的远程控制链接）。
8. `claude-guardian deactivate second-instance`，然后检查 `pgrep -f 'claude --permission-mode'`——验证：两个 `claude` 进程都还在跑（deactivate 只暂停监督，见 Known limitations 里关于 `KillMode` 的说明）。再执行 `claude-guardian activate second-instance`——验证：该实例的 `claude` PID 还是同一个（监督恢复到已存在的会话上，而不是重新创建）。
9. `claude-guardian archive second-instance --yes`——验证：`claude-guardian list` 不再显示 `second-instance`；`claude-guardian archives` 显示一条它的记录，带着保存下来的 `scrollback.txt`；`pgrep -f 'claude --permission-mode'` 只剩下 `claude-code` 那个进程。
10. `claude-guardian resume second-instance`（或者用第 9 步得到的确切归档 id）——验证：`claude-guardian list` 再次显示 `second-instance`，且 `claude-guardian attach second-instance` 延续的是同一段对话，而不是从头开始。
11. 在会话内部断开 Remote Control（`/remote-control` → `Disconnect this session`）然后分离——验证：在 `REMOTE_CONTROL_CHECK_SEC`（默认 5 秒）之内，`claude-guardian logs claude-code` 会出现 `remote control disconnected ... reconnecting`，紧跟着一个*新的*链接，并且 `claude-guardian url claude-code` 打印的就是这个新链接。之后让这个实例保持连接且无人接管数分钟——验证日志完全安静，也就是说每个 tick 都检查的代价在外部看不见、也不敲任何键。想验证重连退避：断开之后立刻让重连无法成功（比如把网络断掉），`reconnecting` 那一行最多每 `REMOTE_CONTROL_RECONNECT_BACKOFF_SEC` 出现一次，而不是每个 tick 一次。
12. 在默认的 `UNATTENDED_NUDGE_SEC=0` 下：触发一个确认弹窗（用 `--permission-mode default` 最省事：让它执行任意一条 shell 命令），分离，放着不管数分钟——验证：`claude-guardian logs claude-code` 始终不会出现 `sending Enter` 那一行，你回来时弹窗还等在那里。没有任何东西替你回答它。然后把 `/etc/claude-guardian/config.env` 里的 `UNATTENDED_NUDGE_SEC` 设成 `"60"`，执行 `claude-guardian restart claude-code`，再重复一次——验证：到了 60 秒这个点，日志里出现 `has been waiting on a confirmation for Ns with nobody attached`，紧跟着 `sending Enter`，弹窗消失。再接管一次、再分离一次——验证它不会立即再次触发（计时器在接管时会重置）。验证完把它改回 `0`。
13. `reboot` 宿主机——验证：重启后，每一个曾被 `activate`（而不是 `deactivate`）过的实例都会自动变回 `active`，不需要手动干预；`claude-guardian logs <name>` 会显示 `continuing this instance's previous conversation (<uuid>)`；接管进去看到的是重启之前那段对话，而不是一段空的。想不真的重启就演练一遍：`claude-guardian stop <name>`、`tmux -S /run/claude-guardian/tmux.sock kill-session -t <name>`、`claude-guardian start <name>`。

本项目不是用 Docker 部署的；以上步骤就是完整的部署流程。

## 数据模型 / 文件布局

```
repo/
├── bin/claude-guardian.sh   # 整个工具——自包含，没有其他源文件
├── README.md / README.zh.md
├── DESIGN.md / DESIGN.zh.md
├── .env.example             # 记录全局 config.env 变量（见 Configuration reference）
└── ...
```

仓库里没有单独签入的 systemd unit 文件或配置模板：`claude-guardian install` 会从内嵌在 `bin/claude-guardian.sh` 里的 heredoc 生成这两者，所以这一个文件本身就是一份完整的、自包含的部署产物——把它拷到任何地方，跑一下 `install` 就够了，不需要仓库里的其他东西。

## 已知限制与坑

- **`UNATTENDED_NUDGE_SEC`（自动敲 Enter）是一个刻意的、经过明确批准的安全权衡，不是一个中性的便利功能。** `--permission-mode auto` 在分类器连续拦截 3 次（或累计拦截 20 次）之后会回退到交互式确认——这个回退机制存在的意义就是让人来对分类器无法自动清除的动作做出判断。无人值守时发送一个裸 Enter，会接受当前高亮/默认的那个选项，**却并不知道那个默认选项对那个具体的弹窗来说是不是安全的选择。** 这一点是被 Claude Code 自己的 auto 模式分类器实测拦截过的——guardian 尝试以这个行为重启时被拦下（"defeats the human-in-the-loop safety fallback"），部署前需要用户明确确认（见 `DECISIONS.md`，2026-08-16）。如果这个权衡对某次部署来说不可接受，把 `UNATTENDED_NUDGE_SEC="0"` 设为禁用——文档里给出的替代方案是 `--permission-mode dontAsk` 配合一份明确的 `permissions.allow` 列表，未列出的动作会被静默拒绝，而不是靠猜一个确认弹窗（更可预测，但配置工作量更大）。v0.4.0 收窄的只是*这件事可能落到谁头上*：现在这个 Enter 只会发给一个 `claude` 自己报告为 `waiting` 的会话，而且还要等弹窗无人回答满整个间隔。所以一个有人正在里面工作的会话不会再被敲键。残留的情况是：一个人在 claude.ai 上打开了一个弹窗，然后把它晾了超过 `UNATTENDED_NUDGE_SEC`，但其实还打算回来回答它——从外面看，这和一个被遗弃的会话没有区别，于是这个弹窗会被代为回答。如果这一点对你很重要，把间隔调大。
- **`claude-guardian install`/`new` 会非交互式地自动安装缺失的 apt 包**（`DEBIAN_FRONTEND=noninteractive apt-get install -y`）。默认情况下是 `tmux` 和 `uuid-runtime`。如果你扩大了 `REQUIRED_APT_PKGS`，请自行审查你在无人值守的情况下要求它安装的是什么。
- **`claude` 二进制缺失会让某个实例的 service 失败循环大约一分钟，然后停下。** `preflight_enforce` 在找不到 `claude` 时会硬性失败（这是设计如此——本工具从不负责安装它）。unit 里的 `StartLimitBurst=10` / `StartLimitIntervalSec=60` 会阻止 systemd 无限重启；之后该实例会停在 `failed` 状态，直到你装好 `claude` 并执行 `systemctl reset-failed claude-guardian@<name> && claude-guardian start <name>`。
- **`claude-guardian deactivate <name>`（即 `systemctl disable --now`）不会杀掉存活的会话——这依赖 unit 里的 `KillMode=process`，已对真实二进制验证过。** systemd 的*默认* `KillMode` 是 `control-group`，会在 stop/restart 时对整个 cgroup 发 SIGTERM，包括 tmux 服务器和 `claude` 本身（这是实测抓到的：unit 最初的版本没有显式设置 `KillMode`，一次 `systemctl restart` 就悄悄杀掉并重建了会话）。设了 `KillMode=process` 之后，只有被跟踪的循环 PID 会收到信号，所以 `claude` 和它的 tmux 会话能扛过该实例监督进程的 `stop`/`restart`/`deactivate`。一个副作用：systemd 会在下次 `start` 时记录一条无害的 `Found left-over process ... in control group` 提示，因为之前的 `claude` 进程还留在那个 cgroup 里——这是预期行为，不是错误。要真正结束某个实例的对话，用 `claude-guardian archive <name>`（破坏性操作，默认要确认）；要拆掉一切，用 `claude-guardian purge`（同样默认要确认，且不会动归档——见下文）。
- **`purge` 的影响范围从"一个会话"变成了"每一个存活的实例"**，这是加入多实例支持时带来的变化（见 `DECISIONS.md`，2026-08-17）。它现在会打印当前存活的实例数，并在动手之前要求交互式确认（或传 `--yes`），且刻意从不删除 `/var/lib/claude-guardian/archive/`——想彻底删掉某个归档，要用 `rm-archive` 显式操作。
- **现在有三处行为依赖 Claude Code 的内部文件。** `$CLAUDE_SESSIONS_DIR/<pid>.json`（字段 `bridgeSessionId`、`status`、`statusUpdatedAt`）和 `$CLAUDE_PROJECTS_DIR/<slugged-workdir>/<id>.jsonl` 都不是有文档、有承诺的接口；未来某个版本的 Claude Code 可能改名、挪位置，或干脆不再写它们。三处都已针对 2.1.202 验证。当对应文件缺失或读不了时，每一处都是降级而不是崩溃：连接检查会退回到发送 `/remote-control` 并从屏幕上读取链接（这正是 v0.2.0 一直以来的做法），nudge 会退回到墙上时钟（也是 v0.2.0 的行为），而一次无法确认的恢复就干脆开一段新对话。两个路径都可以在配置里覆盖（`CLAUDE_SESSIONS_DIR`、`CLAUDE_PROJECTS_DIR`），所以文件挪了位置也不用改脚本。transcript 目录名是这样推导出来的：把工作目录里每一个不在 `[A-Za-z0-9]` 范围内的字符替换成 `-`；如果这个约定变了，重启后恢复对话就会悄无声息地再也找不到 transcript，每次重启又会从一段新对话开始——这就是要留意的症状，因为不会有任何报错。
- **重连 Remote Control 会往 tmux pane 里发送真实的按键**（`C-u`、`/remote-control`、`Escape`），实例创建时的首次捕获也一样（紧跟在引导阶段的双击 Enter 之后）。和 v0.2.0 不同的是，这不再由定时器触发——只有上面那个检查确认 Remote Control 真的断了才会发生——但如果 `claude` 恰好意外地停在正常提示符以外的某个屏幕上（比如引导流程超出了已经发送的那两次 Enter），这些按键就可能被敲进错误的地方。无害（这一步不会自动确认任何东西，而且 Escape 是关闭而不是选中），但可能留下需要手动用 `claude-guardian attach <name>` 清理的杂散文本。这和双击 Enter 清除引导屏幕、以及无人值守 nudge 是同一类已被接受的"盲发按键"权衡，参见上面 `UNATTENDED_NUDGE_SEC` 那条。
- **一次重连会改变实例的 `claude.ai/code/...` 链接。** 对话本身不受影响——还是同一个 `claude` 进程、同一个 `claude_session_id`——但之前收藏的链接会失效。既要真正重连、又要保住旧链接是做不到的，所以工具选择保证连接可用，并且预期链接是按需取（`claude-guardian url <name>`）而不是存下来备用。
- **`resume` 只有在归档里记录了 `claude_session_id` 的情况下才能重建对话。** 由本工具自己的 `archive` 命令生成的归档永远满足这一点（这个 id 在实例创建时就已捕获并一路带过来），但如果某个归档目录被手工改动过，或者 `meta.env` 丢了，`resume` 会拒绝执行，转而指向原始的 `scrollback.txt`，而不是去瞎猜。
- **`install` 会原地迁移一个 v0.1.0 的单实例部署**（`migrate_legacy_unit`）：它会禁用/移除旧的 `claude-guardian.service`，并针对*同一个* tmux 会话启用新的 `claude-guardian@claude-code.service`。这依赖新旧两个 unit 里都设了 `KillMode=process`（上面已验证过）——如果未来某次 systemd unit 改动不小心把这个设置去掉了，这条迁移路径就需要针对一个存活会话重新验证一遍，才能再信任它。已在一台真实的生产主机上验证过：`install` 执行前后，tmux pane 的 PID 和存活状态都没有变化。
- **一个被迁移过来的既有会话，在真正被重建之前，永远拿不到被跟踪的 `claude_session_id`、`workdir` 或已捕获的链接**——这是在上面那次生产迁移中发现的。`respawn-pane` 只会重放 tmux 保存的*最初那条*会话创建命令；对于一个早于 v0.2.0 就存在的会话来说，那条原始命令里没有 `--session-id`，所以任何一次崩溃重生都不会补上这个字段。实际影响：`list` 会把这类实例的 workdir 显示为 `-`；它的链接照样能找到（链接来自 claude 自己的会话文件，每个运行中的会话都有，缺失的被跟踪 id 只是让 PID 复用交叉核对少做了一半）；而对这个实例执行 `archive` 会保存一个空的 `claude_session_id`——之后 `resume` 会正确地拒绝执行，转而指向原始滚动记录，而不是瞎猜。想让一个被迁移的实例拿到真正可恢复的会话 id，唯一的办法是让它的 tmux 会话真正结束并被重建（比如刻意 `archive` 它一次，再 `resume`/`new` 回来）——没有原地回填的办法，手工编辑它的状态文件也只会伪造一个 `claude` 从未真正用过的 id。
- **分离要用 tmux 前缀键，不要用 Ctrl+C——而且单次 Ctrl+C 本来也杀不死 `claude`。** 已对真实 CLI 验证过：Claude Code 把单次 Ctrl+C 当作"中断当前这一轮"（和大多数 REPL 一样），不是退出——pane 依然存活，什么都不会被重新拉起。要快速连按两次 Ctrl+C（或者 `/exit`）才会真正终止进程，此时 pane 才会死掉、guardian 才会把它重新拉起来，这符合最初的要求：一次刻意的杀掉动作绝不能导致零个存活实例。不管要按几次 Ctrl+C 才能退出，这都不是一种干净的离开会话的方式——请始终使用 tmux 前缀键 + `d`。
- **如果这个仓库的工作副本放在挂载了固定 `file_mode` 选项的 CIFS/SMB 文件系统上（NAS 支持的开发环境很常见），对 `bin/claude-guardian.sh` 执行 `chmod +x` 可能会静默地什么都不做**（退出码 0，权限位却没变——开发过程中真的碰到过）。可执行位是在提交时直接记录进 git 树里的（`git update-index --chmod=+x bin/claude-guardian.sh`），所以一次正常的 `git clone` 只要落在支持真实权限位的文件系统上，检出来的文件就会自带可执行权限。如果你本地的工作副本保不住这个可执行位，就显式用 `bash bin/claude-guardian.sh ...` 调用，而不是 `./bin/claude-guardian.sh`。
- **登录状态只在 `install` 时被强制检查，不是持续检查的。** `install` 在 `claude auth status` 失败时会硬性拒绝（已针对两种真实状态验证过：已登录，以及一个没有任何凭据的隔离 `HOME`——分别退出码 0 和 1）。安装完之后，`run` 只在认证缺失或后来丢失时发出警告——service 会继续重试，`claude` 会在下次有人接管时展示它正常的交互式登录流程，而不是拒绝启动。这是刻意如此，不是疏漏：一个原本正常工作、后来丢失认证（token 过期、会话被吊销）的 service，应该继续尝试提供服务，而不是陷入重启失败循环。
- **`REMOTE_CONTROL_CHECK_SEC` 只限定了一次掉线最长能被忽视多久，别的什么都不代表。** v0.2.0 把它设成 1200 秒是为了卡在 Anthropic 文档里那个约 30 分钟的"无法连接 Remote Control 服务器"窗口之内，前提假设是提前重新执行一次 `/remote-control` 就能让连接永不过期。这个假设是错的（见 `DECISIONS.md`，2026-08-17），于是留下了一个 20 分钟的数字在干一件它当初不是为之而选的活：它变成了"一个实例可以有多久够不着"，而在生产环境里它确实就是这么表现的。从 v0.6.0 起，这个检查每个 tick（5 秒）跑一次——它只是读一个文件、不敲任何键，本来就没有慢的理由——旧变量已被移除。配置里仍然设置 `REMOTE_CONTROL_REFRESH_SEC` 的话，循环启动时会给出一条警告，该设置本身被忽略。
- **一个持续失败的重连是按退避重试的，不是每次检查都重试。** `REMOTE_CONTROL_RECONNECT_BACKOFF_SEC`（60 秒）之所以存在，是因为重连是唯一会往会话里敲键的一步：没有它，一个 Remote Control 死活连不回来的实例就会每 5 秒被敲一次 `/remote-control`。而当 `claude` 根本没写出可用的会话文件时，永远不会有任何东西能确认重连成功，所以那种情况退到一个慢得多的内部重试（1200 秒），而不是 60 秒的退避。
- **无人值守 nudge / 连接检查的计时器只从监督循环自身（重新）启动的那一刻开始计数，而不是从会话实际最后一次被接管的时刻算起。** 这是实测抓到的一个真实 bug：最初的版本把两个计时器都初始化为 `0`（纪元时间），导致针对一个已经无人值守的会话执行 `systemctl restart` 会立刻触发一次 nudge 和刷新，而不是先把配置的间隔跑完。修复方式是在循环启动时把两个计时器都设成当前时间。

## 如何扩展

- **新的前置检查**要同时加进 `preflight_report`（只报告，不改动）和 `preflight_enforce`（可能改动系统/硬性失败）——保持两者同步，这样 `check` 才能准确预览 `run`/`install`/`new` 实际会做什么。
- **新的全局配置变量**通过同时扩展 `bin/claude-guardian.sh` 顶部附近的默认值代码块和 `write_default_config` 里的 heredoc 来添加，同时在本文档的 Configuration reference 表格和 `.env.example` 里各加一行。**新的按实例覆盖项**则要走 `write_instance_file` 和一个新的 `new --flag` 选项——保持这个集合小巧；`WORKDIR`/`CLAUDE_ARGS`/`CLAUDE_BIN` 之所以被选中，是因为它们是目前唯一真正出现过按实例需求的旋钮（见 `DECISIONS.md`，2026-08-17）。
- **按实例的 TMUX_SOCKET，或者一个 HTTP 控制 API**，在加入多实例支持时都被考虑过并否决了——重新引入任何一个之前，先看 `DECISIONS.md`，2026-08-17，"Rejected"。
- **新的实例生命周期子命令**应该遵循现有模式：只通过 `instance_file`/`state_get`/`state_set` 读写状态，绝不碰另一个实例的文件，并且要把 `usage()`（那段注释块）和 `main()` 里的 case 语句一起更新——`usage()` 是靠 `sed` 从那段注释块生成的，只要两处在同一次改动里一起改，就不可能出现漂移。
