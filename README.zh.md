# claude-code-guardian

[English](README.md) | **简体中文**

> 译自 `README.md`（v0.5.0）。如有冲突，以英文版为准。

在 Debian 服务器上，以 root 身份常驻一个或多个命名的、可远程接管的 Claude Code（`claude`）会话，无论机器重启还是 `claude` 进程本身被杀（Ctrl+C、崩溃、`exit`）都能保证实例还在。

## 功能

- 安装一个 systemd **实例模板**，为每个命名实例监督一个专用的 `tmux` 会话，默认在其中运行 `claude --permission-mode auto --remote-control`——远程控制指的是可以直接在 **claude.ai 网页或手机上**接管任意一个实例，不只是走 SSH+tmux。
- 掌握每个实例当前的 `claude.ai/code/...` 远程控制链接——`claude-guardian url <name>` 或 `claude-guardian list` 无需接管会话即可打印出来。这样做的意义在于：完全可以从另一台设备创建、发现、接入一个会话，不需要终端。用的时候现取，不要收藏成书签：远程控制每次重连，链接都会变。
- `claude` 无论因何退出，都会在几秒内自动重新拉起，接着同一段对话继续——tmux 会话（连同其滚动记录）不受影响。
- 整个监督进程或宿主机重启后，每一个曾经被 `activate` 过的实例都会自动回来——而且是**接着重启前那段对话**，不是一个空会话。重启会把 tmux 服务器一起带走，所以会话是从零重建的；只要该实例的对话记录还在磁盘上，就会用 `claude --resume` 把对话接回来（设置 `RESUME_AFTER_RESTART=0` 可关闭）。如果某段对话已经无法恢复，就退回开一段新对话，而不是让实例卡在那里。
- 只要没有人接管某个实例，就会盯着它，防止它悄悄卡死或变得不可达——判断依据是读取 Claude Code 自己的会话文件，所以一个健康的实例绝不会被输入任何东西：
  - 如果它停在一个确认弹窗上超过 `UNATTENDED_NUDGE_SEC` 秒且没人来回应，就发送 Enter 把弹窗清掉。正在工作的会话、或者停在空提示符等待输入的会话，都不会被打扰——包括有人正在 claude.ai 上操作的会话，这类会话没有接入的 tmux 客户端，否则会被误判成无人照看。
  - 检查远程控制是否还连着，断了就重连并取回新的链接。

  这里涉及的权衡见 `DESIGN.md` → Known limitations。
- 可以**暂停**一个实例（`deactivate`/`activate`：只停/恢复监督，tmux 会话继续跑），这与**归档**它（`archive`/`resume`：先保存滚动记录和对话 id，再杀掉进程；之后用 `claude --resume` 接回对话）是两件独立的事。
- 前置检查：自动安装缺失的 `apt` 包（默认是 `tmux`、`uuid-runtime`），确认 `claude` 在 `PATH` 上。`install`/`new` 阶段如果 `claude` 还没登录（通过 `claude auth status` 检测）会直接拒绝继续；实例一旦跑起来，`run` 阶段对登录状态只警告不阻塞，这样实例后续如果丢失登录状态也会继续重试，而不是直接启动失败。
- 提供 `attach` 命令，供远程操作者通过 SSH 接管某个存活的会话，作为 claude.ai 远程控制链接之外的另一条路径。
- 可选的成本/资源增长护栏：设置 `MAX_SESSIONS` 后，一旦已有实例数达到这个值，`new` 就会拒绝——每多一个实例就是一个独立的 `claude` 进程，也是一份独立的 token 花费。默认不限制（`0`）。

非目标：不负责安装或更新 Claude Code CLI 本身，也不对外暴露网络控制接口——生命周期管理只走 CLI（详见 `DESIGN.md`）。

## 环境要求

- 操作系统：Debian 或其衍生发行版（Ubuntu 等），需带 systemd
- 必须以 root 身份运行
- `claude` 已安装好并且在 `PATH` 上可用（或通过 `CLAUDE_BIN` 指定）——本工具不负责安装它
- `claude` 已登录（`claude auth status` 必须成功）——否则 `install` 会直接拒绝执行；先运行 `claude auth login`
- 如果 `tmux` 还没装，需要能访问外网执行 `apt-get`

