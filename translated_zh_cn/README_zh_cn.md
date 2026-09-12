# claude-code-guardian

[English](../README.md) | **简体中文**

> 译自 `README.md`（v0.10.0）。如有冲突，以英文版为准。

在 Debian 服务器上保持一个或多个具名、可远程连接的 Claude Code（`claude`）会话持续存活，无论是主机重启还是 `claude` 进程本身被杀掉（Ctrl+C、崩溃、`exit`）都能挺过去。root 负责安装与监管，会话本身则以普通账号运行。

## 功能说明

- 安装一个 systemd **实例模板**，为每个具名实例监管一个专属的 `tmux` 会话，默认在其中运行 `claude --dangerously-skip-permissions --remote-control`——远程控制意味着你可以在 **claude.ai 网页端或手机上**接管任意一个实例，不局限于 SSH+tmux。
- **会话属于一个普通账号，而不是 root。**`RUN_AS_USER` 指定了拥有 tmux 服务器、每一个 `claude` 进程、以及 `claude` 写下的一切内容的账号；root 只负责安装、监管、以及运行管理命令。`install` 会采用你 `sudo` 时所在的那个账号。这不是为了硬化而硬化：`claude` 在以 root 身份运行时会直接拒绝 `--dangerously-skip-permissions`，所以一个绝不能停下来问权限的无人值守会话，*必须*以别的身份运行。直接以 root 身份安装的主机依然可以工作——它会改用 `--permission-mode auto --remote-control`，而"root 加上跳过权限的参数"这个组合会在门口就被拒绝，而不是留着无限重生。
- 知道每个实例当前的 `claude.ai/code/...` 远程控制 URL——`claude-guardian url <name>` 或 `claude-guardian list` 会打印出来，全程无需 attach。要点在于：完全可以从另一台设备创建、发现、连接一个会话，不需要终端。需要时再取，不要收藏它：每次远程控制重连，这个 URL 都会变。
- 如果 `claude` 因任何原因退出，会在几秒内自动重新拉起，接续同一段对话——tmux 会话（及其回滚缓冲区）都会保留下来。
- 如果整个监管进程或主机重启，每一个被 `activate` 过的实例都会自动恢复——**恢复到重启前的那段对话**，而不是一个空会话。重启会把 tmux 服务器一并带走，所以会话是从头重建的；只要该实例的对话记录仍在磁盘上，就会用 `claude --resume` 接续原来的对话（`RESUME_AFTER_RESTART=0` 可以关掉这个行为）。如果一段对话已经无法恢复，就退回新建一个，而不会让该实例卡住。
- **让每一个实例持续可连接。**远程控制会自行断线——服务端超时、网络抖动——而且不会有任何提示：会话本身照常工作，只是从 claude.ai 那边连不上了。每一次监管轮询（`REMOTE_CONTROL_CHECK_SEC`，默认 5 秒）监管进程都会读取 Claude Code 自身的会话文件，检查连接是否仍然畅通，一旦断开就立即重连，并取得新的 URL。这个检查本身不会往会话里输入任何内容；只有实际重连才会，而重连受 `REMOTE_CONTROL_RECONNECT_BACKOFF_SEC`（默认 60 秒）限速，避免对一个连不上的实例反复输入。
- **默认绝不替你回答确认对话框。**卡在权限提示上的会话可以靠发送回车解开——但回车会接受对话框里当前高亮的选项，等于替你做了决定，而从外部根本无法分辨"这是被放弃的"还是"你只是还没来得及回答"。所以自 v0.6.0 起 `UNATTENDED_NUDGE_SEC` 默认是 `0`（关闭）。如果你更希望无人值守的实例能自行解卡，就把它设成一个秒数；即便如此，它也只会对 Claude Code 自身报告为"卡在对话框上"的会话输入，绝不会对正在工作或空闲的会话输入。参见 `DESIGN.md` → Known limitations。
- 可以**暂停**一个实例（`deactivate`/`activate`：停止/恢复监管，tmux 会话本身继续运行），与**归档**一个实例（`archive`/`resume`：保存回滚缓冲区和对话 ID，然后杀掉进程；之后用 `claude --resume` 接续对话）相互独立。
- **绝不会以"什么都没在跑"开机。**归档或停用实例可能导致一个都不剩，而在 v0.9.0 之前，处于这种状态的主机重启后会悄无声息地不带任何对话回来。现在有两道防线阻止这一点：当被移除的实例是重启时唯一会起来的那个时，`archive` 和 `deactivate` 会警告（且在没有 `--yes` 时会先询问）；此外一个开机单元（`claude-guardian-floor.service`）会在没有任何其他实例会起来时创建并启动默认的 `claude-code` 实例。如果你更希望没有已启用实例的主机就以空跑开机，设置 `ENSURE_DEFAULT_INSTANCE=0`。
- 运行预检：自动安装缺失的 `apt` 包（默认 `tmux`、`uuid-runtime`），校验 `claude` 在 `PATH` 上。`install`/`new` 在 `claude` 尚未登录时会拒绝继续（通过 `claude auth status` 校验）；一旦运行起来，`run` 只会对登录状态发出警告，这样一个后来失去认证的实例会不断重试，而不是启动失败。
- 提供 `attach` 命令，让远程操作者通过 SSH 接管一个存活会话，作为 claude.ai 远程控制 URL 之外的另一种方式。
- 可选的成本/资源增长护栏：设置 `MAX_SESSIONS`，一旦已存在这么多实例，`new` 就会拒绝——每个实例都是独立的 `claude` 进程和独立的 token 开销。默认无限制（`0`）。

