# claude-code-guardian — 设计文档

[English](../DESIGN.md) | **简体中文**

> 译自 `DESIGN.md`（v0.10.0）。如有冲突，以英文版为准。

> 本文档的成功标准：另一个人在另一台机器上，仅凭这份文档就能把这个项目重建出来。假设读者看不到你的机器。

## 目标与非目标

**目标**
- 在 Debian 系服务器上，让一个或多个具名的 `claude`（Claude Code CLI）实例并发保活，每个实例都跑在自己可分离的终端复用会话里，让操作者能在任意时刻远程接管其中任何一个——既可以通过 Claude Code 自带的 Remote Control（一个 `claude.ai/code/...` URL，可从网页或手机控制），也可以通过 SSH + `tmux attach`。为什么这取代了最初的单会话设计，见 `DECISIONS.md`，2026-08-17 条目。
- 让每个实例的远程控制 URL 无需附加（attach）就能取到——在创建时以及每次无人值守的刷新时自动捕获，按实例存储，由 `list`/`url` 打印出来。要点在于：操作者完全可以从另一个驱动本工具 CLI 的 Claude Code 会话里创建、发现并触达一个会话，完全不需要自己拥有一个终端。
- 让一个实例可以被**暂停**（`deactivate`/`activate`：停止/恢复监管，tmux 会话保持运行）而独立于被**归档**（`archive`/`resume`：保存回滚缓冲区 + 会话 id，然后杀掉进程；之后通过 `claude --resume` 重新创建）——这两者被刻意设计成爆炸半径不同的两个独立操作。
- 挺过重启（每个已启用的实例的服务在开机时启动）。
- **保证的是下限，而不只是恢复能力。** 最初的需求（`DECISIONS.md`，2026-08-16）是「至少始终有一个会话可用」。直到 v0.9.0，都没有任何机制强制执行这一点：它之所以成立，只是因为 `install` 启用了默认实例，而此后没有人把它归档过——一旦某台主机最后一个实例被归档或停用，它重启后会悄无声息地不带任何会话开机。现在有两套机制把这一点变成了工具本身的属性——一是数量降到零之前会发出警告，二是 `claude-guardian-floor.service`，它会在开机时、当没有其他机制能保证有实例存在的情况下重新创建默认实例（可用 `ENSURE_DEFAULT_INSTANCE=0` 退出该机制）。
- 挺过 `claude` 进程本身被杀死——Ctrl+C、崩溃、`exit`、OOM kill——办法是几秒内自动重启它，而不丢失外层会话。
- 在长时间无人值守的情况下也保持真正可触达，而不只是"进程在跑"：几秒内察觉 Remote Control 连接掉线并修复它，让一个实例不会"活着但联系不上"超过一个检查周期。清除 `auto` 权限模式回退时产生的确认提示这项功能也提供，但默认关闭——回答一个提示是一个决策，而本工具的职责止于让会话保持可触达（见"已知局限"）。
- 运行预检：所需的 `apt` 软件包是否存在（缺失时自动安装）、`claude` 二进制是否存在（硬性要求，绝不自动安装）。登录状态通过 `claude auth status` 检查（这是权威判定，不是靠文件是否存在去猜）——`install`/`new` 在未登录时拒绝继续（一个从未登录过的实例只会不断重生一个没人能用的会话），而 `run` 只发出警告，这样一个之后失去授权的实例会持续重试而不是拒绝启动。
- 在不强加限制的前提下提供资源/成本增长的护栏：一旦并发实例数已达到 `MAX_SESSIONS`，`new` 就拒绝创建——每个实例都是一个独立的 `claude` 进程，也是一份独立的 token 花费。默认值是 `0`（不限制），因为操作者想要多少并发对话是一个工作流决策，本工具无法替他猜测；这个旋钮是留给确实想要一个上限的人的。
- 用一套简短、好记的 CLI（`claude-guardian <动词> [<名字>]`）就能操作。

**非目标**
- 安装或更新 Claude Code CLI 本身。默认操作者已经安装并完成认证（或者通过本工具管理的某个会话交互式完成认证）。
- 从零构建一套远程访问传输层。本工具依赖 Claude Code 自带的 `--remote-control` 功能作为主要远程通路，并假定可以通过 SSH 访问主机作为后备方案；它只负责让 `tmux` 会话保持存活，供二者之一 attach。
- 一套用于远程管理实例的生命周期控制 API（HTTP/REST 或其他形式）。生命周期管理只走 CLI，要么通过 SSH，要么从本工具自身管理的某个 Claude Code 会话内部驱动（见 `DECISIONS.md`，2026-08-17，"Rejected" 一节）。
- 图形界面、网页仪表盘或通知系统。状态通过 `claude-guardian list` / `systemctl status` / `journalctl` 查看。

## 架构

每个具名实例都运行着与最初单会话设计相同的两套独立监管层，只是按实例名参数化——每个 `claude-guardian <name>` 对应一个 systemd 单元实例和一个 tmux 会话，所有 tmux 会话共用同一个 tmux 服务端：

```
                     某一个实例的监管进程开机/崩溃
                                    |
                                    v
   systemd (Restart=always) ---> claude-guardian run <name>  (前台循环)
   claude-guardian@<name>.service    |
   (每个名字一个实例，              | 每 CHECK_INTERVAL_SEC 一次：
    源自一个模板单元)                | tmux has-session? / pane_dead? / client attached?
                                      | （若无人值守：每个周期都检查
                                      |  Remote Control 是否仍连着，若断开则
                                      |  重连；可选地，且默认关闭，
                                      |  清除一个没人回答的对话框 —— 见下文）
                                      v
                     tmux 会话 "<name>" (remain-on-exit 开启)
                     —— 可能是多个之一，都跑在
                       同一个 tmux 服务端 / $TMUX_SOCKET 上
                                    |
                                    v
        claude --dangerously-skip-permissions --remote-control --session-id <uuid>
        （或者用 --resume <uuid> 代替 --session-id：一个由
         `claude-guardian resume <archive-id>` 创建的实例，
         或者一个从重启中恢复、回到已有对话的实例）
                                    ^                       ^
                                    |                       |
                        操作者：ssh + `claude-guardian     操作者：claude.ai
                        attach <name>`（tmux attach）        web/手机 (Remote Control) ——
                                                               URL 从 claude 自己的会话
                                                               文件读取并保存下来，因此
                                                               `claude-guardian url <name>`
                                                               无需 attach
                                                               就能打印出来
```