## 安装

```bash
# Clone a tag, not the branch tip — the tip can be mid-change.
# List available tags: git ls-remote --tags <repo-url>
git clone --depth 1 --branch v0.4.0 https://github.com/CharlesGool/claude-code-guardian.git
cd claude-code-guardian
bash bin/claude-guardian.sh install
```

`install` 会执行前置检查，把默认的全局配置写到 `/etc/claude-guardian/config.env`，把脚本安装到 `/usr/local/bin/claude-guardian`，写入 systemd **实例模板**（`claude-guardian@.service`），并创建、启用一个名为 `claude-code` 的默认实例。它不会启动这个实例——那是下一步。从 v0.1.0 升级时，会自动把原来的单一会话迁移到新模板上，且不会杀掉正在运行的 `claude` 进程。

### 可选：`claude-session` skill

`skills/claude-session/` 是一个 Agent Skill，让 Claude Code 能直接听懂自然语言来调用这些命令（"开一个常驻对话"、"列一下我的对话"、"归档这个"），不用你去记 CLI。它同时把破坏性命令的规则写了进去——`archive` 和 `purge` 会杀掉正在运行的 `claude` 进程，所以这个 skill 要求用户明确点名该动作后才会执行。

```bash
cp -r skills/claude-session ~/.claude/skills/
```

装不装都行，它不改变工具本身：没有它，`claude-guardian` 的行为完全一样。

## 快速开始

```bash
claude-guardian start
claude-guardian attach
```

以上是默认的 `claude-code` 实例。要再跑一个独立的、并发受监督的对话：

```bash
claude-guardian new work --workdir /root/some-project
claude-guardian list          # every instance: systemd/tmux state, attached?, workdir, remote-control URL
claude-guardian url work      # print just the claude.ai URL — no attach needed
```

## 验证是否生效

- `systemctl is-active claude-guardian@claude-code` 输出 `active`。
- `claude-guardian attach` 会把你带进一个存活的 `claude` 终端。用 tmux 前缀键（默认 `Ctrl+b`）接 `d` 来分离——**不要**用 Ctrl+C（见下面的坑）。
- 在会话里真正退出 `claude`（快速按两次 Ctrl+C，或输入 `/exit`——单次 Ctrl+C 只会中断当前这一轮，不会退出）——几秒内 `claude-guardian logs` 会打印一行 `respawning automatically`，再次接管会看到 `claude` 又跑起来了，还是同一段对话。
- `claude-guardian deactivate`——`claude` 继续跑（只是暂停监督并取消开机自启，见下面的坑）；`claude-guardian activate` 恢复监督，不会重启它。
- `claude-guardian archive claude-code --yes`，再 `claude-guardian resume claude-code`——该实例从 `list` 里消失，出现在 `archives` 里，恢复后是同一段对话的延续（`claude --resume`）。
- `reboot` 宿主机——重启后，每一个曾被 `activate` 过的实例都会自动变回 `active`，不需要手动干预，而且 `claude-guardian logs <name>` 会打印一行 `continuing this instance's previous conversation`。接管进去看：重启前的那段对话还在。（不想重启机器也可以这样验证：`claude-guardian stop <name>`，用 `tmux -S /run/claude-guardian/tmux.sock kill-session -t <name>` 杀掉它的 tmux 会话，再 `claude-guardian start <name>`——效果一样。）

## 配置

全局默认值放在 `/etc/claude-guardian/config.env`。每个实例的覆盖项（`WORKDIR`、`CLAUDE_ARGS`、`CLAUDE_BIN`）在创建时通过 `new --workdir`/`--args`/`--claude-bin` 设置，存放在 `/etc/claude-guardian/instances/<name>.env`。