非目标：本工具不安装或更新 Claude Code CLI 本身，也不暴露网络控制 API——生命周期管理仅通过命令行进行（见 `DESIGN.md`）。

## 环境要求

- 操作系统：Debian 或带 systemd 的 Debian 衍生版（Ubuntu 等）
- 每条写入 `/etc`、`/var/lib` 或 systemd 的命令都需要 root——`sudo` 就够了，通常的用法是在你自己的账号下运行 `sudo claude-guardian <command>`
- 一个供会话运行的账号（`RUN_AS_USER`）。`install` 使用你 `sudo` 背后的那个账号；没有的话回退到 root。`runuser`（util-linux 提供，通常已经预装）是 root 借以扮演该账号的手段
- **该账号**需要安装 `claude` 且能在其 `PATH`（或通过 `CLAUDE_BIN`）上找到——本工具不负责安装它。常见的 `~/.local/bin/claude` 即便不在 systemd 的 `PATH` 上也能被找到
- **该账号**下的 `claude` 需要已经登录（该账号下 `claude auth status` 必须成功）——否则 `install` 会拒绝继续；请先以该用户身份运行 `claude auth login`。登录状态属于某一个账号：root 已登录并不能说明会话账号也已登录
- 如果 `tmux` 尚未安装，需要联网以便 `apt-get` 安装

## 安装

```bash
# 克隆某个 tag，而不是分支的最新提交——分支尖端可能处于修改中。
# 列出可用的 tag：git ls-remote --tags <repo-url>
git clone --depth 1 --branch v0.10.0 https://github.com/CharlesGool/claude-code-guardian.git
cd claude-code-guardian
sudo bash bin/claude-guardian.sh install
```

用会话应归属的那个账号执行 `sudo` 来运行：`install` 会把该账号（`$SUDO_USER`）记录为 `RUN_AS_USER`，并以该用户身份解析 `claude` 及其登录状态。随后它会运行预检、把默认全局配置写入 `/etc/claude-guardian/config.env`、把脚本安装到 `/usr/local/bin/claude-guardian`、写入 systemd **实例模板**（`claude-guardian@.service`，其中带有 `User=$RUN_AS_USER`）以及**开机兜底单元**（`claude-guardian-floor.service`）、把状态目录和 socket 目录移交给该账号，并创建并启用一个名为 `claude-code` 的默认实例。它不会启动该实例——那是下一步。从 v0.1.0 版本升级会自动把它原有的单一会话迁移到新模板上，且不会杀掉正在运行的 `claude` 进程。