- **systemd 层**从以下情况中恢复：重启、某个实例的监管脚本崩溃、该实例的 tmux 服务端状态在服务端消失。`Restart=always` 加上有上限的 `StartLimitBurst` 阻止它在 `claude` 确实缺失时无限重启（见"已知局限"）。`KillMode=process` 使得 `stop`/`restart`/`deactivate` 只向被跟踪的循环 PID 发信号，绝不触及 tmux 服务端或 `claude`（这一点已在真实环境中验证——默认的 `KillMode=control-group` 会杀掉整个会话，这也是为什么这里要显式指定，而不是留用 systemd 默认值）。因为它是一个*模板*单元（`claude-guardian@.service`），每个实例都是它的一个独立 systemd 单元实例（`claude-guardian@work.service`、`claude-guardian@personal.service`……），可以被单独启动、停止、启用或禁用，而不影响任何其他实例。该模板还带有 `User=$RUN_AS_USER`，以及针对默认 socket 路径的 `RuntimeDirectory=claude-guardian` 与 `RuntimeDirectoryPreserve=yes`——见下面的账户层。
- **账户层**并不是一个监管层，但它横跨所有监管层：root 负责安装和监管，而 tmux 服务端、每一个 `claude` 进程、以及 `claude` 写下的一切都属于 `$RUN_AS_USER`。原因是具体的，而不是出于卫生习惯——`claude` 在以 root 身份运行时会拒绝 `--dangerously-skip-permissions`，而一个停下来等待权限确认的无人值守会话就是一个卡住的会话，所以工具自身的目标迫使做了这个拆分。以下每一条后果，都是代码为此必须改动的地方，而不只是意图上的陈述：
  - 账户是全局的，不是按实例的。每个实例共用一个 tmux 服务端，而一个 tmux 服务端只属于一个账户，所以一台主机只有一个会话所有者。
  - 只有 root 能创建 `/run/claude-guardian`（一个 tmpfs，开机时为空）和 `/var/lib/claude-guardian/state`，但真正往里面写内容的是那个非特权循环。systemd 的 `RuntimeDirectory=` 会在 `ExecStart` 之前先建好 socket 目录并交给 `User=`；`RuntimeDirectoryPreserve=yes` 是必须的，因为默认行为会在某个监管单元停止的瞬间删掉那个目录——以及里面正在使用的 socket——而这恰恰是 `KillMode=process` 要防止的事情。状态目录由每一个 root 侧命令创建并 chown，因此一台 `RUN_AS_USER` 发生变化的主机会在下一次 `install` 时自我修复。
  - 关于 `claude` 的每一个问题都必须"以那个账户的身份"去问：它的二进制在哪里（`~/.local/bin/claude` 不在任何人的 systemd `PATH` 上）、它是否已登录（登录状态属于某一个账户——root 的登录状态什么也说明不了）、以及哪个 `~/.claude` 保存着会话文件和转录记录。root 通过 `runuser` 来问；答案是从 `passwd` 而不是 `$HOME` 解析出来的，因为在 `sudo` 下 `$HOME` 仍然是 root 的。
  - `run` 在运行它的账户与配置的账户不一致时拒绝启动。这意味着已安装的单元早于配置存在，若仍然启动，就会在错误的账户下建立 tmux 服务端——以及那份对话。
- **开机地板层**能从另外两层都无法恢复的情况中恢复，因为那两层都是按实例的：没有任何实例可供监管的情况。`claude-guardian-floor.service` 是一个独立的 `oneshot` 单元，和各实例一样 `WantedBy=multi-user.target`，每次开机运行一次 `claude-guardian ensure-floor`。它统计那些真正会启动起来的实例——既要在 `$INSTANCES_DIR` 里有配置文件，*又*要有一个已启用的单元，因为 `deactivate` 会把配置文件留下——如果这个数量为零，它就重新创建默认实例并启动它。若已存在一份 `claude-code` 配置，会复用而不是覆盖它（这正是 `deactivate` 的情形，操作者的工作目录/参数是他自己的）；只有确实缺失的配置才会用全局默认值写出。它用 `systemctl start --no-block` 启动实例，绝不用 `enable --now`：这个单元跑在开机事务内部，而在其中阻塞等另一个单元的启动作业正是造成开机死锁的原因。
- **tmux 层**从以下情况中恢复：`claude` 进程本身以任何原因退出，而*会话*（它的回滚缓冲区、它的 pty）被保留下来。这正是为什么在会话内发送 Ctrl+C 是安全的、不会丢状态——只有 `claude` 退出并被重新拉起，tmux 会话本身安然无恙。（说明：Claude Code 本身把单次 Ctrl+C 当作"中断当前这一轮"，而不是退出——需要连按两次，或者用 `/exit`，才能真正终止进程；已对照真实二进制验证过。）所有实例共用一个 tmux 服务端（一个 `$TMUX_SOCKET`），每个实例一个会话，以实例名命名——tmux 本身已经原生支持多路复用会话，所以给每个实例配一个独立服务端只会增加运维开销而没有任何好处（见 `DECISIONS.md`，2026-08-17）。
- **会话身份**：在创建时，每个实例要么被赋予一个全新的 `claude --session-id <uuid>`（通过 `uuidgen` 生成），要么被赋予一个指向既有对话的 `claude --resume <uuid>`。无论哪种方式，这个 id 都被烘焙进了 tmux pane 最初的命令行里，所以崩溃后的每一次 `respawn-pane` 都会自动复用同一个 id——一次重生延续的是同一场对话，绝不会悄悄分叉出一场新的。这个 id 记录在按实例保存的状态里（`/var/lib/claude-guardian/state/<name>.state`），所以 `archive` 能把它存下来，`resume` 能复用它，实例也能在重启后找回同一场对话。
- **重启后保住对话不丢**：`respawn-pane` 只覆盖 `claude` 死掉而它所在 tmux 会话仍存活的情况。一次重启会把整个 tmux 服务端一起带走，所以会话要从零开始重建——而在 v0.4.0 之前，这意味着每次开机都会得到一场全新的空对话，之前的那场则被留在磁盘上，只能靠人手动去够。现在 `create_session` 按以下顺序优先选择：一个显式的 `RESUME_SESSION_ID`（由 `resume <archive-id>` 设置）；如果 `RESUME_AFTER_RESTART=1` 且该实例最后一次的 `claude_session_id` 转录文件仍在磁盘上，就用状态里记的那个 id；否则就用一个全新的 `uuidgen` id。转录文件检查正是让这一切诚实的关键——它决定的是"接续那场对话"和"把 `claude` 从未听说过的一个 id 硬塞给它"之间的差别。如果 `claude` 依然拒绝这次 resume，它会立即退出，`create_session` 不会让监管进程每个 `CHECK_INTERVAL_SEC` 都重建同一条注定失败的命令，而是会察觉这个会话已死（或已消失）一次，然后改用一场新对话重试。
- **无人值守保活**（见 `DECISIONS.md` 2026-08-16「始终可远程控制」）：当 `tmux list-clients` 显示某个实例的会话上没有任何人 attach 时，它的循环会 (a) 检查 Remote Control 是否仍处于连接状态，若已断开则重连，以及 (b) ——仅当操作者通过把 `UNATTENDED_NUDGE_SEC` 设为大于 `0` 主动选择启用时——间隔一秒连按两次 Enter，去清除一个没人回答的确认对话框。两者都会在有客户端 attach（每个周期都会检查）后立即停止。这两者跑在截然不同的时钟节奏上，v0.6.0 把它们拆开是有原因的（见 `DECISIONS.md`，2026-08-17「每个周期都盯着这条连接」）：(a) 是被动的——它只读一个文件，不敲入任何字符——所以它每 `REMOTE_CONTROL_CHECK_SEC`（默认 5 秒，即每个周期）都会跑一次，因为一次断开的连接在 claude.ai 上是不可见的，而它每多断开一秒，操作者就多一秒无法触达一个本来完全正常的会话。只有重连这一步会敲键，而它另外受 `REMOTE_CONTROL_RECONNECT_BACKOFF_SEC`（默认 60 秒）单独限速。(b) 按定义会敲键，代替操作者做决定，因此默认关闭。"没有人 attach"对它而言是必要条件，但不是充分条件：循环还会去问 `claude` 这个会话正在做什么，只有当它确实卡在一个对话框上时才会往里敲——见下面的**推一把何时才被允许敲键**。`create_session` 在启动 `claude` 之后会立即发送同样的两次 Enter，无论这个设置是什么：一次真正的首次运行可能会显示一个需要两次 Enter 才能清除的引导/信任界面，而此时还没有任何对话内容会被这次 Enter 影响——随后同步记录一次 URL，这样 `new` 就能立即打印它，而不必等上一整个 `REMOTE_CONTROL_CHECK_SEC`。当 `claude` 已经正常停在它平时的提示符时，多发的第二次 Enter 反正也是无害的空操作，所以始终发两次、而不是去尝试判断当前显示的是哪个界面，没有任何坏处。
- **"是否仍连着"这个问题是怎么被回答的**（见 `DECISIONS.md`，2026-08-17「读取 claude 自己的会话文件」）：Claude Code 会为每个正在运行的会话在 `$CLAUDE_SESSIONS_DIR`（`${CLAUDE_CONFIG_DIR:-$HOME/.claude}/sessions`）下写一份 JSON 文件，以该会话的 PID 命名，其中的 `bridgeSessionId` 字段在连接期间保存 Remote Control 会话 id，一旦断开就变为 `null`。一个实例的 `claude` *就是*它的 tmux pane 命令，所以 `#{pane_pid}` 可以直接指向那份文件。读取它就能同时回答"Remote Control 是否仍然在线？"和"当前的 `claude.ai/code/...` URL 是什么？"这两个问题，而不需要往会话里敲入任何东西——这一点很重要，因为此刻这个会话完全有可能正有一个真人通过 Remote Control 在里面工作，Remote Control 并不是一个 tmux client，所以一个正在被实际使用的实例在这里看起来仍然像是"无人值守"。这份文件是按文本匹配的（不依赖 `jq`/`python`），并会和该实例自己记录的 `pid` 以及被跟踪的 `claude_session_id` 交叉核对，这样一个被复用的 PID 就不会把别人的会话错当成自己的返回回来。重连是唯一会敲键的步骤：`/remote-control` 在 Remote Control 关闭时把它打开，而当它已经开着时只会弹出一个信息性对话框（"Disconnect this session" / "Show QR code" / "Continue"），随后的一次 Escape 会关掉它而不选中任何一项。**在一个仍自认为处于连接状态的会话上重新执行 `/remote-control` 什么都刷新不了**——这个被误判的前提正是 v0.2.0 那版保活机制的全部基础，也是为什么这里要先检查、后行动。
- **推一把何时才被允许敲键**（见 `DECISIONS.md`，2026-08-17「只推一把确实卡住的会话」和「默认停止代答对话框」）：首先，只有当操作者主动打开这个开关时才会发生——`UNATTENDED_NUDGE_SEC` 默认为 `0`，在 `0` 的情况下绝不会向一个正在运行的会话发送任何 Enter，一次也不会。当它被打开后，同一份会话文件里带有一个 `status` 字段，循环按这个字段来决定是否推一把，而不是按墙上时钟。三种取值，都已在 2.1.202 上被实际观察到：`busy`（正在处理这一轮）、`idle`（停在一个空提示符上）、以及 `waiting`（卡在一个确认对话框上）。只有 `waiting` 才值得发送 Enter，而且只有当它已经保持这个状态达到 `UNATTENDED_NUDGE_SEC` 之后——这个时长是从 `statusUpdatedAt` 读出来的，所以倒计时是从对话框出现那一刻开始算的，而不是从监管进程碰巧看到它那一刻算起。其余一切情况都不去动它，这才是真正让一个正在被人从 claude.ai 操作的会话变得安全的关键：它没有 tmux client，看起来像是被遗弃了，但它读出来的状态永远是 `busy` 或 `idle`，除非真的有一个对话框卡在那里没人回答，否则绝不会是 `waiting`。`updatedAt` 曾被最先尝试过，但被否决了：它跟踪的是状态*转换*的时刻，所以一个已经忙了二十分钟的会话，它的时间戳依然停留在二十分钟前，看起来就像是被遗弃了（这一点是在维护者自己那场正在进行中的会话上亲眼观察到的）。当没有可用的会话文件存在时，循环会回退到 v0.2.0 那种仅按经过时间来推一把的行为。
- 这两层是刻意按实例独立设计的：`claude-guardian deactivate <name>`（`systemctl disable --now`）只停止该实例的*监管循环*；它不会杀掉它正活着的 tmux 会话，所以一个正在对话中的操作者不会被日常维护操作切断——`activate <name>` 会针对同一个仍在运行的会话恢复监管。彻底拆除一个实例是一个单独、显式、破坏性的步骤：`archive <name>`（见下文）。而彻底拆除*整个工具*是 `uninstall`（只拆 systemd 模板，每个实例的配置/会话都保留原样）相对于 `purge`（拆除一切：每个会话、socket、每份配置、已安装的二进制——但绝不动 `/var/lib/claude-guardian/archive/`，见 README）。
- **归档/恢复**：`archive <name>` 停止监管、把完整的回滚缓冲区（`tmux capture-pane -pS -`）和该实例的 `claude_session_id` 捕获保存到 `/var/lib/claude-guardian/archive/<name>-<ts>/`，然后杀掉这个 tmux 会话——这是一个刻意设计、默认需要确认的破坏性操作（见 `DECISIONS.md`，2026-08-17，「archive 会杀掉进程」）。`resume <archive-id> [new-name]` 从该归档重新创建一个实例，并设置 `RESUME_SESSION_ID`，这样 `create_session` 就会传入 `--resume <uuid>` 而不是铸造一个新的——操作者会在同一场对话里接着往下走。