| 变量 | 含义 | 默认值 | 作用域 |
|---|---|---|---|
| `TMUX_SOCKET` | 共享的 tmux 服务器 socket 路径 | `/run/claude-guardian/tmux.sock` | 全局 |
| `WORKDIR` | `claude` 启动时所在的工作目录 | `/root` | 全局 / 可按实例覆盖 |
| `CLAUDE_BIN` | `claude` 可执行文件名或绝对路径 | `claude` | 全局 / 可按实例覆盖 |
| `CLAUDE_ARGS` | 每次（重）启动时附带的额外 CLI 参数 | `--permission-mode auto --remote-control` | 全局 / 可按实例覆盖 |
| `CHECK_INTERVAL_SEC` | 存活检查的间隔秒数 | `5` | 全局 |
| `REQUIRED_APT_PKGS` | 缺失时自动安装的 apt 包，空格分隔 | `tmux uuid-runtime` | 全局 |
| `UNATTENDED_NUDGE_SEC` | 仅无人值守时生效：确认弹窗无人应答达到这么多秒后，发送一次 Enter（`0` 表示禁用）。正在工作或停在提示符等待输入的会话不会收到任何输入 | `300` | 全局 |
| `REMOTE_CONTROL_REFRESH_SEC` | 仅无人值守时生效：每隔这么多秒检查一次远程控制是否还连着，断了就重连（`0` 表示禁用） | `1200` | 全局 |
| `CLAUDE_SESSIONS_DIR` | Claude Code 写每个会话 JSON 文件的位置；只读，连接/断开以及忙碌/空闲/等待输入这些判断读的都是这里 | `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/sessions` | 全局 |
| `CLAUDE_PROJECTS_DIR` | Claude Code 存放对话记录的位置；只读，重启后恢复对话前会先检查这里 | `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects` | 全局 |
| `RESUME_AFTER_RESTART` | `1`：重启后让实例接着之前那段对话回来。`0`：总是开一段新对话 | `1` | 全局 / 可按实例覆盖 |
| `MAX_SESSIONS` | 已有实例数达到这个值后，`new`/`resume` 会拒绝；`0` = 不限制 | `0` | 全局 |

把 `CLAUDE_ARGS` 里的 `--permission-mode auto` 去掉会改变 `DESIGN.md` → Known limitations 里描述的那个安全权衡——动手前先读那一节。

编辑 `/etc/claude-guardian/config.env` 后执行 `systemctl restart 'claude-guardian@*'` 可全局生效；只想影响单个实例的话，编辑该实例自己的配置文件，再执行 `claude-guardian restart <name>`。完整参考见 `DESIGN.md` → Configuration reference。

## 其他命令

```bash
claude-guardian new <name> [--workdir D] [--args "..."] [--claude-bin PATH]
                            # create + enable + start a new instance
claude-guardian list       # table of every instance
claude-guardian url <name> # print the instance's current claude.ai remote-control URL
claude-guardian activate <name>    # enable + start (survives reboot)
claude-guardian deactivate <name>  # disable + stop supervision only — tmux session left running
claude-guardian archive <name> [--yes]   # deactivate, save scrollback + conversation id, kill the session
claude-guardian archives                 # list archived instances
claude-guardian resume <archive-id> [name]  # recreate an instance from an archive, continue the conversation
claude-guardian rm-archive <id> [--yes]  # permanently delete one archive

claude-guardian check      # preflight report only, no changes
claude-guardian status [name]  # systemctl status (name defaults to 'claude-code')
claude-guardian logs [name]    # follow one instance's service journal
claude-guardian stop [name]    # stop (temporary — 'deactivate' also disables at boot)
claude-guardian uninstall  # remove the systemd template (every instance's config/session left untouched)
claude-guardian purge [--yes]  # full teardown: uninstall + kill every session + remove config/binary
                                # (archives are NOT deleted — see rm-archive)
```

坑：在已接管的会话里，Ctrl+C 是被 `claude` 自己解释的（中断当前这一轮；连按两次会让它退出，然后按设计会被自动重新拉起——手动杀掉进程也保证还会剩下一个实例在跑）。无论哪种情况，这都不是一种干净的分离方式。请改用 tmux 前缀键 + `d`。

## 许可证

[GPL-3.0](LICENSE)。本仓库未打包任何第三方代码。
