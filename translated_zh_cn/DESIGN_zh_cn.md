# claude-code-guardian — 设计文档

[English](../DESIGN.md) | **简体中文**

> 译自 `DESIGN.md`（v0.10.1）。如有冲突，以英文版为准。

> 本文档的成功标准：另一个人，在另一台机器上，能够仅凭本文档重建这个项目。假设读者看不到你的机器。

## 目标与非目标

**目标**
- 在 Debian 系服务器上，让一个或多个具名的 `claude`（Claude Code
  CLI）实例并发存活，每个实例都运行在自己可分离的终端多路复用器会话中，
  这样操作者可以在任何时候远程接管其中任何一个——既可以通过 Claude Code
  自带的 Remote Control（一个 `claude.ai/code/...` URL，可从网页或手机
  控制），也可以通过 SSH + `tmux attach`。为什么要从最初的单会话设计
  改为这种方式，见 `DECISIONS.md`，2026-08-17。
- 让每个实例的远程控制 URL 都无需接入该实例即可取得——在创建时以及每次
  无人值守的刷新时自动捕获，按实例存储，由 `list`/`url` 打印。这样做的
  意义在于，操作者可以完全通过另一个驱动本工具 CLI 的 Claude Code 会话
  来创建、发现并连接一个会话，而完全不需要自己打开终端。
- 让一个实例可以被**暂停**（`deactivate`/`activate`：停止/恢复监督，
  tmux 会话继续运行），并且这与被**归档**（`archive`/`resume`：保存
  回滚缓冲区 + 会话 id，然后杀掉进程；之后可通过 `claude --resume`
  重新创建）相互独立——这是刻意设计成两个影响范围不同的独立操作。
- 挺过重启（每个已启用实例的服务在开机时启动）。
- **保证的是下限，而不仅仅是恢复能力。** 最初的需求
  （`DECISIONS.md`，2026-08-16）是"至少始终有一个会话可用"。直到
  v0.9.0 之前，没有任何机制强制执行这一点：它之所以成立，仅仅是因为
  `install` 启用了默认实例，而且此后没人把它归档过；而一台最后一个
  实例被归档或停用的主机，会在悄无声息中启动却没有任何会话。现在有
  两种机制把这变成了工具的一项属性——一是在数量归零之前发出警告，
  二是 `claude-guardian-floor.service`，它会在开机时、当没有其他任何
  东西会启动实例的情况下，重新创建默认实例（`ENSURE_DEFAULT_INSTANCE=0`
  可退出此机制）。
- 挺过 `claude` 进程本身被杀死——Ctrl+C、崩溃、`exit`、OOM
  kill——做法是在数秒内自动重启它，且不丢失周围的会话环境。
- 在长时间无人值守的情况下真正保持可达，而不仅仅是"进程在跑"：
  在数秒内察觉 Remote Control 连接掉线并修复它，这样一个实例就不会
  存在"活着但连不上"超过一个检测周期的情况。清除一个 `auto` 权限模式
  退回时产生的确认提示也是可选功能，但默认关闭——回答一个提示是一个
  决策，而本工具的职责止步于保持会话可达（见"已知局限"）。
- 运行预检：确认所需的 `apt` 软件包已存在（缺失时自动安装）、`claude`
  二进制文件已存在（硬性要求，绝不自动安装）。登录状态通过
  `claude auth status` 检查（这是权威判断，不是靠文件是否存在来猜测）
  ——`install`/`new` 在未登录时拒绝继续（一个从未登录过的实例，只会
  坐在那里不断重生一个没人能用的会话），而 `run` 只是发出警告，
  这样一个之后失去授权的实例会持续重试而不是拒绝启动。
- 在不强加限制的前提下提供资源/成本增长的护栏：`new` 在已存在
  `MAX_SESSIONS` 个并发实例时拒绝执行——每个实例都是一个独立的
  `claude` 进程，也是一份独立的 token 成本。默认值是 `0`（无限制），
  因为操作者想要多少个并发对话是一项工作流决策，本工具无法替其猜测；
  这个开关是留给确实想要设置上限的人的。
- 用一个简短、易记的 CLI（`claude-guardian <verb> [<name>]`）即可操作。

**非目标**
- 安装或更新 Claude Code CLI 本身。假定操作者已经安装并完成认证
  （或者通过本工具管理的会话以交互方式完成认证）。
- 从零构建一个远程访问传输层。本工具依赖 Claude Code 自带的
  `--remote-control` 功能作为主要远程通道，并假定可通过 SSH 访问主机
  作为后备方案；本工具只负责让 `tmux` 会话保持存活，供两者接入。
- 提供一个用于远程管理实例的生命周期控制 API（HTTP/REST 或其他形式）。
  生命周期管理仅限 CLI，要么通过 SSH 驱动，要么从本工具自己管理的
  Claude Code 会话内部驱动（见 `DECISIONS.md`，2026-08-17，"Rejected"）。
- GUI、网页仪表盘或通知系统。状态通过 `claude-guardian list` /
  `systemctl status` / `journalctl` 读取。

## 架构

每个具名实例都运行与最初单会话设计相同的两个独立监督层，只是按实例名
参数化——每个 `claude-guardian <name>` 对应一个 systemd 单元实例和一个
tmux 会话，所有 tmux 会话共享同一个 tmux 服务器：

```
                     某个实例的监督进程开机 / 崩溃
                                    |
                                    v
   systemd (Restart=always) ---> claude-guardian run <name>  （前台循环）
   claude-guardian@<name>.service    |
   （每个名字一个实例，              | 每隔 CHECK_INTERVAL_SEC：
    源自一个模板单元）                | tmux has-session? / pane_dead? / client attached?
                                      | （若无人值守：每个检测周期都检查
                                      |  Remote Control 是否仍连接，
                                      |  未连接则重新连接；此外，
                                      |  默认关闭，可选地清除一个
                                      |  没人回答的对话框——见下文）
                                      v
                     tmux 会话 "<name>"（remain-on-exit 已开启）
                     ——可能有若干个中的一个，全部运行在
                       同一个 tmux 服务器 / $TMUX_SOCKET 上
                                    |
                                    v
        claude --dangerously-skip-permissions --remote-control --session-id <uuid>
        （或者用 --resume <uuid> 代替 --session-id：一个通过
         `claude-guardian resume <archive-id>` 创建的实例，
         或者一个重启后回到已有对话的实例）
                                    ^                       ^
                                    |                       |
                        操作者：ssh + `claude-guardian     操作者：claude.ai
                        attach <name>`（tmux attach）        网页/手机（Remote
                                                              Control）——URL 从
                                                              claude 自己的会话
                                                              文件中读取并存储，
                                                              这样 `claude-guardian
                                                              url <name>` 无需接入
                                                              即可打印它
```

- **systemd 层**从以下情况恢复：重启、某个实例的监督脚本崩溃、该实例的
  tmux 服务端状态消失。`Restart=always` 加上有上限的 `StartLimitBurst`
  防止在 `claude` 确实缺失时无限空转（见"已知局限"）。`KillMode=process`
  使得 `stop`/`restart`/`deactivate` 只向被跟踪的循环 PID 发信号，绝不
  会向 tmux 服务器或 `claude` 发信号（已在实机验证——默认的
  `KillMode=control-group` 会杀掉整个会话，这就是为什么这里要显式设置，
  而不是用 systemd 的默认值）。因为它是一个*模板*单元
  （`claude-guardian@.service`），每个实例都是该模板的一个独立
  systemd 单元实例（`claude-guardian@work.service`、
  `claude-guardian@personal.service`……），可以单独启动、停止、启用或
  禁用，而不影响其他任何实例。该模板还带有 `User=$RUN_AS_USER`，以及
  针对默认 socket 路径的 `RuntimeDirectory=claude-guardian` 配合
  `RuntimeDirectoryPreserve=yes`——见下面的账户层。
