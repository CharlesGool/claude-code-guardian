# claude-code-guardian

[English](README.md) | **简体中文**

> 译自 `README.md`（unreleased，对应 commit `a46c2f4`）。如有冲突，以英文版为准。

在 Debian 服务器上，以 root 身份常驻至少一个可远程接管的 Claude Code（`claude`）会话，无论机器重启还是 `claude` 进程本身被杀（Ctrl+C、崩溃、`exit`）都能保证还有一个实例在跑。

## 功能

- 安装一个 systemd 服务，监督一个专用的 `tmux` 会话，默认在其中运行 `claude --permission-mode auto --remote-control`——远程控制指的是可以直接在 **claude.ai 网页或手机上**接管这个会话，不只是走 SSH+tmux（CLI 启动时会打印一个 `claude.ai/code/...` 链接，`claude-guardian logs` 里也能看到）。
- `claude` 无论因何退出，都会在几秒内自动重新拉起——tmux 会话（连同其滚动记录）不受影响。
- 整个监督进程或宿主机重启后，systemd 会自动把它带回来。
- 无人接管期间会定期"敲一下"会话，防止它悄悄卡死或变得不可达：发送 Enter 清除 `auto` 权限模式在多次被分类器拦截后可能回退出现的确认弹窗，并在 Anthropic 文档所述的约 30 分钟"不可达"阈值到来之前主动重新执行 `/remote-control`。这里涉及的安全权衡见 `DESIGN.md` → Known limitations。
- 启动前跑前置检查：自动安装缺失的 `apt` 包（默认只有 `tmux`），确认 `claude` 在 `PATH` 上，未检测到登录凭据时只警告、不阻塞。
- 提供 `attach` 命令，供远程操作者通过 SSH 接管这个常驻会话，作为 claude.ai 远程控制链接之外的备用方式。

非目标：本工具不负责安装或更新 Claude Code CLI 本身，也不管理多个并存的命名会话（详见 `DESIGN.md`）。

## 要求

- 操作系统：Debian 或其衍生发行版（Ubuntu 等），需要 systemd
- 必须以 root 身份运行
- `claude` 已经安装好并且能在 `PATH`（或 `CLAUDE_BIN` 指定的路径）上找到——本工具不负责安装它
- 如果 `tmux` 还没装，需要能访问外网走 `apt-get`

## 安装

```bash
# 始终克隆 tag，不要克隆可能正在开发中的默认分支。
# 最新发布 tag：`git ls-remote --tags <repo-url>`
git clone --branch v0.1.0 --depth 1 <repo-url> claude-code-guardian
cd claude-code-guardian/repo
bash bin/claude-guardian.sh install
```

`install` 会跑前置检查，把默认配置写到 `/etc/claude-guardian/config.env`，把脚本安装到 `/usr/local/bin/claude-guardian`，写好并启用 systemd unit。它不会启动服务——启动是下一步。

## 快速开始

```bash
claude-guardian start
claude-guardian attach
```

## 验证是否成功

- `systemctl is-active claude-guardian` 输出 `active`。
- `claude-guardian attach` 会把你带进一个实时的 `claude` 终端。退出用 tmux 前缀键（默认 `Ctrl+b`）再按 `d`——**不要**用 Ctrl+C（见下面的坑）。
- 在会话里真正退出 `claude`（快速连按两次 Ctrl+C，或者输入 `/exit`——单次 Ctrl+C 只是打断当前轮次，不会退出）——几秒内 `claude-guardian logs` 会出现一行 `respawning automatically`，再次 attach 会看到 `claude` 又跑起来了。
- `systemctl stop claude-guardian`——`claude` 仍然在跑（stop 只是暂停监督，见下面的坑）；`claude-guardian start` 会恢复监督而不会重启它。
- `reboot` 宿主机——开机后 `systemctl is-active claude-guardian` 会自动变回 `active`，不需要人工干预。

## 配置

| 变量 | 含义 | 默认值 | 必填 |
|---|---|---|---|
| `SESSION_NAME` | 承载 `claude` 的 tmux 会话名 | `claude-code` | 否 |
| `TMUX_SOCKET` | 专用 tmux server 的 socket 路径 | `/run/claude-guardian/tmux.sock` | 否 |
| `WORKDIR` | `claude` 启动时的工作目录 | `/root` | 否 |
| `CLAUDE_BIN` | `claude` 可执行文件名或绝对路径 | `claude` | 否 |
| `CLAUDE_ARGS` | 每次（重）启动时传给 claude 的额外参数 | `--permission-mode auto --remote-control` | 否 |
| `CHECK_INTERVAL_SEC` | 存活检查的间隔秒数 | `5` | 否 |
| `REQUIRED_APT_PKGS` | 缺失时自动安装的 apt 包（空格分隔） | `tmux` | 否 |
| `UNATTENDED_NUDGE_SEC` | 仅无人接管时：空闲这么多秒后发送 Enter 清除卡住的确认弹窗（`0` 关闭） | `300` | 否 |
| `REMOTE_CONTROL_REFRESH_SEC` | 仅无人接管时：空闲这么多秒后重新执行 `/remote-control` 刷新连接（`0` 关闭） | `1200` | 否 |

把 `CLAUDE_ARGS` 里的 `--permission-mode auto` 去掉会改变 `DESIGN.md` → Known limitations 里描述的那个安全权衡——先读那节再改。

编辑 `/etc/claude-guardian/config.env` 后执行 `systemctl restart claude-guardian` 生效。完整说明见 `DESIGN.md` 的 Configuration reference。

## 其他命令

```bash
claude-guardian check      # 只跑前置检查报告，不做任何改动
claude-guardian status     # systemctl status
claude-guardian logs       # 跟踪服务日志
claude-guardian stop       # 停止监督（tmux 会话本身继续运行）
claude-guardian uninstall  # 移除 systemd 服务（配置和会话都不受影响）
```

坑：在已 attach 的会话里，Ctrl+C 是被 `claude` 自己解释的（打断当前轮次；连按两次才会退出，退出后会按设计被自动重新拉起——这样才能保证手动杀掉也一定还有实例在跑）。不管哪种情况，这都不是一种干净的"离开会话"方式。请用 tmux 前缀键 + `d`。

## 许可证

私有项目。保留所有权利——未授予任何复用、修改或再分发许可。