## 技术栈

| 层 | 选择 | 版本 | 原因 |
|---|---|---|---|
| 进程监管 | systemd | （Debian 默认自带） | 每个目标操作系统上都已经预装；原生支持开机集成和重启策略，无需额外照看一个守护进程。 |
| 会话多路复用 | tmux | Debian 稳定版软件包 | 有可脚本化的存活信号（`#{pane_dead}`）和 `respawn-pane`，不像 `screen` 那样需要轮询进程表。 |
| 实现语言 | 近似 POSIX 的 Bash | bash（Debian 默认 `/bin/bash`） | 整个工具做的就是进程编排以及对 `tmux`/`systemctl`/`apt-get` 的 shell-out 调用；引入一个脚本运行时只会多一份依赖，没有任何好处。 |

被否决的替代方案以及每个选择背后的推理都放在 `DECISIONS.md` 里——这里不重复。

## 复现所需条件

### 环境

- 操作系统：Debian 或其衍生系统（Ubuntu 等），以 `systemd` 作为 PID 1，且有可用的 `apt`/`dpkg`。
- 运行时：`bash`（默认自带）、`tmux`（预检脚本在缺失时自动安装）。
- 权限：分开的。每个管理命令都需要 root（`sudo` 即可）——它们管理系统级 systemd 单元、安装 apt 软件包、写入 `/etc`、`/var/lib` 和 `/run`。而被监管的会话不需要 root：监管循环、tmux 服务端和 `claude` 都以 `$RUN_AS_USER` 身份运行，`install` 在安装时从 `$SUDO_USER` 取得这个身份，只有在没有可继承的账户时才回退到 root。
- 只要 `$RUN_AS_USER` 不是 root，就需要 `runuser`（util-linux）：root 正是靠它去解析那个账户的 `claude`、检查它的登录状态、并 attach 到它的 tmux 服务端。
- 硬件：可忽略不计；一个每隔几秒醒一次的空闲 bash 循环。
- 依赖恢复命令：无——本项目没有任何包管理器层面的依赖，只有 `bin/` 下的这一份 shell 脚本。

### 外部依赖