- **账户层**不是一个监督层，但它横跨所有监督层：root 负责安装和监督，
  而 tmux 服务器、每个 `claude` 进程，以及 `claude` 写入的一切都属于
  `$RUN_AS_USER`。这个原因是具体的，而不只是出于卫生考虑——`claude`
  在以 root 身份运行时会拒绝 `--dangerously-skip-permissions`，而一个
  停下来等待权限确认的无人值守会话就是一个卡死的会话，所以工具自身的
  目标迫使必须做这个拆分。由此带来的后果，每一条都是代码不得不改动的
  地方，而不只是一句意图声明：
  - 该账户是全局的，而不是按实例配置的。每个实例共享同一个 tmux 服务器，
    而一个 tmux 服务器只属于一个账户，所以一台主机只有一个会话所有者。
  - 只有 root 能创建 `/run/claude-guardian`（一个 tmpfs，开机时为空）
    和 `/var/lib/claude-guardian/state`，但真正往里面写入的是无特权的
    循环进程。systemd 的 `RuntimeDirectory=` 会在 `ExecStart` 之前创建
    socket 目录并把它交给 `User=`；`RuntimeDirectoryPreserve=yes` 是必须
    的，因为默认行为会在某个监督单元停止的那一刻删除该目录——连同其中
    存活的 socket——这恰恰是 `KillMode=process` 要防止的事情。状态目录
    由每一条 root 侧命令负责创建并 chown，所以一台 `RUN_AS_USER` 发生
    变化的主机会在下一次 `install` 时自我修复。
  - 关于 `claude` 的每一个问题都必须*以该账户的身份*来问：它的二进制
    文件在哪里（`~/.local/bin/claude` 不在任何 systemd 的 `PATH` 里）、
    它是否已登录（登录状态属于某一个账户——root 的登录状态说明不了
    任何问题），以及哪个 `~/.claude` 保存着会话文件和记录。root 通过
    `runuser` 来问；答案从 `passwd` 中解析，而不是从 `$HOME` 中解析，
    因为在 `sudo` 下 `$HOME` 仍然是 root 的。
  - 当 `run` 运行时所处的账户与配置中指定的账户不一致时，它会拒绝启动。
    这意味着已安装的单元早于当前配置，如果照旧启动，就会在错误的账户下
    构建 tmux 服务器——以及那个对话。
- **开机保底层**从一种另外两层都无法恢复的情况中恢复过来，因为那两层
  都是按实例运作的：即根本没有实例可供监督的情况。
  `claude-guardian-floor.service` 是一个独立的 `oneshot` 单元，和各个
  实例一样是 `WantedBy=multi-user.target`，它每次开机运行一次
  `claude-guardian ensure-floor`。它统计有多少个实例真正会启动起来——
  即在 `$INSTANCES_DIR` 中有配置文件*并且*有一个已启用的单元，因为
  `deactivate` 会保留配置文件——如果这个数字是零，它就重新创建默认实例
  并启动它。已有的 `claude-code` 配置会被复用而不是覆盖（这对应
  `deactivate` 的情形，操作者的工作目录/参数是他们自己的）；只有真正
  缺失的配置才会用全局默认值写出。它用 `systemctl start --no-block`
  来启动实例，绝不用 `enable --now`：这个单元运行在开机事务内部，
  如果在这里阻塞等待另一个单元的启动任务，就会导致开机死锁。
- **tmux 层**从以下情况恢复：`claude` 进程因任何原因退出，同时*会话*
  （其回滚缓冲区、其 pty）得以保留。这就是为什么在会话内发送 Ctrl+C
  是安全的、不会丢失状态——只有 `claude` 退出并被重新启动，tmux 会话
  本身继续存活。（注：Claude Code 本身把单次 Ctrl+C 当作"中断当前这一
  轮"，而不是退出——需要连续两次，或者 `/exit`，才会真正终止进程；
  已针对真实二进制文件验证过。）所有实例共享同一个 tmux 服务器
  （一个 `$TMUX_SOCKET`），每个实例一个会话，以实例名命名——tmux
  本身已经原生支持多路复用会话，所以为每个实例单独起一个服务器只会
  增加运维开销而没有任何好处（见 `DECISIONS.md`，2026-08-17）。
- **会话身份**：在创建时，每个实例要么被赋予一个全新的
  `claude --session-id <uuid>`（通过 `uuidgen` 生成），要么被赋予一个
  指向已有对话的 `claude --resume <uuid>`。无论哪种情况，该 id 都被
  写死在该 tmux 面板最初的命令行中，所以每次崩溃后的 `respawn-pane`
  都会自动复用同一个 id——重新生成延续的是同一个对话，绝不会悄悄分叉出
  一个新对话。该 id 记录在按实例存储的状态文件中
  （`/var/lib/claude-guardian/state/<name>.state`），这样 `archive`
  就能保存它，`resume` 就能复用它，而该实例在重启后也能找回同一个对话。
- **在重启后保住对话不丢失**：`respawn-pane` 只覆盖 `claude` 死掉而其
  tmux 会话仍然存活的情形。重启会把整个 tmux 服务器一并带走，所以
  会话要从头构建——而在 v0.4.0 之前，这意味着每次开机都是一个全新的
  空对话，而之前的对话被留在磁盘上，只能靠手动才能找到。现在
  `create_session` 按以下顺序优先选择：一个显式的
  `RESUME_SESSION_ID`（由 `resume <archive-id>` 设置）；该实例自己
  状态中记录的最后一个 `claude_session_id`（如果 `RESUME_AFTER_RESTART=1`
  且其记录文件仍在磁盘上）；否则就是一个全新的 `uuidgen` id。记录文件
  检查是保持这一切诚实的关键——它是"继续那个对话"和"塞给 `claude`
  一个它从未听说过的 id"之间的分界线。如果 `claude` 仍然拒绝这次
  resume，它会立即退出，而不是让监督进程每隔 `CHECK_INTERVAL_SEC`
  就重建一次同样会失败的命令，`create_session` 会察觉这个死掉（或者
  已经消失）的会话一次，然后改用一个新对话重试。
- **无人值守保活**（见 `DECISIONS.md` 2026-08-16 "始终可远程控制"）：
  当 `tmux list-clients` 显示没有人接入某个实例的会话时，它的循环会
  (a) 检查 Remote Control 是否仍然连接，未连接则重新连接，以及
  (b)——仅当操作者通过把 `UNATTENDED_NUDGE_SEC` 设置为大于 `0` 的值
  选择启用时——发送两次回车，间隔一秒，用于清除一个没人回答的确认
  对话框。这两者都会在有客户端接入的那一刻立即停止（每个检测周期都
  会检查）。两者运行在截然不同的时钟上，v0.6.0 把它们分开是有原因的
  （见 `DECISIONS.md`，2026-08-17 "每个检测周期都检查连接"）：(a) 是
  被动的——它只读一个文件，不输入任何内容——所以它每隔
  `REMOTE_CONTROL_CHECK_SEC`（默认 5 秒，即每个检测周期）就运行一次，
  因为一个掉线的连接从 claude.ai 那一侧是不可见的，掉线的每一秒都是
  操作者原本可以正常访问一个其实一切正常的会话、却无法访问的一秒。
  只有重新连接这一步会输入内容，而且它单独受
  `REMOTE_CONTROL_RECONNECT_BACKOFF_SEC`（默认 60 秒）的速率限制。
  (b) 顾名思义会输入内容，代替操作者做决定，因此默认关闭。"没有人
  接入"对它来说是必要条件而非充分条件：该循环还会去问 `claude` 该
  会话正在做什么，只有对真正卡在一个对话框上的会话才会输入内容——
  见下方的**何时允许 nudge 输入内容**。`create_session` 在启动
  `claude` 之后会立即发送同样的双击回车，不受该设置影响：一次真正
  意义上的首次运行可能会显示一个引导/信任界面，需要两次回车才能清除，
  而此时还不存在任何会被回车影响的对话内容——然后它会同步记录一次
  URL，这样 `new` 就能立即打印出来，而不必等待长达
  `REMOTE_CONTROL_CHECK_SEC` 的时间。如果 `claude` 已经停在其正常的
  提示符处，再多发一次回车也只是一次无害的空操作，所以总是发送两次、
  而不去尝试判断当前显示的是哪个界面，并没有坏处。