从更早的任何版本升级：重新运行 `sudo bash bin/claude-guardian.sh install` 即可。它是幂等的，且会保留已有的 `config.env` 不做改动，所以在该文件写下之后才新增的配置项——`ENSURE_DEFAULT_INSTANCE`，以及现在的 `RUN_AS_USER`——不会出现在其中，其内置默认值会一直生效，直到你自己把它们加进去。对 `RUN_AS_USER` 而言，那个默认值是 `root`，所以**升级后的主机会照旧以原来的方式运行会话**；把会话迁到一个普通账号是一个刻意、单向的步骤：

```bash
# 1. 归档每一个实例（保存回滚缓冲区 + 对话 ID，杀掉会话）
sudo claude-guardian archive <name> --yes
# 2. 把对话记录复制过去——它们存放在旧账号的 ~/.claude 里，
#    新账号读不到。目录名取自工作目录，
#    所有非字母数字字符都被替换成了 '-'
sudo cp /root/.claude/projects/-root/<conversation-id>.jsonl \
        /home/you/.claude/projects/-home-you/
sudo chown you:you /home/you/.claude/projects/-home-you/<conversation-id>.jsonl
# 3. 把 RUN_AS_USER 指向新账号并重新安装，然后重新创建
#    实例（`resume <archive-id>` 会接续对话；如果归档的工作目录是
#    旧账号的家目录，先编辑该归档的 meta.env）
sudoedit /etc/claude-guardian/config.env
sudo claude-guardian install
```

一个由旧账号拥有的存活 tmux 服务器会阻挡新账号；`install` 会说明原因并停止，而不是让其会话变成孤儿。仅仅是服务器已经不在了、留下的一个 socket 文件则会被自动清理。存活中的实例不会被 `install` 重启。

### 可选：`claude-session` 技能

`skills/claude-session/` 是一个 Agent Skill，教会 Claude Code 用大白话（"开一个常驻对话"、"list my sessions"、"archive this one"）来驱动这些命令，而不必你自己记住这套命令行。它同时把破坏性命令的规则也编码了进去——`archive` 和 `purge` 会杀掉存活的 `claude` 进程，所以这个技能要求你明确点名了这个动作才会执行其中任何一个。

```bash
cp -r skills/claude-session ~/.claude/skills/
```

这是可选的，且不会改变工具本身的任何行为：有没有它，`claude-guardian` 的表现完全一样。

## 快速上手

```bash
claude-guardian start
claude-guardian attach
```

这就是默认的 `claude-code` 实例。要运行第二个独立、并行受监管的对话：

```bash
claude-guardian new work --workdir /home/you/some-project
claude-guardian list          # 每个实例：systemd/tmux 状态、是否已连接、工作目录、远程控制 URL
claude-guardian url work      # 只打印 claude.ai 的 URL——无需 attach
```

## 验证是否正常工作

- `systemctl is-active claude-guardian@claude-code` 打印 `active`。
- `claude-guardian attach` 会把你带入一个存活的 `claude` 终端。用 tmux 前缀键（默认 `Ctrl+b`）再按 `d` 来 detach——**不要**用 Ctrl+C（见下方的坑）。
- 从会话内部真正退出 `claude`（快速连按两次 Ctrl+C，或输入 `/exit`——单独一次 Ctrl+C 只会中断当前这一轮，不会退出）——几秒内 `claude-guardian logs` 会显示一行 `respawning automatically`，再次 attach 会看到 `claude` 又跑起来了，还是同一段对话。
- `claude-guardian deactivate`——`claude` 会继续运行（只是暂停监管并禁用开机自启，见下方的坑）；`claude-guardian activate` 会恢复对它的监视，且不会重启它。如果它是你唯一的实例，现在会先警告主机重启后将空跑并先询问；传 `--yes` 可以跳过这个询问。
- 开机兜底：让每个实例都处于停用或归档状态，运行 `systemctl start claude-guardian-floor` 会记录 `no instance would come up at boot` 并把 `claude-code` 拉起来——几秒内 `claude-guardian list` 就会显示它是 `active`/`up`。再运行一次会记录 `already enabled — nothing to do`，不会创建第二个会话。这正是开机时运行的同一个单元。
- `claude-guardian archive claude-code --yes` 然后 `claude-guardian resume claude-code`——该实例从 `list` 中消失，出现在 `archives` 里，回来时接续的是同一段对话（`claude --resume`）。
- 在会话内部断开远程控制（`/remote-control` → `Disconnect this session`）然后 detach——在 `REMOTE_CONTROL_CHECK_SEC`（默认 5 秒）之内，`claude-guardian logs <name>` 会显示 `remote control disconnected ... reconnecting`，随后跟着一个 URL，`claude-guardian url <name>` 会打印出那个新 URL。只要连接健康，日志就保持静默，这正是设计意图：不需要输入的会话不会被输入任何内容。
- 对主机执行 `reboot`——开机后，每一个曾被 `activate` 过的实例都会无需人工干预地重新变为 `active`，`claude-guardian logs <name>` 会显示一行 `continuing this instance's previous conversation`。attach 一下：重启前的那段对话仍然还在。（不重启的等价做法：`claude-guardian stop <name>`，用 `tmux -S /run/claude-guardian/tmux.sock kill-session -t <name>` 杀掉它的 tmux 会话，再 `claude-guardian start <name>`——效果相同。）

