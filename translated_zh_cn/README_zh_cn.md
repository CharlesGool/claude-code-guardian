# claude-code-guardian

[English](../README.md) | **简体中文**

> 译自 `README.md`（v0.10.1）。如有冲突，以英文版为准。

在 Debian 服务器上让一个或多个具名、可远程接入的 Claude Code（`claude`）会话持续存活，无论主机重启还是 `claude` 进程本身被杀死（Ctrl+C、崩溃、`exit`）都能挺过去。由 root 负责安装和监督，会话本身则以普通账号运行。

## 功能说明

- 安装一个 systemd **实例模板**，为每个具名实例监督一个专属的 `tmux` 会话，默认每个会话运行 `claude --dangerously-skip-permissions --remote-control`——远程控制意味着你可以从 **网页版 claude.ai 或手机** 接管任意实例，而不局限于 SSH+tmux。
- **会话归属于普通账号，而非 root。** `RUN_AS_USER` 指定拥有 tmux 服务端、每个 `claude` 进程以及 `claude` 写入的一切内容的账号；root 只负责安装、监督并执行管理命令。`install` 会自动采用你 `sudo` 时所用的账号。这并非为了安全而刻意设计的加固：`claude` 在以 root 身份运行时会直接拒绝 `--dangerously-skip-permissions`，因此一个绝不能停下来等待授权确认的无人值守会话，*必须* 以别的身份运行。直接以 root 身份安装的主机依然可以工作——它会改用 `--permission-mode auto --remote-control`，而"root 加跳过授权确认参数"这种组合会在入口处就被拒绝，而不是留着让它无限重生。
- 记录每个实例当前的 `claude.ai/code/...` 远程控制 URL——`claude-guardian url <name>` 或 `claude-guardian list` 不需要接入会话就能打印出来。重点在于：完全可以从另一台设备创建、发现并连接一个会话，不需要终端。需要时再取一次即可，不要收藏它：URL 会在远程控制每次重新连接时变化。
- 如果 `claude` 因任何原因退出，会在几秒内自动重新拉起，并延续同一段对话——tmux 会话（及其回滚记录）依然存在。
- 如果整个监督进程或主机重启，每个曾被 `activate` 过的实例都会自动恢复——**恢复到重启前正在进行的那段对话**，而不是一个空会话。重启会连带杀掉 tmux 服务端，因此会话是从头重建的；当该实例的对话记录仍在磁盘上时，会用 `claude --resume` 接续这段对话（设置 `RESUME_AFTER_RESTART=0` 可退出该行为）。如果对话已无法接续，则退回到开启一个新对话，而不是让该实例卡住。
- **让每个实例持续保持可连接。** 远程控制会自行断开——服务端超时、网络抖动——而不会有任何提示：会话本身照常工作，只是从 claude.ai 那端连不上了。每个监督周期（`REMOTE_CONTROL_CHECK_SEC`，默认 5 秒）监督进程都会读取 Claude Code 自身的会话文件，判断连接是否仍然有效，一旦失效就立刻重新连接并取得新的 URL。这个检查本身不会向会话输入任何内容；只有真正发生重连时才会输入，而重连本身受 `REMOTE_CONTROL_RECONNECT_BACKOFF_SEC`（默认 60 秒）限流，确保一个连不上的实例不会被反复输入。
- **默认绝不替你回答确认对话框。** 卡在授权确认提示上的会话可以靠发送回车键解除卡顿——但回车会接受对话框当前高亮的选项，等于替你做了决定，而从外部根本无法区分"这个会话已被放弃"和"你只是还没来得及回答"。因此自 v0.6.0 起 `UNATTENDED_NUDGE_SEC` 默认为 `0`（关闭）。如果你希望无人值守的实例能自行解除卡顿，可以把它设为一个秒数；即便如此，它也只会向 Claude Code 自身报告为"卡在对话框上"的会话输入内容，绝不会对正在工作或空闲的会话下手。参见 `DESIGN.md` → 已知限制。
- 让你可以独立地对一个实例进行**暂停**（`deactivate`/`activate`：停止/恢复监督，tmux 会话本身照常运行）和**归档**（`archive`/`resume`：保存回滚记录和对话 id，然后杀死进程；之后可用 `claude --resume` 重新接续这段对话）。
- **绝不会在无任何实例运行的状态下启动。** 归档或停用实例可能导致启用中的实例数为零，在 v0.9.0 之前，处于这种状态的主机重启后会悄无声息地连一段对话都没有。现在有两道机制阻止这种情况：`archive` 和 `deactivate` 在被移除的实例是开机时唯一会启动的实例时会发出警告（并在没有 `--yes` 时先询问）；此外还有一个开机单元（`claude-guardian-floor.service`），在没有任何实例会启动时创建并启动默认的 `claude-code` 实例。如果你希望没有已启用实例的主机以空白状态启动，可将 `ENSURE_DEFAULT_INSTANCE` 设为 `0`。
- 运行预检：自动安装缺失的 `apt` 软件包（默认为 `tmux`、`uuid-runtime`），并校验 `claude` 是否在 `PATH` 中。`install`/`new` 在 `claude` 尚未登录时会拒绝继续执行（通过 `claude auth status` 检测）；一旦实例已在运行，`run` 只会对登录状态发出警告，好让之后失去登录态的实例持续重试而不是直接启动失败。
- 提供 `attach` 命令，作为 claude.ai 远程控制 URL 之外的另一种方式，供远程操作者通过 SSH 接管一个在运行中的会话。
- 可选的成本/资源增长防护栏：设置 `MAX_SESSIONS` 后，`new` 一旦达到该数量的已存在实例就会拒绝创建——每个实例都是独立的 `claude` 进程，各自产生独立的 token 开销。默认不限（`0`）。