- **"仍然连接吗？"是如何判断的**（见 `DECISIONS.md`，2026-08-17
  "读取 claude 的会话文件"）：Claude Code 会为每个正在运行的会话在
  `$CLAUDE_SESSIONS_DIR`
  （`${CLAUDE_CONFIG_DIR:-$HOME/.claude}/sessions`）下写入一个 JSON
  文件，以该会话的 PID 命名，其 `bridgeSessionId` 字段在连接期间保存
  Remote Control 会话 id，断开后变为 `null`。一个实例的 `claude`
  *就是*它的 tmux 面板命令，所以 `#{pane_pid}` 可以直接命名该文件。
  读取它既能回答"Remote Control 是否仍然在线？"，也能回答"当前的
  `claude.ai/code/...` URL 是什么？"，而不需要向该会话输入任何内容——
  这一点很重要，因为该会话此刻很可能正有真人通过 Remote Control 在
  操作——Remote Control 不是 tmux 客户端，所以一个正被积极使用的实例
  在这里看起来仍然是"无人接入"。该文件通过文本方式匹配（不依赖
  `jq`/`python`），并与该实例自己记录的 `pid` 和跟踪的
  `claude_session_id` 交叉核对，这样一个被复用的 PID 就不会返回别人
  的会话。重新连接是唯一会发送按键的一步：`/remote-control` 在
  Remote Control 关闭时会将其打开，而在它已经打开的情况下，只会弹出
  一个信息性对话框（"Disconnect this session" / "Show QR code" /
  "Continue"），随后的一次 Escape 会关闭它而不做任何选择。**对一个
  自认为仍然连接着的会话重新运行 `/remote-control` 不会刷新任何
  东西**——这个错误的假设正是 v0.2.0 保活机制的全部基础，也是本机制
  在动手之前要先检查的原因。
- **nudge 何时才被允许输入内容**（见 `DECISIONS.md`，2026-08-17
  "只 nudge 真正卡住的会话"和"默认停止代答对话框"）：首先，仅当
  操作者主动开启时才会生效——`UNATTENDED_NUDGE_SEC` 默认为 `0`，在
  `0` 的情况下绝不会向一个正在运行的会话发送任何回车，没有任何例外。
  当它被开启时，同一个会话文件还带有一个 `status` 字段，该循环依据
  这个字段而不是墙钟时间来决定是否 nudge。三种取值，全部在 2.1.202
  上被实机观测到：`busy`（正在某一轮中）、`idle`（停在空提示符处）、
  以及 `waiting`（卡在一个确认对话框上）。只有 `waiting` 才有理由
  发送回车，而且只有当它已经保持该状态达到 `UNATTENDED_NUDGE_SEC`
  这么久之后才会发送——这个时长从 `statusUpdatedAt` 读取，所以倒计时
  是从对话框出现的那一刻开始的，而不是从监督进程碰巧查看的那一刻
  开始。除此之外的一切都不予理会，而正是这一点最终使得一个正被人
  从 claude.ai 上操作的会话是安全的：它没有 tmux 客户端接入，看起来
  像是被弃置了，但它读到的状态是 `busy` 或 `idle`，绝不会是
  `waiting`，除非确实有一个对话框在那里悬而未决。`updatedAt` 曾被
  尝试过并被否决：它记录的是状态的*转变*，所以一个已经处于 busy
  状态二十分钟的会话，其时间戳仍然停留在二十分钟前，看起来就像被
  弃置了（在维护者自己一个正处于某一轮中的实机会话上观测到这个
  问题）。当不存在可用的会话文件时，该循环会退回到 v0.2.0 的行为，
  仅按经过的时间来 nudge。
- 这两层是刻意按实例相互独立的：`claude-guardian deactivate <name>`
  （`systemctl disable --now`）只停止该实例的*监督循环*；它不会杀掉
  它正在运行的 tmux 会话，所以一个正在对话中的操作者不会因为例行维护
  而被切断——`activate <name>` 会针对同一个仍在运行的会话恢复监督。
  一个实例的彻底拆除是一个独立的、显式的、破坏性的步骤：
  `archive <name>`（见下文）。工具本身的彻底拆除是 `uninstall`（仅
  systemd 模板，每个实例的配置/会话都不受影响）与 `purge`（拆除一切：
  每一个会话、socket、每一份配置、已安装的二进制文件——但绝不包括
  `/var/lib/claude-guardian/archive/`，见 README）之分。
- **归档 / 恢复**：`archive <name>` 停止监督，把完整的回滚缓冲区
  （`tmux capture-pane -pS -`）以及该实例的 `claude_session_id` 保存到
  `/var/lib/claude-guardian/archive/<name>-<ts>/`，然后杀掉 tmux
  会话——这是一个刻意为之、默认需要确认的破坏性操作（见
  `DECISIONS.md`，2026-08-17，"archive 会杀掉进程"）。
  `resume <archive-id> [new-name]` 会用设置了 `RESUME_SESSION_ID` 的
  方式从该归档重新创建一个实例，这样 `create_session` 就会传入
  `--resume <uuid>` 而不是铸造一个新 id——操作者就能在同一个对话中
  接着往下进行。

## 技术栈

| 层 | 选择 | 版本 | 原因 |
|---|---|---|---|
| 进程监督 | systemd | （Debian 默认） | 每个目标操作系统上都已经预装；原生的开机集成与重启策略，不需要额外照看一个守护进程。 |
| 会话多路复用 | tmux | Debian stable 软件包 | 提供可脚本化的存活信号（`#{pane_dead}`）和 `respawn-pane`，不像 `screen` 那样需要轮询进程表。 |
| 实现语言 | 类 POSIX 的 Bash | bash（Debian 默认的 `/bin/bash`） | 整个工具做的就是进程编排以及对 `tmux`/`systemctl`/`apt-get` 的外壳调用；引入一个脚本运行时只会增加依赖而没有任何好处。 |

被否决的替代方案及每一个选择背后的理由都记录在 `DECISIONS.md` 中——
此处不再重复。

## 复现要求

### 环境

- 操作系统：Debian 或其衍生版本（Ubuntu 等），以 `systemd` 作为
  PID 1，并且有 `apt`/`dpkg` 可用。
- 运行时：`bash`（默认已存在）、`tmux`（预检时若缺失则自动安装）。
- 权限：分离的。每一条管理性命令都需要 root（`sudo` 即可）——
  它们管理系统级 systemd 单元、安装 apt 软件包，并写入 `/etc`、
  `/var/lib` 和 `/run`。被监督的会话则不需要：监督循环、tmux 服务器
  和 `claude` 都以 `$RUN_AS_USER` 身份运行，`install` 会从
  `$SUDO_USER` 取得该值，只有在没有可继承的账户时才回退为 root。
- 当 `$RUN_AS_USER` 不是 root 时，需要 `runuser`（util-linux）：
  root 就是靠它来解析该账户的 `claude`、检查其登录状态，以及接入
  其 tmux 服务器的。