- 从一份克隆里运行 `bash tests/run-as-user.sh`——针对会话账号这一层的隔离检查（单元以谁的身份运行、生成的配置和单元文件里有什么内容、哪些组合会被拒绝）。它不安装任何东西，不需要 root，也从不触碰任何存活会话。

## 配置

全局默认值存放在 `/etc/claude-guardian/config.env`。按实例的覆盖项（`WORKDIR`、`CLAUDE_ARGS`、`CLAUDE_BIN`）在创建时通过 `new --workdir`/`--args`/`--claude-bin` 设置，存放在 `/etc/claude-guardian/instances/<name>.env`。

| 变量 | 含义 | 默认值 | 作用范围 |
|---|---|---|---|
| `TMUX_SOCKET` | 共享的 tmux 服务器 socket 路径 | `/run/claude-guardian/tmux.sock` | 全局 |
| `RUN_AS_USER` | tmux 服务器、`claude`、以及监管循环所运行的账号。每台主机一个：所有实例共享同一个 tmux 服务器，而一个 tmux 服务器只属于一个账号。改动它需要重新 `install`（单元文件里带有 `User=`），并且需要新账号已完成 `claude` 登录——对话保留在旧账号的 `~/.claude` 里，不会跟着迁移 | `install` 时 `sudo` 所在的账号，否则为 `root` | 全局 |
| `WORKDIR` | `claude` 启动时所在的工作目录 | `$RUN_AS_USER` 的家目录 | 全局 / 按实例 |
| `CLAUDE_BIN` | `claude` 可执行文件名或绝对路径，在安装时以 `$RUN_AS_USER` 身份解析 | `claude` | 全局 / 按实例 |
| `CLAUDE_ARGS` | 每次（重新）启动时附加传入的命令行参数 | `--dangerously-skip-permissions --remote-control`，当会话以 root 身份运行时为 `--permission-mode auto --remote-control` | 全局 / 按实例 |
| `CHECK_INTERVAL_SEC` | 存活检查之间的间隔秒数 | `5` | 全局 |
| `REQUIRED_APT_PKGS` | 缺失时自动安装的 apt 包，以空格分隔 | `tmux uuid-runtime` | 全局 |
| `UNATTENDED_NUDGE_SEC` | 仅用于无人值守：确认对话框在未被回答这么久之后发送一次回车，替你把它答掉。`0` = 永不（默认）。对正在工作或处于提示符的会话永远不会发送任何内容 | `0` | 全局 |
| `REMOTE_CONTROL_CHECK_SEC` | 仅用于无人值守：连接检查的间隔秒数；该检查是被动的，不输入任何内容，所以可以低到与轮询间隔一致（`0` 表示关闭） | `5` | 全局 |
| `REMOTE_CONTROL_RECONNECT_BACKOFF_SEC` | 两次重连尝试之间的最小间隔秒数——重连是往会话里输入 `/remote-control` 的那一步 | `60` | 全局 |
| `CLAUDE_SESSIONS_DIR` | Claude Code 写入其逐会话 JSON 文件的位置；只读，"已连接/已断开"及"忙碌/空闲/等待中"的检查都读取这里 | `$RUN_AS_USER` 的 `~/.claude/sessions` | 全局 |
| `CLAUDE_PROJECTS_DIR` | Claude Code 保存对话记录的位置；只读，在重启后接续对话之前会先检查这里 | `$RUN_AS_USER` 的 `~/.claude/projects` | 全局 |
| `RESUME_AFTER_RESTART` | `1`：重启后让实例恢复到重启前的对话。`0`：总是新建一个 | `1` | 全局 / 按实例 |
| `MAX_SESSIONS` | 一旦已存在这么多实例，`new`/`resume` 就会拒绝；`0` = 不限 | `0` | 全局 |
| `ENSURE_DEFAULT_INSTANCE` | `1`：开机时，如果压根没有任何实例会起来，就创建并启动默认的 `claude-code` 实例。绝不会碰一台已有已启用实例的主机。`0`：这样的主机会以空跑开机 | `1` | 全局 |