非目标：本工具不安装或更新 Claude Code CLI 本身，也不暴露网络控制 API——生命周期管理仅限命令行（详见 `DESIGN.md`）。

## 环境要求

- 操作系统：Debian 或带 systemd 的 Debian 衍生系统（Ubuntu 等）
- 每条写入 `/etc`、`/var/lib` 或 systemd 的命令都需要 root——`sudo` 即可，通常的方式是从你自己的账号执行 `sudo claude-guardian <command>`
- 一个供会话运行的账号（`RUN_AS_USER`）。`install` 使用你 `sudo` 时所在的账号；没有的话回退到 root。`runuser`（util-linux，通常已预装）用于让 root 以该账号身份行事
- **在该账号下**安装并可在其 `PATH` 中找到（或通过 `CLAUDE_BIN` 指定）的 `claude`——本工具不负责安装它。常见的 `~/.local/bin/claude` 即使不在 systemd 的 `PATH` 中也能被找到
- **以该账号身份**已完成 `claude` 登录（该账号下 `claude auth status` 必须成功）——否则 `install` 会拒绝继续，请先以该用户身份运行 `claude auth login`。登录状态归属于某一个账号：root 已登录并不代表会话账号也已登录
- 若尚未安装 `tmux`，需要联网以供 `apt-get` 使用

## 安装

```bash
# 克隆某个 tag，而不是分支尖端——分支尖端可能处于改动中途。
# 列出可用 tag：git ls-remote --tags <repo-url>
git clone --depth 1 --branch v0.10.0 https://github.com/CharlesGool/claude-code-guardian.git
cd claude-code-guardian
sudo bash bin/claude-guardian.sh install
```

请从会话应归属的那个账号用 `sudo` 运行本命令：`install` 会把该账号（`$SUDO_USER`）记为 `RUN_AS_USER`，并以该用户身份解析 `claude` 及其登录状态。随后它会执行预检、把默认全局配置写入 `/etc/claude-guardian/config.env`、把脚本安装到 `/usr/local/bin/claude-guardian`、写入 systemd **实例模板**（`claude-guardian@.service`，携带 `User=$RUN_AS_USER`）以及**开机保底单元**（`claude-guardian-floor.service`）、把状态目录和 socket 目录移交给该账号，并创建加启用一个名为 `claude-code` 的默认实例。它不会启动这个实例——那是下一步。从 v0.1.0 版本升级时，会自动把它的单一会话迁移到新模板上，不会杀掉正在运行的 `claude` 进程。