- 硬件：几乎可以忽略；只是一个每隔几秒醒来一次的空闲 bash 循环。
- 依赖恢复命令：无——本项目没有任何包管理器依赖，只有 `bin/` 下
  唯一的一个 shell 脚本。

### 外部依赖

| 项目 | 来源 | 存放位置 |
|---|---|---|
| `claude`（Claude Code CLI） | 由操作者事先安装并完成认证——本工具不负责安装它 | 位于 `$RUN_AS_USER` 的 `PATH` 中的任意位置（会显式查找该账户的`~/.local/bin`，因为服务账户的 `PATH` 常常不包含它），或者将`CLAUDE_BIN` 指向一个绝对路径。**以该账户的身份**进行解析和登录检查，而不是以运行该命令的人的身份 |
| `runuser`（util-linux） | 标准 Debian/Ubuntu 安装中已存在 | root 借此以 `$RUN_AS_USER` 身份行事：解析 `claude`、检查`claude auth status`，以及 `attach` 到该账户的 tmux 服务器。仅当会话账户不是 root 时才需要 |
| `uuidgen`（`uuid-runtime` 软件包） | 预检时若缺失则自动安装，与 `tmux` 相同 | 每次创建/恢复实例时使用一次，用于铸造或复用一个`claude --session-id`/`--resume` 的值 |
| Claude Code 的按会话文件（`$CLAUDE_SESSIONS_DIR/<pid>.json`，字段 `bridgeSessionId`、`status`、`statusUpdatedAt`） | 由 `claude`本身在会话运行期间写入——无需安装任何东西 | 读取它以判断某个实例的 Remote Control 是否仍然连接、取得其当前的`claude.ai/code/...` URL，以及判断它正在工作、空闲，还是卡在一个确认对话框上。已针对 Claude Code **2.1.202** 验证过；这些是内部细节，不是承诺的接口，因此不同版本可能不提供它们——此时本工具会退回为从终端读取 URL，以及退回为按墙钟时间做 nudge（见"已知局限"）|
| Claude Code 的对话记录文件（`$CLAUDE_PROJECTS_DIR/<slugged-workdir>/<session-id>.jsonl`） | 由 `claude` 本身写入——无需安装任何东西 | 在重启后恢复一段对话之前，会先检查它是否存在；目录名是把工作目录中所有不属于 `[A-Za-z0-9]` 的字符都替换为 `-` 得到的。已针对**2.1.202** 验证过，与上一条相同的注意事项：如果没找到，只是意味着会启动一个新对话 |

### 路径与挂载点

下表中的每一个路径都只能通过 `bin/claude-guardian.sh` 顶部附近的
常量来配置（这些是部署拓扑，不是运行时配置，也不是按实例的行为）；
脚本中其他任何地方都没有把它们写死。

| 路径 | 由谁提供 | 用途 |
|---|---|---|
| `/etc/claude-guardian/config.env` | 本工具，在首次 `install` 时 | 全局运行时配置，被每个实例共享（见下文） |
| `/etc/claude-guardian/instances/<name>.env` | 本工具，在 `new`/`resume` 时 | 按实例的覆盖项：`WORKDIR`、`CLAUDE_ARGS`、`CLAUDE_BIN`，以及（如果是恢复出来的）`RESUME_SESSION_ID` |
| `/etc/systemd/system/claude-guardian@.service` | 本工具，在 `install` 时 | systemd **模板**单元——`claude-guardian@<name>.service` 是每个正在运行的实例对该模板的一次实例化 |
| `/etc/systemd/system/claude-guardian-floor.service` | 本工具，在 `install` 时 | 开机保底：一个 `oneshot` 单元，每次开机运行一次`claude-guardian ensure-floor`。刻意与模板分离——模板的各个单元只会为已经启用的实例存在，所以没有一个会运行在保底层需要去修复的那种状态下 |
| `/var/lib/claude-guardian/state/<name>.state` | 本工具，在运行时 | 按实例的运行时状态：`claude_session_id`、`workdir`、`created_at`、`remote_url`、`remote_url_updated_at` |
| `/var/lib/claude-guardian/archive/<name>-<timestamp>/` | 本工具，在 `archive` 时 | 每个被归档的实例对应一个目录：`scrollback.txt`、`meta.env`、`instance.env` |
| `/usr/local/bin/claude-guardian` | 本工具，在 `install` 时（从`bin/claude-guardian.sh` 复制而来） | 已安装的 CLI 入口点 |
| `$TMUX_SOCKET`（默认 `/run/claude-guardian/tmux.sock`） | systemd（`RuntimeDirectory=`）在单元启动时提供，或任意一条 root 侧命令 | 每个实例共享的一个专用 tmux 服务器 socket，与任何交互式管理员自己在 `/tmp` 上的 tmux 服务器相隔离。该目录属于 `$RUN_AS_USER`；当没有服务器在应答某个 socket 文件时，前一位所有者遗留下来的该文件会被删除，如果仍有服务器在应答，则拒绝删除 |
| `$WORKDIR`（默认：`$RUN_AS_USER` 的家目录，可按实例覆盖） | 操作者，通过配置或 `new --workdir` 提供 | `claude` 启动时所在的工作目录 |
| `$CLAUDE_SESSIONS_DIR`（默认 `$RUN_AS_USER` 的 `~/.claude/sessions`，从 `passwd` 中读取） | Claude Code，而非本工具 | 只读：每个正在运行的 `claude` 会话对应一个 JSON 文件，以其 PID命名；是 Remote Control 连接/断开检查以及 nudge 所依据的busy/idle/waiting 检查的数据来源 |
| `$CLAUDE_PROJECTS_DIR`（默认 `$RUN_AS_USER` 的 `~/.claude/projects`，从 `passwd` 中读取） | Claude Code，而非本工具 | 只读：对话记录文件，每个工作目录对应一个目录；在重启后恢复一段对话之前会检查其是否存在 |

### 配置参考

全局变量存放在 `/etc/claude-guardian/config.env` 中，这是一个纯
`KEY="value"` 形式的 shell 文件，最先被 source。按实例的覆盖项
（`WORKDIR`、`CLAUDE_ARGS`、`CLAUDE_BIN`）存放在
`/etc/claude-guardian/instances/<name>.env` 中，只针对该实例在其上
再 source 一次——参见 `new --workdir`/`--args`/`--claude-bin`。仓库中
的 `.env.example` 记录了这些全局默认值以供参考（本项目没有单独的
应用层 `.env`——已安装的配置文件本身*就是*运行时配置）。