`CLAUDE_ARGS` 正是安全权衡所在，并且与 `RUN_AS_USER` 绑在一起：`--dangerously-skip-permissions` 意味着会话永远不会停下来询问，而 `claude` 在 root 身份下会拒绝这个参数。`claude-guardian check` 会报告这个组合的情况，`install`/`new`/`run` 会拒绝这种不可能的组合，而不是去重生一个会立刻退出的会话。改动其中任何一个之前，先读 `DESIGN.md` → Known limitations。

编辑 `/etc/claude-guardian/config.env` 并执行 `systemctl restart 'claude-guardian@*'` 可全局生效，或编辑某个实例自己的文件并对该实例执行 `claude-guardian restart <name>`。完整参考见 `DESIGN.md` → Configuration reference。

## 其他命令

```bash
claude-guardian new <name> [--workdir D] [--args "..."] [--claude-bin PATH]
                            # 创建 + 启用 + 启动一个新实例
claude-guardian list       # 每个实例的表格
claude-guardian url <name> # 打印该实例当前的 claude.ai 远程控制 URL
claude-guardian activate <name>    # 启用 + 启动（重启后仍存活）
claude-guardian deactivate <name> [--yes]  # 仅禁用 + 停止监管——tmux 会话保持运行
                                           # 如果它是重启后唯一会起来的实例，会先询问
claude-guardian archive <name> [--yes]   # 停用、保存回滚缓冲区 + 对话 ID、杀掉会话
                                         # 与 deactivate 相同的"最后一个实例"警告
claude-guardian archives                 # 列出已归档的实例
claude-guardian resume <archive-id> [name]  # 从一份归档重建一个实例，接续对话
claude-guardian rm-archive <id> [--yes]  # 永久删除一份归档

claude-guardian ensure-floor   # 按需执行开机兜底：如果没有任何实例会
                               # 在开机时起来，创建 + 启用 + 启动默认实例。由
                               # claude-guardian-floor.service 自动运行；手动运行也是安全的
claude-guardian check      # 只出预检报告，不做任何改动
claude-guardian status [name]  # systemctl status（name 默认为 'claude-code'）
claude-guardian logs [name]    # 跟随某个实例的服务日志
claude-guardian stop [name]    # 停止（临时性——'deactivate' 还会顺带禁用开机自启）
claude-guardian uninstall  # 移除 systemd 模板（每个实例的配置/会话保持不动）
claude-guardian purge [--yes]  # 彻底清除：uninstall + 杀掉每一个会话 + 移除配置/二进制
                                # （归档不会被删除——见 rm-archive）
```

坑：在一个已 attach 的会话内部，Ctrl+C 是被 `claude` 自身解释的（中断当前这一轮；连按两次会退出它，之后会按设计被自动重新拉起——手动杀掉也保证依然会留下一个正在运行的实例）。无论哪种情况，这都不是一种干净的 detach 方式。请改用 tmux 前缀键 + `d`。

## 许可证

[GPL-3.0](LICENSE)。本仓库不内嵌任何第三方代码。
