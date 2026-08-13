---
name: dsh-installer
description: DeepSeek Harness 安装、服务与插件管理工具。当用户要求安装/更新/卸载 DeepSeek Harness，安装/移除/搜索 dsh 插件，或启动/停止/查看 Web UI 服务时使用。
---

# DeepSeek Harness 安装器（dsh-installer）

通过 dsh-installer 命令管理 DeepSeek Harness 本体与插件。所有命令必须非交互（加 -y），机器结果用 --json。

## 定位安装器
优先执行 **command -v dsh-installer**（Linux/macOS）或 **dsh-installer.cmd**（Windows）；否则依次尝试 **~/.local/bin/dsh-installer**、**bash ~/DSH-installer/install.sh**。

## 命令速查
- 安装: **dsh-installer install -y --mode npx|source --port 3080**
- 状态: **dsh-installer status --json**（读 running 字段）
- 启动/停止/重启: **dsh-installer start|stop|restart -y**
- 插件安装: **dsh-installer plugin add 包名 或 github:用户/仓库 或 ./路径 或 .tgz -y**
- 插件移除: **dsh-installer plugin remove 包名 -y**
- 插件列表: **dsh-installer plugin list --json**
- 插件搜索: **dsh-installer plugin search 关键词 --json**
- 更新: **dsh-installer update -y**
- 卸载: **dsh-installer uninstall -y --purge**

## 规则
1. 每条命令都带 -y；失败先看日志 **dsh-installer logs -n 30** 再决定重试。
2. 安装/移除插件后需要重启 Web UI 才生效：**dsh-installer restart -y**。
3. 要求 Node.js >= 22.19 或 >= 24；缺失时安装器自动装到用户目录（无需 sudo/管理员）。
4. 国内网络失败时加 **--registry https://registry.npmmirror.com** 重试。