| 变量 | 含义 | 默认值 | 作用范围 | 是否必须 |
|---|---|---|---|---|
| `TMUX_SOCKET` | 共享 tmux 服务器 socket 路径 | `/run/claude-guardian/tmux.sock` | 全局 | 否 |
| `RUN_AS_USER` | tmux 服务器、`claude` 以及监督循环所运行的账户。由于设计使然是全局的（一台主机一个 tmux 服务器，一个 tmux 服务器一个所有者）。修改它需要重新运行 `install`，因为 systemd 单元中写有 `User=`；`run` 在不匹配时会拒绝启动。对话不会跟着它走——它们仍然保存在旧账户的 `~/.claude` 中 | 安装时的 `$SUDO_USER`，否则为 `root` | 全局 | 否 |
| `WORKDIR` | `claude` 启动时所在的工作目录 | `$RUN_AS_USER` 的家目录，取自 `passwd` | 全局，可按实例覆盖 | 否 |
| `CLAUDE_BIN` | `claude` 可执行文件名或绝对路径；一个裸名字会以`$RUN_AS_USER` 的身份、通过该账户的交互式登录 shell 及其`~/.local/bin` 来解析 | `claude` | 全局，可按实例覆盖 | 否 |
| `CLAUDE_ARGS` | 每次（重新）启动时附加传入的 CLI 参数。`--dangerously-skip-permissions` 与 `RUN_AS_USER=root` 同时使用会被拒绝——`claude` 在以 root 身份运行时会拒绝该参数，所以这种组合会立即形成一个反复重生的循环 | `--dangerously-skip-permissions --remote-control`；root 安装时会改写为 `--permission-mode auto --remote-control` | 全局，可按实例覆盖 | 否 |
| `CHECK_INTERVAL_SEC` | 存活检查之间的间隔秒数 | `5` | 全局 | 否 |
| `REQUIRED_APT_PKGS` | 以空格分隔的、缺失时自动安装的 apt 软件包 | `tmux uuid-runtime` | 全局 | 否 |
| `UNATTENDED_NUDGE_SEC` | 仅在无人值守时生效：在没有 tmux 客户端接入的情况下，一个确认对话框可以悬而未决多久，之后才会由系统代为回答一次空回车；`0`（默认）表示绝不发送。一个正在工作或停在空提示符处的会话，无论如何都不会被输入任何内容 | `0` | 全局 | 否 |
| `REMOTE_CONTROL_CHECK_SEC` | 仅在无人值守时生效：连接检查之间的间隔秒数。该检查是被动的——只读取会话文件，不输入任何内容——所以默认是每个监督检测周期检查一次；`0` 表示禁用 | `5` | 全局 | 否 |
| `REMOTE_CONTROL_RECONNECT_BACKOFF_SEC` | 针对同一个实例的两次重新连接尝试之间的最短间隔秒数。重新连接是唯一会输入内容的部分（`/remote-control`），所以这个值限制了一个无法重新连接的实例被输入内容的频率 | `60` | 全局 | 否 |
| `CLAUDE_SESSIONS_DIR` | Claude Code 写入其按会话 JSON 文件的位置；只读，也是连接/断开以及 busy/idle/waiting 检查得以实现的基础 | `$RUN_AS_USER` 的`~/.claude/sessions`（`$CLAUDE_CONFIG_DIR` 优先） | 全局 | 否 |
| `CLAUDE_PROJECTS_DIR` | Claude Code 保存对话记录文件的位置；只读，在重启后恢复一段对话之前会检查 | `$RUN_AS_USER` 的`~/.claude/projects`（`$CLAUDE_CONFIG_DIR` 优先） | 全局 | 否 |
| `RESUME_AFTER_RESTART` | `1`：在一次连带 tmux 会话一起重启之后，让该实例回到它原本所在的那个对话；`0`：始终启动一个新对话 | `1` | 全局，可按实例覆盖 | 否 |
| `MAX_SESSIONS` | `new`/`resume` 在已存在这么多实例时拒绝执行；`0` = 无限制 | `0` | 全局 | 否 |
| `ENSURE_DEFAULT_INSTANCE` | `1`：在开机时，如果根本没有任何实例会启动起来，就从上面的全局值创建并启动默认的 `claude-code` 实例；一台已经有已启用实例的主机绝不会被触碰。`0`：这样的主机会以什么都没有的状态开机，恢复它需要手动执行 `new`。注意这与 `deactivate`之间的互动关系：在 `1` 时，停用*最后一个*实例的效果会在下一次开机时被撤销——这是刻意的（这项保证胜过簿记的一致性），`deactivate`在执行前会说明这一点 | `1` | 全局 | 否 |

## 从零开始搭建

1. 以将要作为会话账号运行的用户身份登录，把仓库（某个 tag，而不是分支最新提交）克隆到目标 Debian 服务器上——验证：`git clone ...` 退出码为 0，且 `bin/claude-guardian.sh` 存在。
2. `bash bin/claude-guardian.sh check`——验证：打印出四个检查小节（`apt dependencies`、`session account`、`claude CLI`、`login state`），带 `[ok]`/`[missing]`/`[warn]`/`[skip]` 标记，且不做任何修改。`session account` 小节会说明会话将以哪个账号运行，以及 `CLAUDE_ARGS` 与该账号的搭配是否合法。
3. `sudo bash bin/claude-guardian.sh install`——验证：日志中打印 `the session will run as '<you>'`（即 `sudo` 背后的那个账号），以 `install complete` 结尾，`grep RUN_AS_USER /etc/claude-guardian/config.env` 显示的正是该账号；`systemctl cat claude-guardian@claude-code` 显示 `User=<you>` 和 `RuntimeDirectoryPreserve=yes`；`systemctl is-enabled claude-guardian@claude-code` 打印 `enabled`（默认实例会自动创建并启用），`systemctl is-enabled claude-guardian-floor` 也打印 `enabled`（开机保底）。然后 `ls -ld /var/lib/claude-guardian/state`——验证其归属于该账号，而不是 root。
4. `claude-guardian start`——验证：`systemctl is-active claude-guardian@claude-code` 打印 `active`。
5. `claude-guardian attach`——验证：会把你带入 tmux 内的一个实时 `claude` 终端（名称默认为 `claude-code`），面板上会显示一行 `/remote-control is active ... https://claude.ai/code/session_...` ——该 URL 可以脱离本次 SSH 会话，从网页或手机上远程控制，`claude-guardian url claude-code` 无需 attach 也能打印出同一个 URL。用 tmux 前缀键（默认 `Ctrl+b`）加 `d` 来 detach——**不要**用 Ctrl+C。
6. `claude-guardian new second-instance`——验证：`claude-guardian list` 显示两行（`claude-code`、`second-instance`），各自有独立的 `SYSTEMD`/`TMUX`/`URL` 列，确认二者是各自独立被监管、可远程控制的。
7. 打开第二个终端，真正从会话内部退出 `claude`，验证其被自动重启——例如 `tmux -S /run/claude-guardian/tmux.sock send-keys -t =claude-code: C-c C-c`（`=`…`:` 这种写法是精确匹配会话名；不加的话 tmux 会做前缀匹配，可能会命中名字只是恰好以相同前缀开头的*另一个*实例）（Claude Code 把单次 Ctrl+C 当作"打断当前这一轮"，这与大多数 REPL 一致；要连续按两次才会真正退出，等效于输入 `/exit`）。验证：在 `CHECK_INTERVAL_SEC` 时间内，`claude-guardian logs claude-code` 会显示一行 `respawning automatically`，该实例的 `claude` 进程 PID（`pgrep -f 'claude --permission-mode'`）已发生变化，`claude-guardian attach` 再次显示出一个鲜活的会话（附带一个重新捕获的远程控制 URL）。
8. `claude-guardian deactivate second-instance`，然后检查 `pgrep -u "$(id -un)" -af 'claude --'`——验证：两个 `claude` 进程仍在运行，归属于会话账号而非 root（`deactivate` 只是暂停监管，参见「已知限制」中关于 `KillMode` 的说明）。再次执行 `claude-guardian activate second-instance`——验证：该实例的 `claude` PID 依然是同一个（监管是针对既有会话实例恢复的，而不是重新创建）。
9. `claude-guardian archive second-instance --yes`——验证：`claude-guardian list` 中不再出现 `second-instance`；`claude-guardian archives` 显示它的一条记录，带有一份已保存的 `scrollback.txt`；`pgrep -af 'claude --'` 只剩下 `claude-code` 进程。
10. `claude-guardian resume second-instance`（或步骤 9 中那个准确的归档 id）——验证：`claude-guardian list` 中再次出现 `second-instance`，`claude-guardian attach second-instance` 会接续同一段对话，而不是重新开始。
11. 从会话内部断开 Remote Control（`/remote-control` → `Disconnect this session`）后 detach——验证：在 `REMOTE_CONTROL_CHECK_SEC`（默认 5 秒）之内，`claude-guardian logs claude-code` 会显示 `remote control disconnected ... reconnecting`，随后跟着一个*新*的 URL，`claude-guardian url claude-code` 打印的正是这个新 URL。之后让该实例保持已连接且已 detach 的状态数分钟——验证日志始终完全静默，也就是说每一次检查在看不见的层面上不产生任何代价，也不会敲入任何字符。要触发重连退避，可以断开后立即破坏重连（例如断网）：`reconnecting` 这一行每 `REMOTE_CONTROL_RECONNECT_BACKOFF_SEC` 才应该出现至多一次,而不是每个 tick 都出现一次。
12. 在默认 `UNATTENDED_NUDGE_SEC=0` 的情况下：触发一个确认对话框（最简单的做法是用 `--permission-mode default`：让它执行任意 shell 命令），detach 后放置数分钟——验证：`claude-guardian logs claude-code` 从未出现 `sending Enter` 这一行，回来时对话框仍在等待。没有任何东西替你回答它。然后在 `/etc/claude-guardian/config.env` 中设置 `UNATTENDED_NUDGE_SEC="60"`，执行 `claude-guardian restart claude-code`，重复上述过程——验证：在 60 秒这个时间点，日志会显示 `has been waiting on a confirmation for Ns with nobody attached`，紧接着是 `sending Enter`,对话框随之消失。再重新 attach 一次然后 detach——验证它不会立即再次触发（计时器在 attach 时会重置）。之后把它改回 `0`。
13. 开机保底机制。对每一个实例依次执行 `claude-guardian deactivate <name> --yes`，直到没有一个实例处于启用状态——验证：最后一个会警告说主机将在开机时什么都不会启动（不加 `--yes` 时,在非交互式 shell 中它会拒绝执行而不是直接动手）。然后执行 `systemctl start claude-guardian-floor`——验证：`journalctl -u claude-guardian-floor` 显示 `no instance would come up at boot`，紧接着是 `instance 'claude-code' enabled and starting`,几秒钟之内 `claude-guardian list` 就会显示 `claude-code` 为 `active`/`up`。再次执行 `systemctl restart claude-guardian-floor`——验证它这次记录的是 `1 instance(s) already enabled — nothing to do`，且不会出现第二个会话。设置 `ENSURE_DEFAULT_INSTANCE="0"` 后从空状态重复以上步骤——验证它记录的是 `disabled, doing nothing`，且不创建任何东西。
14. `reboot` 主机——验证：重启之后,每一个之前是 `activate`（而非 `deactivate`）状态的实例都会在无需人工干预的情况下再次变为 `active`，`claude-guardian logs <name>` 显示 `continuing this instance's previous conversation (<uuid>)`（对于由 `resume` 创建的实例，则显示 `resuming archived conversation <uuid>`，其配置固定了 `RESUME_SESSION_ID`，优先级高于 `RESUME_AFTER_RESTART`），`/run/claude-guardian` 以 `drwx------` 权限存在，归属于会话账号（由 `RuntimeDirectory=` 在一个全新的 tmpfs 上创建，只有真实重启才会触发这一点），attach 后显示的是重启前的对话,而不是一个空对话。想在不重启的情况下演练这一过程：`claude-guardian stop <name>`，`tmux -S /run/claude-guardian/tmux.sock kill-session -t <name>`，`claude-guardian start <name>`。