从任何更早版本升级：重新执行 `sudo bash bin/claude-guardian.sh install` 即可。该操作是幂等的，且不会改动已存在的 `config.env`，因此该文件写入之后新增的设置项——`ENSURE_DEFAULT_INSTANCE`，以及现在的 `RUN_AS_USER`——不会出现在其中，它们的内置默认值会在你自己添加之前一直生效。`RUN_AS_USER` 的默认值是 `root`，所以**升级后的主机会继续原封不动地以原来的方式运行会话**；把会话迁到普通账号是一个刻意的、单向的步骤：

```bash
# 1. 归档每一个实例（保存回滚记录 + 对话 id，杀死会话）
sudo claude-guardian archive <name> --yes
# 2. 把对话记录搬到新账号——它们存在*旧*账号的 ~/.claude 下，
#    新账号读不到。目录名取自工作目录，
#    每个非字母数字字符都被替换成了 '-'
sudo cp /root/.claude/projects/-root/<conversation-id>.jsonl \
        /home/you/.claude/projects/-home-you/
sudo chown you:you /home/you/.claude/projects/-home-you/<conversation-id>.jsonl
# 3. 把 RUN_AS_USER 指向新账号并重新 install，然后重新创建
#    各实例（`resume <archive-id>` 会接续对话；如果该归档的
#    工作目录是旧账号的家目录，先编辑该归档的 meta.env）
sudoedit /etc/claude-guardian/config.env
sudo claude-guardian install
```

一个由旧账号拥有的存活 tmux 服务端会挡住新账号的服务端；`install` 会提示这一点并停止，而不是让旧账号的会话失去归属。仅仅是被遗留下来、其服务端已经不在的 socket 文件会被自动清理。存活的实例不会被 `install` 重启。

### 可选：`claude-session` skill

`skills/claude-session/` 是一个 Agent Skill，教会 Claude Code 用自然语言（"开一个常驻对话"、"list my sessions"、"archive this one"）驱动上述命令，而不需要你记住这些命令行。它还内置了破坏性命令的规则——`archive` 和 `purge` 会杀死正在运行的 `claude` 进程，因此该 skill 要求先出现明确点名该动作的请求才会执行其中任何一个。

```bash
cp -r skills/claude-session ~/.claude/skills/
```

这是可选项，且不会改变工具本身的任何行为：没有它 `claude-guardian` 照样正常工作。

## 快速上手

```bash
claude-guardian start
claude-guardian attach
```

以上是默认的 `claude-code` 实例。要运行第二个独立的、并行受监督的对话：

```bash
claude-guardian new work --workdir /home/you/some-project
claude-guardian list          # 每个实例：systemd/tmux 状态、是否已接入、工作目录、远程控制 URL
claude-guardian url work      # 只打印 claude.ai 的 URL——不需要接入
```

## 验证是否正常工作

- `systemctl is-active claude-guardian@claude-code` 打印 `active`。
- `claude-guardian attach` 会把你带入一个存活的 `claude` 终端。用 tmux 前缀（默认 `Ctrl+b`）再按 `d` 分离——**不要**用 Ctrl+C（见下方的坑）。
- 真正从会话内部退出 `claude`（快速连按两次 Ctrl+C，或输入 `/exit`——单次 Ctrl+C 只会中断当前这一轮，不会退出）——几秒钟内 `claude-guardian logs` 会显示一行 `respawning automatically`，再次接入时会看到 `claude` 又在运行，且是同一段对话。
- `claude-guardian deactivate`——`claude` 会继续运行（只是暂停监督并禁用开机自启，见下方的坑）；`claude-guardian activate` 会在不重启它的情况下恢复监督。如果它是你唯一的实例，现在会先警告"主机将以空白状态启动"并先询问；传入 `--yes` 可跳过这个询问。
- 开机保底机制：把每个实例都停用或归档后，`systemctl start claude-guardian-floor` 会记录 `no instance would come up at boot` 并把 `claude-code` 重新拉起来——几秒内 `claude-guardian list` 会显示它处于 `active`/`up`。再运行一次会记录 `already enabled — nothing to do`，不会创建第二个会话。这与开机时运行的是同一个单元。
- `claude-guardian archive claude-code --yes` 之后 `claude-guardian resume claude-code`——该实例会从 `list` 中消失、出现在 `archives` 中，并以同一段对话（`claude --resume`）延续回来。
- 从会话内部断开远程控制（`/remote-control` → `Disconnect this session`）并分离——在 `REMOTE_CONTROL_CHECK_SEC`（默认 5 秒）内 `claude-guardian logs <name>` 会依次显示 `remote control disconnected ... reconnecting` 和一个 URL，`claude-guardian url <name>` 会打印这个新 URL。连接健康时日志保持沉默，这正是设计的重点：不会对一个不需要输入的会话输入任何内容。
- `reboot` 主机——启动后，每个曾被 `activate` 过的实例都会无需人工干预地重新变为 `active`，`claude-guardian logs <name>` 会显示一行 `continuing this instance's previous conversation`——如果该实例是用 `resume` 恢复回来的，则显示 `resuming archived conversation`；两者含义相同，都表示同一段对话被接续了。接入后：重启前的那段对话依然还在。（不重启的等效做法：`claude-guardian stop <name>`，用 `tmux -S /run/claude-guardian/tmux.sock kill-session -t <name>` 杀掉其 tmux 会话，再 `claude-guardian start <name>`——效果相同。）

