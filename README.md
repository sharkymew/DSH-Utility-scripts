# DeepSeek Harness 多平台安装器

一套面向 **macOS / Linux / Windows** 的 DeepSeek Harness（`dsh`）安装与管理工具，支持两种官方安装方式，并附带服务管理、插件安装/卸载、更新，以及一个可选的实验性 dsh Skill。

> DeepSeek Harness 目前处于开发者预览阶段，兼容性破坏性变更随时可能发生。

## 特性

- **两种官方安装方式**：
  1. **npx 快捷模式** — `npx --yes @deepseek-ai/dsh web`，启动快、每次启动自动使用最新发布版；
  2. **源码模式** — `git clone https://github.com/deepseek-ai/deepseek-harness.git` + `pnpm install` + `pnpm run build`，适合读改源码；已有仓库会被复用并尝试 `git pull`，但不会被默认卸载流程删除。
- **服务管理**：后台启动 / 停止 / 重启 / 状态 / 日志 / 浏览器打开，Web UI 默认 http://127.0.0.1:3080。
- **插件管理**：安装、移除、更新、列表、搜索 dsh 插件（底层转发 `dsh plugin --profile web`，支持 npm 包名、`github:用户/仓库`、本地路径、tarball）。
- **依赖自动处理**：Node.js（要求 ^22.19.0 或 >=24.0.0）、pnpm、git 缺失时自动安装到用户目录，**全程无需 sudo / 管理员权限**。
- **可选实验性 Skill**：无 TTY 自动非交互、`-y` 显式非交互、`--json` 机器可读输出、稳定退出码（0=成功 1=错误 2=未运行）；**安装时不会默认注册或注入 Skill**。仅在用户明确需要时手动执行 `skill` 注册，且该功能未经完整测试。
- **国内网络友好**：`--registry` 指定 npm 镜像、`--clone-url` 指定 git 镜像；`--api-key` 一键写入 `~/.dsh/.env`。
- **安全卸载**：卸载前多重守卫（目录/进程归属校验、交互确认），`--purge` 可连 `~/.dsh` 数据目录一并清除；外部安装清理始终要求真实交互终端中的二次确认。

## 文件

| 文件 | 说明 |
| --- | --- |
| `install.sh` | macOS / Linux 安装器（bash 3.2+，单文件可分发） |
| `install.ps1` | Windows 安装器（PowerShell 5.1+，UTF-8 BOM） |
| `install.bat` | Windows 双击入口（自动绕过执行策略） |
| `skills/dsh-installer/SKILL.md` | 可选、实验性、未经完整测试的 Skill 模板；仅在明确需要时注册或手动复制 |
| `README.md` | 本文档 |

## 快速开始

### macOS / Linux

```sh
# 方式一：直接运行（交互式）
./install.sh install

# 方式二：非交互安装（供脚本 / dsh 调用）
./install.sh install -y --mode npx

# 指定端口与国内镜像
./install.sh install -y --mode npx --port 8080 --registry https://registry.npmmirror.com

# 源码安装（默认克隆到 ~/deepseek-harness）
./install.sh install -y --mode source --dir ~/deepseek-harness
```

安装完成后会创建 `~/.local/bin/dsh-web`（前台启动）与 `~/.local/bin/dsh-installer`（本工具命令入口）。安装器会加入当前进程的 `PATH`，并在交互式安装时询问是否写入 shell 启动文件；新终端仍可手动执行：

```sh
export PATH="$HOME/.local/bin:$PATH"   # 建议写入 ~/.bashrc / ~/.zshrc
```

### Windows

- 双击 `install.bat`，或：
- PowerShell 中运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 install
# 或非交互
powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 install -y --mode npx
```

安装完成后可用 `dsh-web` 启动；`dsh-installer` 已注册为命令（新开终端生效）。

## 命令参考

以 macOS/Linux 为例，Windows 把 `./install.sh` 换成 `install.ps1` 即可，参数完全一致。

### install — 安装

```
./install.sh install [选项]
```

| 选项 | 说明 |
| --- | --- |
| `-m, --mode npx\|source` | 安装方式（默认交互选择；非交互默认 npx） |
| `-d, --dir <路径>` | 源码模式安装目录（默认 `~/deepseek-harness`） |
| `-p, --port <端口>` | Web UI 端口（默认 3080） |
| `-H, --host <地址>` | 绑定地址（默认 127.0.0.1） |
| `--registry <URL>` | npm 镜像，如 `https://registry.npmmirror.com` |
| `--clone-url <URL>` | git 克隆地址（可用镜像替代官方 GitHub 仓库） |
| `--api-key <密钥>` | 写入 `DEEPSEEK_API_KEY` 到 `~/.dsh/.env` |
| `--node-version <主版本>` | 自动安装的 Node 主版本（默认 24） |
| `--no-start` | 安装后不启动 |
| `-y, --yes` / `-q, --quiet` | 非交互 / 静默 |

