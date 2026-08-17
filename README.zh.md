# claude-code-guardian

[English](README.md) | **简体中文**

> 译自 `README.md`（v0.2.0）。如有冲突，以英文版为准。

在 Debian 服务器上，以 root 身份常驻一个或多个命名的、可远程接管的 Claude Code（`claude`）会话，无论机器重启还是 `claude` 进程本身被杀（Ctrl+C、崩溃、`exit`）都能保证实例还在。

## 功能

- 安装一个 systemd **实例模板**，为每个命名实例监督一个专用的 `tmux` 会话，默认在其中运行 `claude --permission-mode auto --remote-control`——远程控制指的是可以直接在 **claude.ai 网页或手机上**接管任意一个实例，不只是走 SSH+tmux。
- 自动捕获每个实例的 `claude.ai/code/...` 远程控制链接（创建时捕获一次，之后每次无人值守的刷新周期再捕获一次）并保存下来——`claude-guardian url <name>` 或 `claude-guardian list` 无需接管会话即可打印出来。这样做的意义在于：完全可以从另一台设备创建、发现、接入一个会话，不需要终端。
- `claude` 无论因何退出，都会在几秒内自动重新拉起，接着同一段对话继续——tmux 会话（连同其滚动记录）不受影响。
- 整个监督进程或宿主机重启后，每一个曾经被 `activate` 过的实例都会自动回来。
- 只要某个实例暂时无人接管，就会定期"敲一下"它，防止它悄悄卡死或变得不可达：发送 Enter 清除 `auto` 权限模式在多次被分类器拦截后可能回退出现的确认弹窗，并在 Anthropic 文档所述的约 30 分钟"不可达"阈值到来之前主动重新执行 `/remote-control`。这里涉及的安全权衡见 `DESIGN.md` → Known limitations。
- 可以**暂停**一个实例（`deactivate`/`activate`：只停/恢复监督，tmux 会话继续跑），这与**归档**它（`archive`/`resume`：先保存滚动记录和对话 id，再杀掉进程；之后用 `claude --resume` 接回对话）是两件独立的事。
- 前置检查：自动安装缺失的 `apt` 包（默认是 `tmux`、`uuid-runtime`），确认 `claude` 在 `PATH` 上。`install`/`new` 阶段如果 `claude` 还没登录（通过 `claude auth status` 检测）会直接拒绝继续；实例一旦跑起来，`run` 阶段对登录状态只警告不阻塞，这样实例后续如果丢失登录状态也会继续重试，而不是直接启动失败。
- 提供 `attach` 命令，供远程操作者通过 SSH 接管某个存活的会话，作为 claude.ai 远程控制链接之外的另一条路径。
- 限制成本/资源增长：一旦并发实例数达到 `MAX_SESSIONS`（默认 3），`new` 就会拒绝——每多一个实例就是一个独立的 `claude` 进程，也是一份独立的 token 花费。

非目标：不负责安装或更新 Claude Code CLI 本身，也不对外暴露网络控制接口——生命周期管理只走 CLI（详见 `DESIGN.md`）。

## 环境要求

- 操作系统：Debian 或其衍生发行版（Ubuntu 等），需带 systemd
- 必须以 root 身份运行
- `claude` 已安装好并且在 `PATH` 上可用（或通过 `CLAUDE_BIN` 指定）——本工具不负责安装它
- `claude` 已登录（`claude auth status` 必须成功）——否则 `install` 会直接拒绝执行；先运行 `claude auth login`
- 如果 `tmux` 还没装，需要能访问外网执行 `apt-get`

## 安装

```bash
# 克隆一个 tag，不要克隆分支尖端——分支尖端可能处于改动中途。
# 查看可用 tag：git ls-remote --tags <repo-url>
git clone --depth 1 --branch v0.2.0 https://github.com/CharlesGool/claude-code-guardian.git
cd claude-code-guardian
bash bin/claude-guardian.sh install
```

`install` 会执行前置检查，把默认的全局配置写到 `/etc/claude-guardian/config.env`，把脚本安装到 `/usr/local/bin/claude-guardian`，写入 systemd **实例模板**（`claude-guardian@.service`），并创建、启用一个名为 `claude-code` 的默认实例。它不会启动这个实例——那是下一步。从 v0.1.0 升级时，会自动把原来的单一会话迁移到新模板上，且不会杀掉正在运行的 `claude` 进程。

## 快速开始

```bash
claude-guardian start
claude-guardian attach
```