本项目不通过 Docker 部署；以上步骤就是完整的部署流程。

## 数据模型／文件布局

```
repo/
├── bin/claude-guardian.sh   # 整个工具——自包含，没有其他源文件
├── tests/run-as-user.sh     # 针对会话账号这一层的独立检查；不安装任何东西
├── README.md / README.zh.md
├── DESIGN.md / DESIGN.zh.md
├── .env.example             # 记录全局 config.env 变量的说明文档（参见「配置参考」）
└── ...
```

仓库中没有单独提交的 systemd unit 文件或配置模板：`claude-guardian install` 会从内嵌在 `bin/claude-guardian.sh` 中的 heredoc 生成这两者，所以这一个文件就是一份完整、自包含的部署产物——把它复制到任何地方并运行 `install` 即可，不需要仓库的其余部分。

## 已知限制与注意事项

- **每台主机只能有一个会话账号，对话不会跟着它走。**
  `RUN_AS_USER` 是全局的，因为所有实例共享同一个 tmux server，而一个 tmux server 只能有一个所有者。因此，把一台主机从一个账号迁到另一个账号是一次迁移，而不是改一下配置那么简单：`claude` 会把会话记录保存在*旧*账号的 `~/.claude` 下，新账号无法读取，因此对话必须手动复制过去（而且它们的会话记录目录名是根据工作目录生成的，通常也会一起变化）。工具不会替你完成这件事——它无法知道一个账号下的哪些对话属于这台主机。README → Install 中有完整的操作顺序。