| 项目 | 来源 | 存放位置 |
|---|---|---|
| `claude`（Claude Code CLI） | 由操作者事先安装并完成认证——本工具不负责安装它 | `$RUN_AS_USER` 的 `PATH` 上的任意位置（会显式查看该账户的 `~/.local/bin`，因为一个服务账户的 `PATH` 里常常不包含它），或者把 `CLAUDE_BIN` 指向一个绝对路径。会**以那个账户的身份**去解析并检查登录状态，而不是以运行命令的那个人的身份 |
| `runuser`（util-linux） | 标准 Debian/Ubuntu 安装中自带 | root 以 `$RUN_AS_USER` 身份行事的方式：解析 `claude`、检查 `claude auth status`、attach 到那个账户的 tmux 服务端。只有当会话账户不是 root 时才需要 |
| `uuidgen`（`uuid-runtime` 软件包） | 缺失时由预检脚本自动安装，和 `tmux` 一样 | 在每次创建/恢复实例时使用一次，用于铸造或复用一个 `claude --session-id`/`--resume` 的值 |
| Claude Code 的按会话文件（`$CLAUDE_SESSIONS_DIR/<pid>.json`，字段 `bridgeSessionId`、`status`、`statusUpdatedAt`） | 由 `claude` 自己在会话运行期间写出——无需安装任何东西 | 用于判断某个实例的 Remote Control 是否仍处于连接状态、获取它当前的 `claude.ai/code/...` URL，以及判断它是在工作中、空闲、还是卡在一个确认对话框上。已对照 Claude Code **2.1.202** 验证过；这些属于内部实现细节，不是被承诺的接口，因此不同版本可能不提供它们——此时本工具会回退到从终端画面读取 URL，以及回退到按墙上时钟推一把（见"已知局限"） |
| Claude Code 的对话转录文件（`$CLAUDE_PROJECTS_DIR/<经过转义的工作目录>/<session-id>.jsonl`） | 由 `claude` 自己写出——无需安装任何东西 | 在重启后恢复一场对话之前，先检查它是否存在；目录名是把工作目录里每一个不在 `[A-Za-z0-9]` 范围内的字符替换成 `-` 得到的。已对照 **2.1.202** 验证过，与上面同样的提醒：读不到就意味着开始一场新对话 |

### 路径与挂载

以下每个路径都只能通过 `bin/claude-guardian.sh` 顶部附近的常量来配置（不是运行时配置——这些属于部署拓扑，而不是按实例的行为）；脚本里的其他地方都没有硬编码它们。

| 路径 | 提供者 | 用途 |
|---|---|---|
| `/etc/claude-guardian/config.env` | 本工具，在首次 `install` 时 | 全局运行时配置，被每个实例共享（见下文） |
| `/etc/claude-guardian/instances/<name>.env` | 本工具，在 `new`/`resume` 时 | 按实例的覆盖项：`WORKDIR`、`CLAUDE_ARGS`、`CLAUDE_BIN`，以及（如果是 resume 出来的）`RESUME_SESSION_ID` |
| `/etc/systemd/system/claude-guardian@.service` | 本工具，在 `install` 时 | systemd **模板**单元——`claude-guardian@<name>.service` 是它针对每个运行中实例的一个实例 |
| `/etc/systemd/system/claude-guardian-floor.service` | 本工具，在 `install` 时 | 开机地板机制：一个每次开机运行一次 `claude-guardian ensure-floor` 的 `oneshot` 单元。刻意和模板分开——模板的单元只为已经启用的实例存在，因此没有一个会跑在地板层需要修复的那种状态里 |
| `/var/lib/claude-guardian/state/<name>.state` | 本工具，运行期间 | 按实例的运行时状态：`claude_session_id`、`workdir`、`created_at`、`remote_url`、`remote_url_updated_at` |
| `/var/lib/claude-guardian/archive/<name>-<timestamp>/` | 本工具，在 `archive` 时 | 每个被归档的实例一个目录：`scrollback.txt`、`meta.env`、`instance.env` |
| `/usr/local/bin/claude-guardian` | 本工具，在 `install` 时（从 `bin/claude-guardian.sh` 复制而来） | 已安装的 CLI 入口点 |
| `$TMUX_SOCKET`（默认 `/run/claude-guardian/tmux.sock`） | systemd（`RuntimeDirectory=`）在单元启动时，或任意 root 侧命令 | 每个实例共用的一个专用 tmux 服务端 socket，与任何交互式管理员自己在 `/tmp` 上的 tmux 服务端隔离开。这个目录属于 `$RUN_AS_USER`；上一个所有者留下的、当前没有服务端在应答的 socket 文件会被移除，而仍有服务端在应答的则会被拒绝清除 |
| `$WORKDIR`（默认：`$RUN_AS_USER` 的主目录，可按实例覆盖） | 操作者，通过配置或 `new --workdir` | `claude` 启动时所在的工作目录 |
| `$CLAUDE_SESSIONS_DIR`（默认 `$RUN_AS_USER` 的 `~/.claude/sessions`，从 `passwd` 读取） | Claude Code，不是本工具 | 只读：每个正在运行的 `claude` 会话一份 JSON 文件，以其 PID 命名；是 Remote Control 是否连接的检查、以及推一把所依据的忙碌/空闲/等待检查的数据来源 |
| `$CLAUDE_PROJECTS_DIR`（默认 `$RUN_AS_USER` 的 `~/.claude/projects`，从 `passwd` 读取） | Claude Code，不是本工具 | 只读：对话转录记录，每个工作目录一个目录；在重启后恢复对话之前会检查它是否存在 |

### 配置参考

全局变量放在 `/etc/claude-guardian/config.env` 里，这是一个纯粹的 `KEY="value"` shell 文件，被最先 source。按实例的覆盖项（`WORKDIR`、`CLAUDE_ARGS`、`CLAUDE_BIN`）放在 `/etc/claude-guardian/instances/<name>.env` 里，只针对那一个实例在之上再 source 一遍——见 `new --workdir`/`--args`/`--claude-bin`。仓库里的 `.env.example` 记录了全局默认值以供参考（本项目没有单独的应用层 `.env`——已安装的配置文件*就是*运行时配置）。