### 服务管理

```sh
./install.sh start          # 后台启动 Web UI
./install.sh stop           # 停止（未运行时退出码 2）
./install.sh restart        # 重启
./install.sh status         # 状态；加 --json 输出机器可读结果
./install.sh logs -n 50     # 查看日志；-f 持续输出
./install.sh open           # 在浏览器打开 Web UI
```

### 插件管理（profile 默认为 web）

```sh
# 安装：npm 包名 / github 仓库 / 本地路径 / tarball 均可
./install.sh plugin add some-dsh-plugin -y
./install.sh plugin add github:someone/awesome-dsh-plugin -y
./install.sh plugin add ./my-local-plugin -y
./install.sh plugin add ./my-plugin-0.1.0.tgz -y

# 移除 / 更新 / 列表 / 搜索
./install.sh plugin remove some-dsh-plugin -y
./install.sh plugin update -y
./install.sh plugin list            # 或 plugin list --json
./install.sh plugin search 关键词    # 或 plugin search 关键词 --json
```

插件装到 profile（`~/.dsh/profiles/web`），安装或移除后需重启 Web UI 生效：

```sh
./install.sh restart -y
```

### 更新 / 卸载

```sh
./install.sh update -y              # npx 模式清缓存（下次启动即最新）；源码模式 git pull + 重建
./install.sh uninstall -y           # 卸载本体（保留 ~/.dsh 数据）
./install.sh uninstall -y --purge   # 连同 ~/.dsh（会话/配置/插件）全部删除
./install.sh remove-external        # 扫描并清理外部安装（独立危险操作；必须人工二次确认）
./install.sh uninstall -y --remove-external --dir ~/my-fork/deepseek-harness  # 组合使用；仍必须人工二次确认
```

**卸载采用所有权隔离模型，默认不扫、不猜、不扩大范围：**

| 层级 | 内容 | 触发方式 |
| --- | --- | --- |
| ① 本工具管理的资源 | 带本安装器归属标记的源码目录（脏仓库二次确认）、启动器、CLI 链接、带归属标记的可选 Skill、本工具安装的 Node、仅 DSH 自身的 npx 缓存条目 | `uninstall`（默认） |
| ② 数据目录 | `~/.dsh`（会话/配置/插件） | `uninstall --purge`（二次确认，仅限名为 .dsh 的目录） |
| ③ 外部安装 | `npm install -g`、`pnpm add -g`、`yarn global add`、nvm/fnm/volta 各版本全局装、常见位置的源码仓库 | `remove-external`（先展示清单，**无论是否带 `-y` 都必须人工二次确认**；源码仓库仅当官方 origin、无未提交改动且无仅本地提交时才删除；shim 只删能证明指向 `@deepseek-ai/dsh` 的） |

说明：npx 模式本身无驻留安装，`npx @deepseek-ai/dsh web` 随时可以重新下载运行——默认卸载的意义在于清除 DSH 自己的缓存条目、启动器和带归属标记的可选 Skill；数据目录仅在明确指定 `--purge` 后才会处理。

### 参数约束与安全

- `--host` 仅接受 `127.0.0.1` 或 `0.0.0.0`；选 `0.0.0.0` 会强弹警告（Web UI 当前无 TLS/认证，暴露到局域网有风险）。
- `--port` 仅接受 1-65535（不接受 0）。
- `--registry` / `--clone-url` 会被校验；shell 版不再把这些值或插件参数拼接进 `sh -c`。
- 进程管理带身份校验：PID 文件记录 PID、启动时间和命令行特征。旧版本仅含 PID 的记录只用于诊断，绝不会被当成可停止的本工具进程；端口探测只用于「被占用」提示，不作为身份认证。
- `npx` 的缓存目录是共享目录；更新和默认卸载只清理确认含 `@deepseek-ai/dsh` 的缓存条目，不会删除整个 `_npx` 缓存。

### 其他

```sh
./install.sh info --json            # 环境与安装信息（机器可读）
./install.sh skill                  # 手动注册可选实验性 Skill（未经完整测试）
./install.sh version
```

## 可选：让 dsh 参考本安装器 Skill