以上是默认的 `claude-code` 实例。要再跑一个独立的、并发受监督的对话：

```bash
claude-guardian new work --workdir /root/some-project
claude-guardian list          # 列出每个实例：systemd/tmux 状态、是否有人接管、工作目录、远程控制链接
claude-guardian url work      # 只打印 claude.ai 链接——不需要接管
```

## 验证是否生效

- `systemctl is-active claude-guardian@claude-code` 输出 `active`。
- `claude-guardian attach` 会把你带进一个存活的 `claude` 终端。用 tmux 前缀键（默认 `Ctrl+b`）接 `d` 来分离——**不要**用 Ctrl+C（见下面的坑）。
- 在会话里真正退出 `claude`（快速按两次 Ctrl+C，或输入 `/exit`——单次 Ctrl+C 只会中断当前这一轮，不会退出）——几秒内 `claude-guardian logs` 会打印一行 `respawning automatically`，再次接管会看到 `claude` 又跑起来了，还是同一段对话。
- `claude-guardian deactivate`——`claude` 继续跑（只是暂停监督并取消开机自启，见下面的坑）；`claude-guardian activate` 恢复监督，不会重启它。
- `claude-guardian archive claude-code --yes`，再 `claude-guardian resume claude-code`——该实例从 `list` 里消失，出现在 `archives` 里，恢复后是同一段对话的延续（`claude --resume`）。
- `reboot` 宿主机——重启后，每一个曾被 `activate` 过的实例都会自动变回 `active`，不需要手动干预。

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
| `UNATTENDED_NUDGE_SEC` | 仅无人值守时生效：空闲这么多秒后发送 Enter 清除卡住的确认弹窗（`0` 表示禁用） | `300` | 全局 |
| `REMOTE_CONTROL_REFRESH_SEC` | 仅无人值守时生效：空闲这么多秒后重新执行 `/remote-control` 刷新连接并重新捕获链接（`0` 表示禁用） | `1200` | 全局 |
| `MAX_SESSIONS` | 实例数达到这个值后 `new`/`resume` 会拒绝 | `3` | 全局 |

把 `CLAUDE_ARGS` 里的 `--permission-mode auto` 去掉会改变 `DESIGN.md` → Known limitations 里描述的那个安全权衡——动手前先读那一节。

编辑 `/etc/claude-guardian/config.env` 后执行 `systemctl restart 'claude-guardian@*'` 可全局生效；只想影响单个实例的话，编辑该实例自己的配置文件，再执行 `claude-guardian restart <name>`。完整参考见 `DESIGN.md` → Configuration reference。

## 其他命令

```bash
claude-guardian new <name> [--workdir D] [--args "..."] [--claude-bin PATH]
                            # 创建 + 启用 + 启动一个新实例
claude-guardian list       # 列出所有实例的表格
claude-guardian url <name> # 打印保存下来的 claude.ai 远程控制链接
claude-guardian activate <name>    # 启用 + 启动（重启后仍会自动拉起）
claude-guardian deactivate <name>  # 禁用 + 只停止监督——tmux 会话继续留着
claude-guardian archive <name> [--yes]   # 先取消激活，保存滚动记录 + 对话 id，再杀掉会话
claude-guardian archives                 # 列出已归档的实例
claude-guardian resume <archive-id> [name]  # 从某个归档重建实例，接着对话继续
claude-guardian rm-archive <id> [--yes]  # 永久删除某个归档

claude-guardian check      # 只跑前置检查报告，不做任何改动
claude-guardian status [name]  # systemctl status（name 默认是 'claude-code'）
claude-guardian logs [name]    # 跟踪某个实例的 service 日志
claude-guardian stop [name]    # 停止（临时性的——'deactivate' 还会额外取消开机自启）
claude-guardian uninstall  # 移除 systemd 模板（每个实例的配置/会话保持不动）
claude-guardian purge [--yes]  # 彻底清除：uninstall + 杀掉所有会话 + 删除配置/二进制
                                # （归档不会被删除——见 rm-archive）
```

坑：在已接管的会话里，Ctrl+C 是被 `claude` 自己解释的（中断当前这一轮；连按两次会让它退出，然后按设计会被自动重新拉起——手动杀掉进程也保证还会剩下一个实例在跑）。无论哪种情况，这都不是一种干净的分离方式。请改用 tmux 前缀键 + `d`。

## 许可证

[GPL-3.0](LICENSE)。本仓库未打包任何第三方代码。