| 变量 | 含义 | 默认值 | 作用域 | 是否必需 |
|---|---|---|---|---|
| `TMUX_SOCKET` | 共享 tmux 服务端 socket 路径 | `/run/claude-guardian/tmux.sock` | 全局 | 否 |
| `RUN_AS_USER` | tmux 服务端、`claude` 和监管循环所运行的账户。由于构造原因是全局的（一台主机一个 tmux 服务端，一个 tmux 服务端一个所有者）。修改它需要重新运行 `install`，因为 systemd 单元里带有 `User=`；`run` 在不匹配时拒绝启动。对话不会跟着它走——它们仍留在旧账户的 `~/.claude` 里 | 安装时的 `$SUDO_USER`，否则为 `root` | 全局 | 否 |
| `WORKDIR` | `claude` 启动时所在的工作目录 | `$RUN_AS_USER` 的主目录，来自 `passwd` | 全局，可按实例覆盖 | 否 |
| `CLAUDE_BIN` | `claude` 可执行文件名或绝对路径；一个裸名字会以 `$RUN_AS_USER` 的身份、通过该账户的交互式登录 shell、再到它的 `~/.local/bin` 中解析 | `claude` | 全局，可按实例覆盖 | 否 |
| `CLAUDE_ARGS` | 每次（重）启动时附加传入的 CLI 参数。`--dangerously-skip-permissions` 与 `RUN_AS_USER=root` 同时出现会被拒绝——`claude` 以 root 身份运行时会拒绝这个标志，所以这个组合就是一个瞬发的重生循环 | `--dangerously-skip-permissions --remote-control`；root 安装时会改写为 `--permission-mode auto --remote-control` | 全局，可按实例覆盖 | 否 |
| `CHECK_INTERVAL_SEC` | 存活检查之间的间隔秒数 | `5` | 全局 | 否 |
| `REQUIRED_APT_PKGS` | 缺失时自动安装的 apt 软件包，以空格分隔 | `tmux uuid-runtime` | 全局 | 否 |
| `UNATTENDED_NUDGE_SEC` | 仅在无人值守时生效：一个确认对话框在没有 tmux client attach 的情况下最多可以悬空多久，超过之后会代替操作者按一次纯 Enter 回答它；`0`（默认值）表示绝不发送。一个正在工作中或停在空提示符上的会话无论如何都不会被敲入任何字符 | `0` | 全局 | 否 |
| `REMOTE_CONTROL_CHECK_SEC` | 仅在无人值守时生效：连接检查的间隔秒数。这个检查是被动的——只读会话文件、不敲入任何字符——所以默认是每个监管周期检查一次；`0` 表示禁用 | `5` | 全局 | 否 |
| `REMOTE_CONTROL_RECONNECT_BACKOFF_SEC` | 针对同一个实例，两次重连尝试之间的最小间隔秒数。重连是唯一会敲键的部分（`/remote-control`），所以这个值限制了一个无法重连的实例被敲入字符的频率 | `60` | 全局 | 否 |
| `CLAUDE_SESSIONS_DIR` | Claude Code 写入其按会话 JSON 文件的位置；只读，是让连接/断开以及忙碌/空闲/等待检查成为可能的前提 | `$RUN_AS_USER` 的 `~/.claude/sessions`（`$CLAUDE_CONFIG_DIR` 优先） | 全局 | 否 |
| `CLAUDE_PROJECTS_DIR` | Claude Code 保存对话转录记录的位置；只读，在重启后恢复对话前会检查 | `$RUN_AS_USER` 的 `~/.claude/projects`（`$CLAUDE_CONFIG_DIR` 优先） | 全局 | 否 |
| `RESUME_AFTER_RESTART` | `1`：在一次连带 tmux 会话一起消失的重启之后，让实例回到它原本正在进行的那场对话；`0`：每次都开始一场新的 | `1` | 全局，可按实例覆盖 | 否 |
| `MAX_SESSIONS` | 一旦已存在这么多实例，`new`/`resume` 就拒绝创建；`0` = 不限制 | `0` | 全局 | 否 |
| `ENSURE_DEFAULT_INSTANCE` | `1`：开机时，若压根没有任何实例会起来，就用上面的全局值创建并启动默认的 `claude-code` 实例；一台已经有已启用实例的主机永远不会被触碰。`0`：这样的主机会以空空如也的状态开机，恢复它需要手动 `new`。注意它和 `deactivate` 之间的相互作用：在 `1` 的情况下，停用*最后一个*实例会在下次开机时被撤销——这是刻意设计（保证优先于簿记），`deactivate` 会在动手前把这一点说清楚 | `1` | 全局 | 否 |

## 从零开始的搭建步骤

1. 把仓库（某个 tag，而不是分支尖端）克隆到目标 Debian 服务器上，以会话应归属的那个账户身份登录——验证方式：`git clone ...` 退出码为 0，且 `bin/claude-guardian.sh` 存在。
2. `bash bin/claude-guardian.sh check` —— 验证：打印出四个检查小节（`apt dependencies`、`session account`、`claude CLI`、`login state`），带 `[ok]`/`[missing]`/`[warn]`/`[skip]` 标记，且不修改任何东西。`session account` 小节会点名会话将以哪个账户运行，并说明 `CLAUDE_ARGS` 与那个账户是不是一个合法组合。
3. `sudo bash bin/claude-guardian.sh install` —— 验证：日志会打印 `the session will run as '<你>'`（`sudo` 背后的那个账户），以 `install complete` 结束，`grep RUN_AS_USER /etc/claude-guardian/config.env` 会点名那个账户；`systemctl cat claude-guardian@claude-code` 显示 `User=<你>` 和 `RuntimeDirectoryPreserve=yes`；`systemctl is-enabled claude-guardian@claude-code` 打印 `enabled`（默认实例被自动创建并启用），`systemctl is-enabled claude-guardian-floor` 也打印 `enabled`（开机地板机制）。然后 `ls -ld /var/lib/claude-guardian/state` —— 验证它属于那个账户，而不是 root。
4. `claude-guardian start` —— 验证：`systemctl is-active claude-guardian@claude-code` 打印 `active`。
5. `claude-guardian attach` —— 验证：把你带入一个跑在 tmux 里的活生生的 `claude` 终端（名字默认是 `claude-code`），窗格里显示一行 `/remote-control is active ... https://claude.ai/code/session_...`——那个 URL 独立于这次 SSH 会话，可以从网页或手机控制，也可以由 `claude-guardian url claude-code` 打印出来而不需要 attach。用 tmux 前缀键（默认 `Ctrl+b`）再按 `d` 来分离——**不要**用 Ctrl+C。
6. `claude-guardian new second-instance` —— 验证：`claude-guardian list` 显示两行（`claude-code`、`second-instance`），各自带有独立的 `SYSTEMD`/`TMUX`/`URL` 列，确认两者都被独立监管、可独立远程控制。
7. 从第二个终端，真正从会话内部退出 `claude`，并验证它被重新拉起——例如 `tmux -S /run/claude-guardian/tmux.sock send-keys -t =claude-code: C-c C-c`（`=`…`:` 这种写法是精确的会话匹配；不加它 tmux 会做前缀匹配，可能会命中一个名字只是碰巧同前缀的*另一个*实例）（Claude Code 把单次 Ctrl+C 当作"中断当前这一轮"，和大多数 REPL 一致；需要快速连按两次才会真正退出，跟输入 `/exit` 效果相同）。验证：在 `CHECK_INTERVAL_SEC` 之内，`claude-guardian logs claude-code` 显示一行 `respawning automatically`，该实例的 `claude` PID（`pgrep -f 'claude --permission-mode'`）已经变化，`claude-guardian attach` 再次显示一个活的会话（带有新捕获到的远程控制 URL）。
8. `claude-guardian deactivate second-instance` 之后检查 `pgrep -u "$(id -un)" -af 'claude --'` —— 验证：两个 `claude` 进程仍在运行，归属会话账户而不是 root（deactivate 只是暂停监管，见"已知局限"里关于 `KillMode` 的部分）。再执行 `claude-guardian activate second-instance` —— 验证：该实例的同一个 `claude` PID 仍然存在（监管针对既有会话恢复，而不是重新创建）。
9. `claude-guardian archive second-instance --yes` —— 验证：`claude-guardian list` 不再显示 `second-instance`；`claude-guardian archives` 显示一条对应记录，带有一份保存下来的 `scrollback.txt`；`pgrep -af 'claude --'` 只剩下 `claude-code` 这一个进程。
10. `claude-guardian resume second-instance`（或第 9 步里那个确切的 archive id）—— 验证：`claude-guardian list` 再次显示 `second-instance`，`claude-guardian attach second-instance` 会接着同一场对话，而不是重新开始一场。
11. 从会话内部断开 Remote Control（`/remote-control` → `Disconnect this session`）并分离——验证：在 `REMOTE_CONTROL_CHECK_SEC`（默认 5 秒）之内，`claude-guardian logs claude-code` 显示 `remote control disconnected ... reconnecting`，随后是一个*新的* URL，`claude-guardian url claude-code` 打印那个新 URL。之后让实例保持连接和分离状态几分钟——验证日志保持完全安静，也就是说每个周期的检查在视觉上不产生任何成本，也不敲入任何字符。为了演练重连退避机制：断开之后立即破坏重连（例如断网）：`reconnecting` 这一行每 `REMOTE_CONTROL_RECONNECT_BACKOFF_SEC` 最多出现一次，而不是每个周期都出现一次。
12. 在默认的 `UNATTENDED_NUDGE_SEC=0` 下：触发一个确认对话框（用 `--permission-mode default` 最容易：让它执行任意一条 shell 命令），分离，放置几分钟——验证：`claude-guardian logs claude-code` 从未显示 `sending Enter` 这一行，等你回来时对话框依然在等待。没有任何东西替你回答它。然后在 `/etc/claude-guardian/config.env` 里设置 `UNATTENDED_NUDGE_SEC="60"`，`claude-guardian restart claude-code`，重复以上步骤——验证：到 60 秒这个节点，日志显示 `has been waiting on a confirmation for Ns with nobody attached`，随后是 `sending Enter`，对话框随之消失。重新 attach 再分离一次——验证它不会立即再次触发（计时器在 attach 时重置）。之后把它改回 `0`。
13. 开机地板机制。对每一个实例执行 `claude-guardian deactivate <name> --yes`，直到没有一个是已启用状态——验证：最后一个会警告主机将会以空空如也的状态开机（不加 `--yes` 时，它在非交互式 shell 里会拒绝执行，而不是径直动手）。然后 `systemctl start claude-guardian-floor` —— 验证：`journalctl -u claude-guardian-floor` 显示 `no instance would come up at boot`，随后是 `instance 'claude-code' enabled and starting`，几秒之内 `claude-guardian list` 显示 `claude-code` 为 `active`/`up`。再执行一次 `systemctl restart claude-guardian-floor` —— 验证它现在记录的是 `1 instance(s) already enabled — nothing to do`，且没有出现第二个会话。把 `ENSURE_DEFAULT_INSTANCE` 设为 `"0"`，从一个空状态重复以上步骤——验证它记录 `disabled, doing nothing` 且什么都不创建。
14. `reboot` 这台主机——验证：开机之后，每一个曾被 `activate`（而不是 `deactivate`）过的实例都会重新变为 `active`，无需人工干预，`claude-guardian logs <name>` 显示 `continuing this instance's previous conversation (<uuid>)`，attach 之后显示的是重启之前的那场对话，而不是一场空的。要在不真正重启的情况下演练这一点：`claude-guardian stop <name>`，`tmux -S /run/claude-guardian/tmux.sock kill-session -t <name>`，`claude-guardian start <name>`。