安装器默认**不会**注册、注入或自动启用 Skill。若你明确希望 dsh 参考这个实验性辅助说明，才手动执行：

```sh
./install.sh skill
# Windows: powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 skill
```

这项 Skill **未经完整测试**，只提供命令参考，不会授权自动安装、更新、停止服务、变更插件或删除任何数据。尤其是：它不能默认追加 `-y`，也不能默认使用 `--purge` 或 `--remove-external`。其余运行时契约如下：

- **非交互**：stdin 不是 TTY 时全部按默认值继续（安装类默认是），`-y` 显式强制；
- **机器可读**：`status --json` / `info --json` / `plugin list --json` / `plugin search --json` 输出 JSON；
- **退出码**：0 成功、1 错误、2 服务未运行；
- **幂等与归属**：重复 `install` / `start` / `skill` 不会扩大删除范围；默认卸载仅处理带本安装器归属标记的资源。

也可在充分知情的前提下手动复制 `skills/dsh-installer/SKILL.md` 到 `~/.dsh/skills/dsh-installer/SKILL.md` 完成注册；手动复制的目录没有本安装器归属标记，默认卸载会保留它。

## 目录布局

| 位置 | 内容 |
| --- | --- |
| `~/.dsh` | DSH 数据目录：profiles（含 web 插件）、会话、设置、技能（`DSH_HOME` 可覆盖） |
| `~/.dsh/.env` | `DEEPSEEK_API_KEY` 等凭据（安装器 `--api-key` 写入处） |
| `~/.config/dsh-installer`（macOS/Linux）/ `%LOCALAPPDATA%\dsh-installer`（Windows） | 安装器配置、pid、日志 |
| `~/.local/share/dsh-installer/node`（macOS/Linux） | 安装器自动安装的 Node（有标记文件，卸载时随之删除） |
| `~/deepseek-harness` | 源码模式的仓库（默认位置） |

## 常见问题

**Q: Node 版本要求？**
需要 `^22.19.0` 或 `>=24.0.0`（与官方仓库 engines 一致）。不满足时安装器自动下载官方二进制到用户目录，不动系统 Node。

**Q: 提示端口被占用？**
`./install.sh install -y --port 8080` 换端口；旧实例用 `./install.sh stop` 停止。

**Q: 国内下载慢 / 失败？**
加 `--registry https://registry.npmmirror.com`；源码模式再加 `--clone-url` 指向镜像。

**Q: 卸载会误删其他文件吗？**
默认流程不会扩大到未经证明归属的资源。`uninstall` 只清理带本安装器归属标记的源码目录、Skill、本工具安装的 Node、启动器和 DSH 自己的 npx 缓存条目；`--purge` 仅允许删除名为 `.dsh` 的数据目录且需二次确认；外部安装必须显式 `remove-external`，先展示清单，且即使带 `-y` 也必须人工二次确认。

**Q: 能卸载不是用本安装器装的 dsh 吗？**
可以，但默认**不会碰**。用 `remove-external`（或 `uninstall --remove-external`）先展示候选清单；它必须从真实交互终端输入 `y/yes`，`-y` 不能绕过该确认。确认后才执行 `npm uninstall -g`、`pnpm uninstall -g`、`yarn global remove` 并清理扫描到的包；源码仓库还必须同时满足官方 origin、无未提交改动、无仅本地提交，`--dir` 只能额外提供候选目录，不能跳过这些条件。

**Q: 卸载后 npx @deepseek-ai/dsh web 还能启动？**
能，这是 npx 的特性：npx 模式没有驻留安装，任何时候运行都会重新下载。卸载只清除 DSH 自己的 npx 缓存条目、启动器、带归属标记的可选 Skill 与（`--purge` 时）数据目录；源码模式也只会删除带本安装器归属标记的仓库。

**Q: macOS 双击 / 新终端找不到命令？**
把 `~/.local/bin` 加入 PATH（见快速开始）；Windows 用户 PATH 已在安装时写入，新开终端生效。

**Q: pnpm 版本？**
官方仓库锁定 pnpm 11.7.0；安装器按此版本安装，已有其他版本亦可使用。

## 免责声明

本工具是独立第三方便利脚本，与 DeepSeek Harness 官方项目无隶属关系；安装、升级行为最终以 [官方仓库](https://github.com/deepseek-ai/deepseek-harness) 为准。开发者预览期接口变动频繁，若 dsh 命令行为变化导致安装器失配，欢迎反馈。

## 鸣谢
[LINUX DO](https://linux.do/)提供的交流社区