- 在一份克隆下运行 `bash tests/run-as-user.sh`——针对会话账号这一层的隔离检查（单元以谁的身份运行、生成的配置和单元里写了什么、哪些组合会被拒绝）。它不安装任何东西，不需要 root，也绝不会触碰存活中的会话。

## 配置

全局默认值存放在 `/etc/claude-guardian/config.env`。每实例覆盖项（`WORKDIR`、`CLAUDE_ARGS`、`CLAUDE_BIN`）在创建时通过 `new --workdir`/`--args`/`--claude-bin` 设置，存放在 `/etc/claude-guardian/instances/<name>.env`。

| 变量 | 含义 | 默认值 | 作用域 |
|---|---|---|---|
| `TMUX_SOCKET` | 共享的 tmux 服务端 socket 路径 | `/run/claude-guardian/tmux.sock` | 全局 |
| `RUN_AS_USER` | tmux 服务端、`claude` 以及监督循环所运行的账号。每台主机一个：所有实例共用一个 tmux 服务端，而一个 tmux 服务端只属于一个账号。改动它需要重新 `install`（该单元携带 `User=`），并需要为新账号完成 `claude` 登录——对话记录留在旧账号的 `~/.claude` 下，不会跟着迁移 | `install` 时 `sudo` 所用的账号，否则为 `root` | 全局 |
| `WORKDIR` | `claude` 启动时所在的工作目录 | `$RUN_AS_USER` 的家目录 | 全局 / 每实例 |
| `CLAUDE_BIN` | `claude` 可执行文件名或绝对路径，在 install 时以 `$RUN_AS_USER` 身份解析 | `claude` | 全局 / 每实例 |
| `CLAUDE_ARGS` | 每次（重新）启动时附加的额外命令行参数 | `--dangerously-skip-permissions --remote-control`；当会话以 root 身份运行时为 `--permission-mode auto --remote-control` | 全局 / 每实例 |
| `CHECK_INTERVAL_SEC` | 存活检查之间的间隔秒数 | `5` | 全局 |
| `REQUIRED_APT_PKGS` | 缺失时自动安装的 apt 软件包，以空格分隔 | `tmux uuid-runtime` | 全局 |
| `UNATTENDED_NUDGE_SEC` | 仅用于无人值守场景：一旦某个确认对话框在这么长时间内无人回答，就发送回车，替你做出回答。`0` = 从不（默认）。绝不会向正在工作或处于提示符状态的会话发送任何内容 | `0` | 全局 |
| `REMOTE_CONTROL_CHECK_SEC` | 仅用于无人值守场景：连接检查之间的间隔秒数；该检查是被动的，不输入任何内容，因此可以设得和轮询间隔一样低（`0` 表示关闭） | `5` | 全局 |
| `REMOTE_CONTROL_RECONNECT_BACKOFF_SEC` | 两次重连尝试之间的最小间隔秒数——重连才是向会话输入 `/remote-control` 的那一步 | `60` | 全局 |
| `CLAUDE_SESSIONS_DIR` | Claude Code 写入其每会话 JSON 文件的位置；只读，也是"已连接/未连接"和"忙碌/空闲/等待"检查所读取的位置 | `$RUN_AS_USER` 的 `~/.claude/sessions` | 全局 |
| `CLAUDE_PROJECTS_DIR` | Claude Code 保存对话记录的位置；只读，在重启后接续对话前会先检查此处 | `$RUN_AS_USER` 的 `~/.claude/projects` | 全局 |
| `RESUME_AFTER_RESTART` | `1`：重启后让实例回到重启前的那段对话。`0`：总是开启新对话 | `1` | 全局 / 每实例 |
| `MAX_SESSIONS` | `new`/`resume` 一旦达到该数量的已存在实例就拒绝执行；`0` = 不限 | `0` | 全局 |
| `ENSURE_DEFAULT_INSTANCE` | `1`：开机时如果没有任何实例会启动，就创建并启动默认的 `claude-code` 实例。绝不会触碰已有启用中实例的主机。`0`：这种主机就以空白状态启动 | `1` | 全局 |