本项目不使用 Docker 部署；以上步骤就是完整的部署流程。

## 数据模型 / 文件布局

```
repo/
├── bin/claude-guardian.sh   # 整个工具 —— 自包含，没有其他源文件
├── tests/run-as-user.sh     # 针对会话账户层的独立检查；不安装任何东西
├── README.md / README.zh.md
├── DESIGN.md / DESIGN.zh.md
├── .env.example             # 记录全局 config.env 变量（见"配置参考"）
└── ...
```

仓库里没有单独签入的 systemd 单元文件或配置模板：`claude-guardian install` 会从内嵌在 `bin/claude-guardian.sh` 里的 heredoc 生成这两者，所以这一份文件就是一个完整、自包含的部署产物——把它复制到任何地方并运行 `install` 就足够了，不需要仓库里的其他内容。

## 已知局限与坑

- **一台主机只有一个会话账户，而且对话不会跟着账户走。** `RUN_AS_USER` 是全局的，因为每个实例共用一个 tmux 服务端，而一个 tmux 服务端只有一个所有者。因此把一台主机从一个账户挪到另一个账户是一次迁移，而不是一次设置变更：`claude` 会把它的转录记录留在*旧*账户的 `~/.claude` 下，新账户无法读取，所以对话必须手工搬过去（而且它们的转录目录名是按工作目录派生的，工作目录通常也会一并改变）。本工具不会替你做这件事——它无从知道一个账户下的哪些对话是属于这台主机的。README 的"安装"一节有具体步骤。
- **首次运行的信任提示是代替你回答的。** 打开一个某账户从未打开过的目录时，`claude` 会问"Is this a project you created or one you trust?"，默认预选的是**No, exit**。在无人值守的情况下这是致命的：本工具为清除引导界面而盲发的 Enter 会选中它，`claude` 会退出，监管进程会把它重新拉起到同一个界面，如此循环，而日志只会显示 `claude exited`。所以监管进程会专门检测这个特定界面，并替你回答*yes*。这么做的理由是：`$WORKDIR` 是操作者为一个无人值守会话专门配置的目录，所以已经没有别人可以去问了——但这终究是一个替你做出的决定。它每个账户对每个工作目录只发生一次（`claude` 会把这次回答记在它自己的 `~/.claude.json` 里）。如果你不希望这样，就只把实例指向你自己已经打开过的目录。
- **没有任何东西阻止 `--dangerously-skip-permissions` 名副其实。** 它在这里是默认值，因为本工具存在的意义就是让无人值守的会话保持推进，而一个卡在权限提示上的会话就是一个停摆的会话。同一种取舍的有边界版本是 `CLAUDE_ARGS="--permission-mode auto --remote-control"`，这正是 root 安装时的默认值，而 `UNATTENDED_NUDGE_SEC` 是同一条轴线上的第三个刻度。请按主机分别选择，并记住这个会话携带的是会话账户的全部权限——包括，在一个拥有免密 `sudo` 的账户上，root 权限。
- **开机地板机制只在开机时运行一次，不是持续运行的。** `ensure-floor` 是一个 `oneshot`，所以在会话进行中归档最后一个实例，会让主机在下次重启（或手动执行 `claude-guardian ensure-floor` / `new`）之前一直保持无任何东西在运行的状态。这是刻意的：一个在你刚归档完一个实例几秒钟后就重新创建实例的地板机制，会让 `archive` 变得没法用，而在同一版本里加入的那条警告正是为了覆盖这种交互式场景。要记住的结论是："地板机制会兜底"这句话只对重启这一种情况成立。
- **在 `ENSURE_DEFAULT_INSTANCE=1` 时，停用最后一个实例会在下次开机时被撤销。** `deactivate` 承诺的是"开机时不会重启"，而地板机制承诺的是"始终有东西在运行"；当涉及的实例是唯一的一个时，这两者互相矛盾，地板机制会获胜。`deactivate` 会在动手之前把这一点原样打印出来，所以这个意外是提前告知的，而不是等重启之后才被发现——但一台真正打算以空闲状态开机的主机需要的是 `ENSURE_DEFAULT_INSTANCE=0`，而不是 `deactivate`。
- **地板机制的兜底实例是一场全新对话，不是你归档的那一场。** 当不存在 `claude-code` 配置时，它会用全局的 `WORKDIR`/`CLAUDE_ARGS` 写出一份新配置，新会话从空白开始。回到之前的某场对话是 `resume <archive-id>` 的职责；地板机制只保证*存在*一个会话。
- **`UNATTENDED_NUDGE_SEC`（自动敲 Enter）自 v0.6.0 起默认关闭，把它打开是一个刻意的安全取舍，而不是一个中性的便利功能。** 以下内容描述的都是你选择开启后所承担的东西；在默认值 `0` 下，这一切都不会发生，一个确认对话框只会静静等待一个真人去回答它。`--permission-mode auto` 在分类器连续拦截 3 个动作（或累计 20 个）之后会回退到一次交互式确认——这个回退机制存在的意义正是让一个真人来决定分类器没能自动放行的那件事。在无人值守的情况下发送一个纯 Enter，等同于接受当前高亮/默认选中的那个选项，**而完全不知道那个默认选项对于那个具体提示而言是不是安全的选择。** 这一点曾被 Claude Code 自身的 auto 模式分类器现场标记出来——当时监管工具正试图以这个行为启用状态重启（"defeats the human-in-the-loop safety fallback"），并在部署之前要求用户明确确认（见 `DECISIONS.md`，2026-08-16）。如果这种取舍对某次部署而言不可接受，就把 `UNATTENDED_NUDGE_SEC` 设为 `"0"` 来关闭它——文档中给出的替代方案是 `--permission-mode dontAsk` 配合一份显式的 `permissions.allow` 列表，它会对未列出的动作静默拒绝，而不是去猜一个确认对话框（更可预测，但配置工作更多）。v0.4.0 缩小了它*能作用于谁*的范围——Enter 只会发给一个 `claude` 自己报告为 `waiting` 的会话，而且只有在对话框已经悬空达到完整的间隔时长之后，这样一个有人正在其中工作的会话就不会被敲入任何字符。它没能解决的是这个残留情形：一个在 claude.ai 上的真人打开了一个对话框，然后把它放置的时间超过了 `UNATTENDED_NUDGE_SEC`，但仍然打算回来回答它——这种情况从外部看，和一个被遗弃的会话毫无区别，而且在 v0.4.0 上线的当天，它就在生产环境里被实际观察到了。没有任何信号能区分这两种情况，所以 v0.6.0 不再尝试区分：这个功能默认关闭，除非操作者主动打开，而循环在打开之后仍然遵循同一条只对 `waiting` 生效的规则。打开这个开关的人，是在"一个被遗弃的实例能自行解套"和"除了我以外没有人能回答权限提示"之间，选择了前者。
- **`claude-guardian install`/`new` 会以非交互方式自动安装缺失的 apt 软件包**（`DEBIAN_FRONTEND=noninteractive apt-get install -y`）。默认情况下这指的是 `tmux` 和 `uuid-runtime`。如果你扩大了 `REQUIRED_APT_PKGS`，请仔细审视你要它无人值守地安装的是什么。
- **`claude` 二进制缺失会让一个实例的服务进入约一分钟的失败重启循环，然后停止。** `preflight_enforce` 在找不到 `claude` 时会硬性失败（这是设计使然——本工具绝不安装它）。单元里的 `StartLimitBurst=10` / `StartLimitIntervalSec=60` 会阻止 systemd 无限重启；之后该实例会停留在 `failed` 状态，直到你安装好 `claude` 并运行 `systemctl reset-failed claude-guardian@<name> && claude-guardian start <name>`。
- **`claude-guardian deactivate <name>`（`systemctl disable --now`）不会杀掉活着的会话——这要求单元里带有 `KillMode=process`，已对照真实二进制验证过。** systemd 的*默认* `KillMode` 是 `control-group`，它会在 stop/restart 时向整个 cgroup 发送 SIGTERM，包括 tmux 服务端和 `claude` 本身（这一点是现场踩到的：单元最初的版本没有显式设置 `KillMode`，一次 `systemctl restart` 悄无声息地杀掉并重建了整个会话）。有了 `KillMode=process`，只有被跟踪的循环 PID 会收到信号，因此 `claude` 及其 tmux 会话在该实例监管进程的 `stop`/`restart`/`deactivate` 中都能存活下来。一个副作用是：systemd 会在下一次 `start` 时打印一条无害的 `Found left-over process ... in control group` 提示，因为之前那个 `claude` 进程仍然在那个 cgroup 里——这是预期行为，不是错误。要真正结束一个实例的对话，用 `claude-guardian archive <name>`（破坏性操作，默认需要确认）；要拆除一切，用 `claude-guardian purge`（同样默认需要确认，且不会碰归档——见下文）。
- **在加入多实例支持时，`purge` 的爆炸半径从"一个会话"扩大到了"所有活着的实例"**（见 `DECISIONS.md`，2026-08-17）。它现在会打印活着的实例数量，并在杀掉任何东西之前要求交互式确认（或 `--yes`），而且刻意永远不删除 `/var/lib/claude-guardian/archive/`——如果你也想清掉个别归档，用 `rm-archive` 显式移除。
- **有三种行为现在依赖 Claude Code 的内部文件。** `$CLAUDE_SESSIONS_DIR/<pid>.json`（字段 `bridgeSessionId`、`status`、`statusUpdatedAt`）以及 `$CLAUDE_PROJECTS_DIR/<经过转义的工作目录>/<id>.jsonl` 都不是一份文档化的、被承诺的接口；未来的 Claude Code 版本可能会重命名、迁移或不再写入它们。全部已对照 2.1.202 验证过。当对应文件缺失或不可读时，每一种行为都是退化而不是崩溃：连接检查会回退到发送 `/remote-control` 并从画面上读取 URL（这正是 v0.2.0 一直以来的做法），推一把功能会回退到墙上时钟（同样是 v0.2.0 的行为），而一次无法被确认的 resume 只会简单地开始一场新对话。这两条路径在配置里都是可覆盖的（`CLAUDE_SESSIONS_DIR`、`CLAUDE_PROJECTS_DIR`），所以一个被挪动的文件可以直接指过去，而不需要改脚本。转录目录名是通过把工作目录里每一个不在 `[A-Za-z0-9]` 范围内的字符替换成 `-` 得到的；如果这个约定发生变化，重启后恢复对话的功能会悄无声息地找不到转录记录，每次重启都会重新开始一场新对话——由于不会报任何错，这正是应该留意的症状。
- **重连 Remote Control 会往 tmux pane 里发送真实的按键**（`C-u`、`/remote-control`、`Escape`），实例创建时的首次捕获（紧跟在引导阶段的两次 Enter 之后）同样如此。和 v0.2.0 不同的是，这不再按定时器触发——只有在上面那个检查确认 Remote Control 确实已断开时才会发生——但如果 `claude` 恰好在那个精确时刻停在一个非正常提示符的画面上（比如那两次 Enter 之外的另一个引导步骤），这些按键就可能被敲到错误的地方。虽然无害（这一步不会自动确认任何东西，Escape 是关闭而不是选中），但可能会留下需要通过 `claude-guardian attach <name>` 手动清理的杂散文字。这和引导阶段的双 Enter 清屏、以及无人值守的推一把功能所接受的是同一类"盲发按键"取舍；见上面 `UNATTENDED_NUDGE_SEC` 那一条。
- **一次重连会改变实例的 `claude.ai/code/...` URL。** 对话本身不受影响——还是同一个 `claude` 进程、同一个 `claude_session_id`——但之前收藏的链接会失效。没有办法既真正重新连接、又保住旧的 URL，所以本工具的取舍是优化"连接始终在线"，并预期这个 URL 会被按需取用（`claude-guardian url <name>`），而不是被事先保存下来。
- **`resume` 只有在归档里记录了 `claude_session_id` 的情况下才能重建一场对话。** 对于本工具自身 `archive` 命令创建的归档，这一点始终成立（这个 id 在实例创建时被捕获并一路带过来），但如果一个归档目录被手工改动过、或者 `meta.env` 丢失了，`resume` 会拒绝执行，转而指向原始的 `scrollback.txt`，而不是去猜。
- **`install` 会原地迁移一次 v0.1.0 的单实例部署**（`migrate_legacy_unit`）：它会禁用/移除旧的 `claude-guardian.service`，并针对*同一个* tmux 会话启用新的 `claude-guardian@claude-code.service`。这依赖于新旧两个单元里的 `KillMode=process` 都成立（上面已验证）——如果未来某次 systemd 单元变更去掉了这个设置，这条迁移路径就需要在信任它之前重新对照一个活会话验证一次。已对照一台真实生产主机验证过：tmux pane 的 PID 与存活状态在 `install` 前后紧挨着的时刻都没有变化。
- **一个被迁移过来的既有会话，在它真正被重建之前，永远不会获得一个被跟踪的 `claude_session_id`、`workdir` 或捕获到的 URL**——这一点是在上面同一次真实迁移中发现的。`respawn-pane` 只会重放 tmux 在会话最初创建时存下的*原始*命令；对于一个早于 v0.2.0 就存在的会话，那条原始命令里没有 `--session-id`，所以任何一次崩溃重生都无法追溯性地给它补上一个。实际影响是：`list` 对该实例的工作目录会显示 `-`，它的 URL 仍然能找到（这来自 `claude` 自己的会话文件，每个正在运行的会话都有，只是缺失被跟踪的 id 会跳过一半的 PID 复用交叉核对），而对该实例执行 `archive` 会保存一个空的 `claude_session_id`——`resume` 之后会正确地拒绝执行，转而指向原始回滚缓冲区，而不是去猜。给一个被迁移的实例真正补上一个可恢复的会话 id 的唯一办法，是让它的 tmux 会话真正结束并被重新创建（例如先刻意 `archive` 它一次，然后再 `resume`/`new` 回来）——没有原地补写这种做法，手工编辑它的状态文件只会捏造出一个 `claude` 从未真正使用过的 id。
- **用 tmux 前缀键分离，不要用 Ctrl+C——而且单次 Ctrl+C 反正也杀不死 `claude`。** 已对照真实 CLI 验证过：Claude Code 把一次 Ctrl+C 当作"中断当前这一轮"（和大多数 REPL 一样），而不是退出——窗格保持存活，什么都不会被重新拉起。需要快速连按两次 Ctrl+C（或 `/exit`）才能真正终止进程，此时窗格才会死掉，监管进程才会把它重新拉起，这符合最初的需求——一次刻意的杀进程绝不能让活着的实例数量归零。不管需要按几次 Ctrl+C 才能退出，这都不是一种干净的离开会话的方式——务必使用 tmux 前缀键 + `d`。
- **如果你这份仓库的工作副本存放在带有固定 `file_mode` 选项的 CIFS/SMB 挂载文件系统上（NAS 支撑的开发环境中常见），对 `bin/claude-guardian.sh` 的 `chmod +x` 可能是一次静默的空操作**（退出码 0，权限位没有变化——开发期间实际踩到过）。可执行位是在提交时用 `git update-index --chmod=+x bin/claude-guardian.sh` 直接记录进 git 树里的，所以一次正常的 `git clone` 落到一个支持真实权限位的文件系统上，检出来就自带可执行属性。如果你本地的工作副本无法保存可执行位，就显式用 `bash bin/claude-guardian.sh ...` 调用脚本，而不是 `./bin/claude-guardian.sh`。
- **登录状态只在 `install` 时被强制检查，不是持续检查的。** `install` 在 `claude auth status` 失败时会硬性拒绝（已对照两种真实状态验证过：已登录、以及一个没有任何凭据的隔离 `HOME`——分别退出 0 和 1）。一旦安装完成，`run` 只会在认证缺失或之后丢失时发出警告——服务会持续重试，`claude` 会在下一个人 attach 时展示它正常的交互式登录流程，而不是拒绝启动。这是刻意设计，不是疏漏：一个原本正常工作、后来失去认证的服务（token 过期、会话被吊销）应该继续尝试提供服务，而不是陷入一个重启-失败循环。
- **`REMOTE_CONTROL_CHECK_SEC` 只限定一次断开的连接最多能被漏检多久，仅此而已。** v0.2.0 把这个值设为 1200 秒，是为了停留在 Anthropic 文档所说的约 30 分钟"could not reach the Remote Control server"窗口之内，前提假设是事先重新执行 `/remote-control` 就能防止连接过期。这个假设是错的（见 `DECISIONS.md`，2026-08-17），这让一个 20 分钟的数字承担了一份它从未被选来承担的工作：它变成了"一个实例最多能不可触达多久"，而在生产环境里，它确实就是这样表现的。自 v0.6.0 起，这个检查每个周期（5 秒）都会跑一次——它只是一次不敲入任何字符的文件读取，所以它慢下来从来就没有过理由——旧的那个变量已经不存在了。一份仍然设置了 `REMOTE_CONTROL_REFRESH_SEC` 的配置会在循环启动时收到一条警告；那个设置本身会被忽略。
- **一次持续失败的重连会按退避策略重试，而不是每次检查都重试。** `REMOTE_CONTROL_RECONNECT_BACKOFF_SEC`（60 秒）存在的原因是：重连是唯一会往会话里敲字符的步骤——没有它，一个 Remote Control 始终连不回来的实例会每 5 秒就被敲入一次 `/remote-control`。当 `claude` 完全没有写出可用的会话文件时，没有任何东西能确认重连是否成功，这种情况会回退到一个慢得多的内部重试间隔（1200 秒），而不是 60 秒的退避。
- **无人值守推一把/连接检查的计时器只从监管循环本身（重新）启动那一刻开始计数，而不是从会话实际最后一次被人使用的那一刻开始。** 这是一个曾被现场捕获的真实 bug：最初的版本把两个计时器都初始化为 `0`（纪元时间），所以针对一个本已无人值守的会话执行 `systemctl restart`，会立即触发一次推一把和一次刷新，而不是等待配置的间隔耗尽。修复方式是在循环启动时用当前时间给两个计时器都做种。