- **首次运行的信任提示会由工具替你回答。** 当某个账号第一次打开一个从未打开过的目录时，`claude` 会问"这是你创建或信任的项目吗？"，并预选**No, exit**。在无人值守的情况下,这是致命的：本工具为清除引导界面而发送的那次盲打 Enter 会选中它，`claude` 就会退出，而监管进程则会一遍又一遍地把它重新拉起到同一个画面上，日志里只会写着 `claude exited`。因此监管进程会识别出这个特定画面并回答*是*。理由是 `$WORKDIR` 是操作员为无人值守会话专门配置的目录，因此已经没有人可以去问了——但这终究还是替你做了一个决定。这种情况每个账号对每个工作目录只会发生一次（`claude` 会把答案记录在自己的 `~/.claude.json` 中）。如果你不希望如此，就只把实例指向你自己已经打开过的目录。
- **没有任何东西能阻止 `--dangerously-skip-permissions` 真的按字面意思行事。** 之所以把它设为默认值，是因为本工具存在的目的就是让无人值守的会话持续运转，而卡在权限提示上的会话就是一个停摆的会话。同一权衡的有界版本是 `CLAUDE_ARGS="--permission-mode auto --remote-control"`，这也是 root 安装时得到的配置，而 `UNATTENDED_NUDGE_SEC` 是同一条轴线上的第三个取值点。请按主机选择，并记住会话拥有会话账号的全部权限——如果该账号拥有免密码的 `sudo`，那就包括 root 权限。
- **开机保底机制只在开机时运行，不是持续运行的。** `ensure-floor` 是一个 `oneshot`，所以在会话中途归档掉最后一个实例，会让主机在下次重启（或手动执行 `claude-guardian ensure-floor` / `new`）之前一直保持无实例运行的状态。这是刻意为之：如果保底机制在你归档一个实例几秒钟后就重新创建一个实例，会让 `archive` 变得没法用，同一版本中加入的警告则覆盖了交互式场景。需要记住的结论是,"保底机制会兜底"这句话只对重启场景成立。
- **在 `ENSURE_DEFAULT_INSTANCE=1` 时，停用最后一个实例的效果会在下次开机时被撤销。** `deactivate` 承诺"开机不会自动启动"，而保底机制承诺"总有东西在运行"；当涉及的实例是唯一的一个时，二者就发生了矛盾,保底机制会获胜。`deactivate` 会在动手之前把这一点原原本本地打印出来，所以这个意外是提前告知的，而不是在重启后才被发现——但一台确实打算以空闲状态开机的主机，需要的是 `ENSURE_DEFAULT_INSTANCE=0`，而不是 `deactivate`。
- **保底机制兜底出的实例是一段全新对话，而不是你归档掉的那一个。** 当不存在 `claude-code` 配置时，它会根据全局的 `WORKDIR`/`CLAUDE_ARGS` 写入配置，新会话是从空白开始的。回到此前的某段对话是 `resume <archive-id>` 的职责；保底机制只保证*存在*一个会话。
- **`UNATTENDED_NUDGE_SEC`（自动回车）自 v0.6.0 起默认关闭，打开它是一个刻意的安全权衡，而不是一个中性的便利特性。** 以下描述的是打开它之后你所选择接受的东西；在默认值 `0` 下，这些事情都不会发生，一个确认对话框只会一直等到有人来回答它。`--permission-mode auto` 在分类器连续拦截 3 个动作（或累计拦截 20 个）之后，会退回到交互式确认——这个退回机制的存在是为了让人来对分类器无法自动放行的事情做出判断。在无人值守的状态下发送一个裸的 Enter，会接受当前高亮/默认的那个选项，**而并不知道该默认选项对那个特定的提示是否是安全的选择。** 当 guardian 尝试在开启该行为的情况下重启时，Claude Code 自身的自动模式分类器当场标记了这一点（"defeats the human-in-the-loop safety fallback"，意为"破坏了人工介入的安全兜底"），并要求用户在部署前明确确认（参见 `DECISIONS.md`，2026-08-16）。如果这一权衡对某次部署来说不可接受，把 `UNATTENDED_NUDGE_SEC="0"` 设置为禁用它——文档记载的替代方案是使用 `--permission-mode dontAsk` 配合一份明确的 `permissions.allow` 列表，它会静默拒绝未列出的动作，而不是去猜一个确认对话框（更可预测，但需要更多前期配置）。v0.4.0 收窄了它*可以作用于谁*——Enter 只会发送给 `claude` 自己报告为 `waiting` 状态的会话，而且只在对话框已经无人回应满一个完整间隔之后，因此正有人在使用的会话不会被误打字。这一点没能解决的是那个残余情形：一个在 claude.ai 上打开了对话框、随后离开的时间超过 `UNATTENDED_NUDGE_SEC`、但仍打算回来回答它的人，从外部看和一个被遗弃的会话是无法区分的——而这种情况确实在 v0.4.0 上线当天就在生产环境中被观察到了。二者之间没有任何可以区分的信号，所以 v0.6.0 不再尝试区分：这个特性默认关闭，除非操作员主动打开它，打开之后，循环仍然遵循同一条"仅 `waiting`"规则。打开它的人，是在"一个被遗弃的实例能自己脱困"和"除了我谁都不会替我回答权限提示"之间，选择了前者。
- **`claude-guardian install`/`new` 会非交互式地自动安装缺失的 apt 软件包**（`DEBIAN_FRONTEND=noninteractive apt-get install -y`）。默认情况下这指的是 `tmux` 和 `uuid-runtime`。如果你扩大了 `REQUIRED_APT_PKGS`，请自行审视你在无人值守的情况下让它安装的是什么。
- **缺失 `claude` 可执行文件会让某个实例的服务反复失败重启约一分钟，然后停下。** `preflight_enforce` 在找不到 `claude` 时会硬性失败（这是有意为之——本工具从不负责安装它）。unit 中的 `StartLimitBurst=10` / `StartLimitIntervalSec=60` 会阻止 systemd 无限重启；之后该实例会一直处于 `failed` 状态，直到你安装 `claude` 并执行 `systemctl reset-failed claude-guardian@<name> && claude-guardian start <name>`。
- **`claude-guardian deactivate <name>`（`systemctl disable --now`）不会杀掉活跃会话——这需要在 unit 中设置 `KillMode=process`，并已针对真实的二进制文件验证过。** systemd 的*默认* `KillMode` 是 `control-group`，它会在 stop/restart 时对整个 cgroup 发送 SIGTERM，包括 tmux server 和 `claude` 本身（这一点是在实际使用中发现的：unit 最初的版本没有显式设置 `KillMode`，一次 `systemctl restart` 就悄无声息地杀掉并重建了会话）。有了 `KillMode=process`，只有被跟踪的循环 PID 会被发送信号，因此该实例的 `claude` 及其 tmux 会话能在 `stop`/`restart`/`deactivate` 之后存活下来。一个副作用是：systemd 会在下一次 `start` 时打印一条无害的提示 `Found left-over process ... in control group`，这是因为之前的 `claude` 进程仍在该 cgroup 中——这是预期行为,而不是错误。要真正结束某个实例的对话，用 `claude-guardian archive <name>`（具有破坏性,默认会要求确认）；要彻底拆掉一切，用 `claude-guardian purge`（同样默认要求确认，且不会碰归档目录——见下文）。
- **`purge` 的影响范围在加入多实例支持时从"单个会话"扩大到了"所有活跃实例"**（参见 `DECISIONS.md`，2026-08-17）。它现在会打印当前活跃实例的数量，并在杀掉任何东西之前要求交互式确认（或传入 `--yes`），而且刻意从不删除 `/var/lib/claude-guardian/archive/`——如果想把归档也一并清掉，需要用 `rm-archive` 显式移除各个归档。
- **有三项行为目前依赖于 Claude Code 的内部文件。** `$CLAUDE_SESSIONS_DIR/<pid>.json`（字段 `bridgeSessionId`、`status`、`statusUpdatedAt`）以及 `$CLAUDE_PROJECTS_DIR/<slugged-workdir>/<id>.jsonl` 并不是一份有文档、有承诺的接口；未来的 Claude Code 版本可能会重命名、移动，或者干脆不再写这些文件。以上均已针对 2.1.202 验证过。当对应文件缺失或不可读时，每一项行为都会降级而不是直接崩溃：连接检测会退回到发送 `/remote-control` 并从屏幕上读取 URL（也就是 v0.2.0 一直以来的做法），提醒功能会退回到用系统时钟计时（同样是 v0.2.0 的行为），而无法被确认的 resume 则会直接开始一段新对话。这两条路径都可以在配置中覆盖（`CLAUDE_SESSIONS_DIR`、`CLAUDE_PROJECTS_DIR`），因此文件被挪动位置时，无需修改脚本就能重新指向它。会话记录目录的名字是通过把工作目录中每一个不在 `[A-Za-z0-9]` 范围内的字符替换成 `-` 得到的；如果这一约定发生变化，重启后的 resume 会悄无声息地找不到对应的会话记录，每次重启都会开始一段全新对话——由于不会报任何错误，这是需要留意的症状。
- **重连 Remote Control 会向 tmux 面板发送字面意义上的按键（`C-u`、`/remote-control`、`Escape`）**，实例创建时的首次捕获（紧跟在引导阶段的双击 Enter 之后）也是如此。与 v0.2.0 不同的是，这不再按固定周期发生——只有在上述检查确认 Remote Control 确实已断开时才会发生——但如果 `claude` 恰好在那一刻意外停在了其正常提示符之外的其他画面上（例如那两次已发送的 Enter 之外的某个引导步骤），这些按键就可能被输入到错误的地方。这是无害的（这一步不会自动确认任何东西，Escape 是取消而不是选中），但可能会留下需要通过 `claude-guardian attach <name>` 手动清理的杂散文本。这与双击 Enter 清除引导界面以及无人值守提醒所接受的"盲打按键"是同一类权衡；参见上文 `UNATTENDED_NUDGE_SEC` 条目。
- **重连会改变该实例的 `claude.ai/code/...` URL。** 对话本身不受影响——依然是同一个 `claude` 进程和同一个 `claude_session_id`——但之前收藏的链接会失效。没有办法既真正重连又保留旧的 URL，所以本工具优先保证连接是活的，并预期 URL 会按需获取（`claude-guardian url <name>`），而不是被保存下来。
- **`resume` 只有在归档中记录了 `claude_session_id` 时才能重建一段对话。** 对于由本工具自己的 `archive` 命令创建的归档，这一点总是成立（该 id 在实例创建时就被捕获，并一路带过来），但如果某个归档目录被人手动改动过，或者 `meta.env` 丢失了，`resume` 会拒绝执行，转而指向原始的 `scrollback.txt`，而不是去猜。
- **`install` 会原地迁移一个 v0.1.0 的单实例部署**（`migrate_legacy_unit`）：它会禁用/移除旧的 `claude-guardian.service`，并针对*同一个* tmux 会话启用新的 `claude-guardian@claude-code.service`。这依赖于新旧两个 unit 中的 `KillMode=process` 均成立（上文已验证）——如果未来某次 systemd unit 的改动去掉了这个设置，这条迁移路径在被再次信任之前需要重新验证，且要针对一个真实运行中的会话进行。已针对一台真实生产主机验证过：`install` 前后 tmux 面板的 PID 和存活状态没有变化。
- **一个被迁移过来的既有会话，在真正被重新创建之前,永远不会拥有被跟踪的 `claude_session_id`、`workdir` 或已捕获的 URL**——这一点是在上述同一次真实迁移中发现的。`respawn-pane` 只会重放 tmux 在会话首次创建时存储的*原始*命令；对于一个早于 v0.2.0 就存在的会话，那条原始命令里没有 `--session-id`，所以任何一次崩溃重启都不可能追溯性地为它补上。实际表现是：`list` 会把该实例的工作目录显示为 `-`，它的 URL 依然能找到（那来自 `claude` 自己的会话文件，任何正在运行的会话都有，缺失被跟踪的 id 只会跳过 PID 复用交叉检查的一半），而 `archive` 该实例会保存一个空的 `claude_session_id`——`resume` 到时候会正确地拒绝执行，并转而指向原始的 scrollback，而不是去猜。想让一个被迁移过来的实例获得一个真实、可 resume 的 session id，唯一的办法是让它的 tmux 会话真正结束再被重新创建（例如先 `archive` 它一次，然后再 `resume`/`new` 回来）——不存在原地回填的方法，手动改写它的状态文件也只会伪造出一个 `claude` 从未真正使用过的 id。
- **用 tmux 前缀键 detach，而不是 Ctrl+C——而且单次 Ctrl+C 本来就杀不死 `claude`。** 已针对真实 CLI 验证过：Claude Code 把单次 Ctrl+C 当作"打断当前这一轮"（与大多数 REPL 一致），而不是退出——面板保持存活，也不会有任何重启发生。要连续快速按两次 Ctrl+C（或者用 `/exit`）才能真正终止进程，此时面板才会死掉，guardian 才会重启它,这符合最初的要求——一次刻意的杀进程操作绝不能让实例数归零。无论要按多少次 Ctrl+C 才能退出，这都不是一种干净的离开会话的方式——永远使用 tmux 前缀键 + `d`。
- **如果你这份仓库的工作副本存放在一个带固定 `file_mode` 选项的 CIFS/SMB 挂载文件系统上（NAS 背后的开发环境中很常见），对 `bin/claude-guardian.sh` 执行 `chmod +x` 可能是一次静默的空操作**（退出码为 0，权限位却没有变化——这一点在开发过程中被实际遇到过）。可执行位是在提交时通过 `git update-index --chmod=+x bin/claude-guardian.sh` 直接记录在 git 树里的，所以在一个支持真实权限位的文件系统上正常 `git clone`，检出来的文件本来就是可执行的。如果你本地的工作副本无法保留可执行位，就显式用 `bash bin/claude-guardian.sh ...` 来调用脚本，而不是 `./bin/claude-guardian.sh`。
- **登录状态只在 `install` 时被强制检查，而不是持续检查。** 如果 `claude auth status` 失败，`install` 会硬性拒绝（针对两种真实状态都验证过：已登录，以及一个没有任何凭据的隔离 `HOME`——分别退出码为 0 和 1）。一旦安装完成，`run` 在鉴权缺失或之后丢失时只会发出警告——服务会持续重试，下次有人 attach 时,`claude` 会显示它正常的交互式登录流程，而不是拒绝启动。这是刻意为之，不是疏漏：一个原本正常工作、之后丢失了鉴权的服务（token 过期、会话被吊销），应该持续尝试提供服务,而不是陷入重启失败循环。
- **`REMOTE_CONTROL_CHECK_SEC` 限定的只是一个断开的连接最长能有多久不被发现，仅此而已。** v0.2.0 把它设为 1200 秒，是为了保持在 Anthropic 文档记载的约 30 分钟"could not reach the Remote Control server"（无法连接到 Remote Control 服务器）窗口之内，前提假设是提前重新执行一次 `/remote-control` 就能让连接永不过期。这个假设是错的（参见 `DECISIONS.md`，2026-08-17），这就让一个原本 20 分钟的数字承担了一份它从未被选来承担的职责：它变成了"一个实例最长能不可达多久"，而在生产环境中它确实就是这么表现的。自 v0.6.0 起，这项检查在每个 tick（5 秒）都会执行——它只是一次不产生任何按键的文件读取，所以本就没有理由让它慢——旧的那个变量已经被移除。仍然设置着 `REMOTE_CONTROL_REFRESH_SEC` 的配置会在循环启动时收到一条警告；该设置本身会被忽略。
- **一次持续失败的重连会按退避策略重试，而不是每次检查都重试。** `REMOTE_CONTROL_RECONNECT_BACKOFF_SEC`（60 秒）之所以存在，是因为重连是唯一一个会向会话里敲字符的步骤：如果没有它，一个 Remote Control 始终无法恢复的实例，就会每 5 秒被敲入一次 `/remote-control`。当 `claude` 完全没有写出可用的会话文件时，就没有任何东西能确认重连是否成功了，这种情况会退回到一个慢得多的内部重试间隔（1200 秒），而不是 60 秒的退避。
- **无人值守提醒/连接检测的计时器只从监管循环自身（重新）启动的那一刻开始计数，而不是从会话实际最后一次被关照的时刻开始计数。** 这是一个在实际使用中被发现的真实 bug：最初的版本把两个计时器都初始化为 `0`（纪元时间），所以任何一次针对已经无人照看的会话执行的 `systemctl restart`，都会立刻触发一次提醒和刷新,而不是等满配置的间隔。修复方式是在循环启动时,用当前时间为两个计时器设定初始值。