`CLAUDE_ARGS` 正是安全权衡所在之处，且与 `RUN_AS_USER` 绑定：`--dangerously-skip-permissions` 意味着会话绝不会停下来询问授权，而 `claude` 在以 root 身份运行时会拒绝该参数。`claude-guardian check` 会报告这一组合的状态，`install`/`new`/`run` 会拒绝这种不可能的组合，而不是反复重新拉起一个立刻退出的会话。改动其中任何一项之前请先阅读 `DESIGN.md` → 已知限制。

编辑 `/etc/claude-guardian/config.env` 并执行 `systemctl restart 'claude-guardian@*'` 可全局生效，或编辑某个实例自己的文件并执行 `claude-guardian restart <name>` 只对该实例生效。完整参考见 `DESIGN.md` → 配置参考。

## 其他命令

```bash
claude-guardian new <name> [--workdir D] [--args "..."] [--claude-bin PATH]
                            # 创建 + 启用 + 启动一个新实例
claude-guardian list       # 所有实例的表格
claude-guardian url <name> # 打印该实例当前的 claude.ai 远程控制 URL
claude-guardian activate <name>    # 启用 + 启动（重启后依然存活）
claude-guardian deactivate <name> [--yes]  # 只禁用 + 停止监督——tmux 会话照常运行
                                           # 如果它是开机会启动的最后一个实例，会先询问
claude-guardian archive <name> [--yes]   # 停用、保存回滚记录 + 对话 id、杀死会话
                                         # 与 deactivate 相同的"最后一个实例"警告
claude-guardian archives                 # 列出已归档的实例
claude-guardian resume <archive-id> [name]  # 从归档重新创建一个实例，接续该对话
claude-guardian rm-archive <id> [--yes]  # 永久删除一份归档

claude-guardian ensure-floor   # 按需执行的开机保底逻辑：如果没有任何实例会
                               # 开机启动，就创建 + 启用 + 启动默认实例。由
                               # claude-guardian-floor.service 自动运行；手动运行也安全
claude-guardian check      # 仅输出预检报告，不做任何改动
claude-guardian status [name]  # systemctl status（name 默认为 'claude-code'）
claude-guardian logs [name]    # 跟随某个实例的服务日志
claude-guardian stop [name]    # 停止（临时性的——'deactivate' 还会禁用开机自启）
claude-guardian uninstall  # 移除 systemd 模板（每个实例的配置/会话保持不变）
claude-guardian purge [--yes]  # 完全拆除：uninstall + 杀死每个会话 + 移除配置/二进制文件
                                # （归档不会被删除——见 rm-archive）
```

坑：在已接入的会话内，Ctrl+C 会被 `claude` 自身解释（中断当前这一轮；连按两次会退出它，退出后按设计会被自动重新拉起——手动杀死进程保证仍会留下一个正在运行的实例）。无论哪种情况，这都不是干净的分离方式。请改用 tmux 前缀 + `d`。

## 许可证

[GPL-3.0](LICENSE)。本仓库未收录任何第三方代码。