## 如何扩展

- **新的预检检查**要同时加进 `preflight_report`（只报告）和 `preflight_enforce`（可能会修改/硬性失败）——保持两者同步，这样 `check` 才能准确预览 `run`/`install`/`new` 将会做什么。
- **新的全局配置变量**通过同时扩展 `bin/claude-guardian.sh` 顶部附近的默认值代码块和 `write_default_config` 里的 heredoc 来添加，再加上本文档"配置参考"表格里的一行，以及 `.env.example` 里的一行。**新的按实例覆盖项**则要走 `write_instance_file` 和一个新的 `new --flag` 选项——保持这个集合精简；`WORKDIR`/`CLAUDE_ARGS`/`CLAUDE_BIN` 之所以被选中，是因为它们是目前唯一真正出现过按实例需求的旋钮（见 `DECISIONS.md`，2026-08-17）。
- **一个按实例的 `TMUX_SOCKET` 或一套 HTTP 控制 API**在加入多实例支持时都被考虑过并被否决——重新引入任何一个之前，见 `DECISIONS.md`，2026-08-17，"Rejected" 一节。
- **新的实例生命周期子命令**应遵循既有模式：只通过 `instance_file`/`state_get`/`state_set` 读写状态，绝不触碰另一个实例的文件，并同步更新 `usage()`（那个注释块）和 `main()` 里的 case 语句——`usage()` 是通过 `sed` 从那个注释块生成的，只要两者在同一次改动里一起编辑，就不可能出现二者不一致的漂移。
