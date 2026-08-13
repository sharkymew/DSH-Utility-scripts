# DeepSeek Harness 多平台实用脚本

一套面向 **macOS / Linux / Windows** 的 DeepSeek Harness（`dsh`）安装与管理工具，支持两种官方安装方式，并附带服务管理、插件安装/卸载、更新、dsh 技能集成等实用功能。

> DeepSeek Harness 目前处于开发者预览阶段，兼容性破坏性变更随时可能发生。

## 特性

- **两种官方安装方式**，一台机器一键切换：
  1. **npx 快捷模式** — `npx --yes @deepseek-ai/dsh web`，启动快、每次启动自动使用最新发布版；
  2. **源码模式** — `git clone https://github.com/deepseek-ai/deepseek-harness.git` + `pnpm install` + `pnpm run build`，适合读改源码；检测到已有仓库时自动复用并 `git pull`。
- **服务管理**：后台启动 / 停止 / 重启 / 状态 / 日志 / 浏览器打开，Web UI 默认 http://127.0.0.1:3080。
- **插件管理**：安装、移除、更新、列表、搜索 dsh 插件（底层转发 `dsh plugin --profile web`，支持 npm 包名、`github:用户/仓库`、本地路径、tarball）。
- **依赖自动处理**：Node.js（要求 ^22.19.0 或 >=24.0.0）、pnpm、git 缺失时自动安装到用户目录，**全程无需 sudo / 管理员权限**。
- **可被 dsh 直接调用**：无 TTY 自动非交互、`-y` 强制非交互、`--json` 机器可读输出、稳定退出码（0=成功 1=错误 2=未运行）；安装时自动把自身注册为 dsh 技能（`~/.dsh/skills/dsh-installer/SKILL.md`），dsh 的 agent 可以直接用本安装器装插件。
- **国内网络友好**：`--registry` 指定 npm 镜像、`--clone-url` 指定 git 镜像；`--api-key` 一键写入 `~/.dsh/.env`。
- **安全卸载**：卸载前多重守卫（目录归属校验、交互确认），`--purge` 可连 `~/.dsh` 数据目录一并清除。

## 文件

| 文件 | 说明 |
| --- | --- |
| `install.sh` | macOS / Linux 安装器（bash 3.2+，单文件可分发） |
| `install.ps1` | Windows 安装器（PowerShell 5.1+，UTF-8 BOM） |
| `install.bat` | Windows 双击入口（自动绕过执行策略） |
| `skills/dsh-installer/SKILL.md` | dsh 技能文件（也可手动复制到 `~/.dsh/skills/dsh-installer/`） |
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