## 如何扩展

- **新增 preflight 检查**要同时加入 `preflight_report`（只报告，不动手）和 `preflight_enforce`（可能修改状态／硬性失败)——保持二者同步，这样 `check` 才能准确预览 `run`/`install`/`new` 将会做什么。
- **新增全局配置变量**的做法是同时扩展 `bin/claude-guardian.sh` 顶部附近的默认值代码块和 `write_default_config` 中的 heredoc，再在本文档「配置参考」表格和 `.env.example` 中各加一行。**新增按实例覆盖的配置**则应通过 `write_instance_file` 和一个新的 `new --flag` 选项来实现——保持集合精简；之所以选中 `WORKDIR`/`CLAUDE_ARGS`/`CLAUDE_BIN` 三个，是因为它们是目前唯一出现过真实按实例需求的旋钮（参见 `DECISIONS.md`，2026-08-17）。
- **按实例的 TMUX_SOCKET，或者一个 HTTP 控制 API**，二者在加入多实例支持时都曾被考虑过并被否决——在重新引入其中任何一个之前，请先参见 `DECISIONS.md`，2026-08-17，「Rejected」小节。
- **新增实例生命周期子命令**应遵循既有模式：只通过 `instance_file`/`state_get`/`state_set` 读写状态，绝不触碰其他实例的文件，并在同一次改动中一起更新 `usage()`（那段注释块）和 `main()` 里的 case 语句——`usage()` 是通过 `sed` 从那段注释块生成的，所以只要两者在同一次改动中一起编辑，就不可能出现漂移。