安装完成后会创建 `~/.local/bin/dsh-web`（前台启动）与 `~/.local/bin/dsh-installer`（本工具命令入口）。若 `~/.local/bin` 不在 PATH 中，请执行：

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
| `-m, --mode npx|source` | 安装方式（默认交互选择；非交互默认 npx） |
| `-d, --dir <路径>` | 源码模式安装目录（默认 `~/deepseek-harness`） |
| `-p, --port <端口>` | Web UI 端口（默认 3080） |
| `-H, --host <地址>` | 绑定地址（默认 127.0.0.1） |
| `--registry <URL>` | npm 镜像，如 `https://registry.npmmirror.com` |
| `--clone-url <URL>` | git 克隆地址（可用镜像替代官方 GitHub 仓库） |
| `--api-key <密钥>` | 写入 `DEEPSEEK_API_KEY` 到 `~/.dsh/.env` |
| `--node-version <主版本>` | 自动安装的 Node 主版本（默认 24） |
| `--no-start` | 安装后不启动 |
| `--no-skill` | 不注册 dsh 技能 |
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
./install.sh remove-external        # 扫描并清理外部安装（独立危险操作）
./install.sh uninstall -y --remove-external --dir ~/my-fork/deepseek-harness  # 组合使用
```

**卸载采用所有权隔离模型，默认不扫、不猜、不扩大范围：**

| 层级 | 内容 | 触发方式 |
| --- | --- | --- |
| ① 本工具管理的资源 | 配置登记的源码目录（脏仓库二次确认）、启动器、CLI 链接、dsh 技能、本工具安装的 Node、npx 缓存 | `uninstall`（默认） |
| ② 数据目录 | `~/.dsh`（会话/配置/插件） | `uninstall --purge`（二次确认，仅限名为 .dsh 的目录） |
| ③ 外部安装 | `npm install -g`、`pnpm add -g`、`yarn global add`、nvm/fnm/volta 各版本全局装、任意位置的源码仓库 | `remove-external`（先展示清单，**默认取消**；脏仓库一律拒绝；shim 只删能证明指向 `@deepseek-ai/dsh` 的） |

说明：npx 模式本身无驻留安装，`npx @deepseek-ai/dsh web` 随时可以重新下载运行——卸载的意义在于清除缓存、启动器、技能与数据目录。

### 参数约束与安全

- `--host` 仅接受 `127.0.0.1` 或 `0.0.0.0`；选 `0.0.0.0` 会强弹警告（Web UI 当前无 TLS/认证，暴露到局域网有风险）。
- `--port` 仅接受 1-65535（不接受 0）。
- `--registry` / `--clone-url` 拒绝空白、引号与命令注入字符。
- 进程管理带身份校验：PID 文件记录进程启动时间与命令行特征，停止前校验，防止 PID 复用误杀；端口探测只用于「被占用」提示，不作为身份认证。

### 其他

```sh
./install.sh info --json            # 环境与安装信息（机器可读）
./install.sh skill                  # 手动注册 dsh 技能
./install.sh version
```

## 让 dsh 直接调用本安装器

安装时默认自动注册技能到 `~/.dsh/skills/dsh-installer/SKILL.md`。此后在 dsh 会话中对 agent 说「安装插件 xxx」即可触发调用。为 agent 设计的关键契约：

- **非交互**：stdin 不是 TTY 时全部按默认值继续（安装类默认是），`-y` 显式强制；
- **机器可读**：`status --json` / `info --json` / `plugin list --json` / `plugin search --json` 输出 JSON；
- **退出码**：0 成功、1 错误、2 服务未运行；
- **幂等**：重复 install/start/skill 安全无副作用。

也可手动复制 `skills/dsh-installer/SKILL.md` 到 `~/.dsh/skills/dsh-installer/SKILL.md` 完成注册。

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
不会。默认 `uninstall` 只清理本工具确认拥有的资源（配置登记的源码目录、启动器、技能、本工具安装的 Node、npx 缓存）；`--purge` 仅允许删除名为 `.dsh` 的数据目录且需二次确认；外部安装必须显式 `remove-external`，先展示清单默认取消，脏仓库一律跳过。

**Q: 能卸载不是用本安装器装的 dsh 吗？**
能，但默认**不会碰**。用 `remove-external`（或 `uninstall --remove-external`）先展示全部候选清单，**默认取消**，确认后才依次执行 `npm uninstall -g`、`pnpm uninstall -g`、`yarn global remove` 并删除扫描到的包与仓库（有未提交改动的仓库一律跳过；`--dir` 可额外指定仓库）。

**Q: 卸载后 npx @deepseek-ai/dsh web 还能启动？**
能，这是 npx 的特性：npx 模式没有驻留安装，任何时候运行都会重新下载。卸载已清除本地缓存、启动器、技能与（`--purge` 时）数据目录；若需彻底禁止，用源码模式安装，卸载会删除整个仓库。

**Q: macOS 双击 / 新终端找不到命令？**
把 `~/.local/bin` 加入 PATH（见快速开始）；Windows 用户 PATH 已在安装时写入，新开终端生效。

**Q: pnpm 版本？**
官方仓库锁定 pnpm 11.7.0；安装器按此版本安装，已有其他版本亦可使用。

## 免责声明

本工具是独立第三方便利脚本，与 DeepSeek Harness 官方项目无隶属关系；安装、升级行为最终以 [官方仓库](https://github.com/deepseek-ai/deepseek-harness) 为准。开发者预览期接口变动频繁，若 dsh 命令行为变化导致安装器失配，欢迎反馈。
