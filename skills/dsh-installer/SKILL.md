---
name: dsh-installer
description: 可选的实验性 DeepSeek Harness 安装、服务与插件管理提示。未经完整测试；仅在用户明确要求使用 dsh-installer 时参考，任何删除操作均须再次取得明确同意。
---

# DeepSeek Harness 安装器（可选实验性 Skill）

> 本 Skill 是可选功能，未经完整测试，安装器默认不会注册它。它不是“自动注入”或“默认执行”规则；只有用户明确要求使用 dsh-installer 时才可参考。

通过 dsh-installer 命令管理 DeepSeek Harness 本体与插件。查询状态可使用 `--json`；涉及安装、更新、启动、停止、插件变更和卸载前，先向用户说明将执行的操作，得到明确同意后再执行。

## 定位安装器
优先执行 **command -v dsh-installer**（Linux/macOS）或 **dsh-installer.cmd**（Windows）；否则依次尝试 **~/.local/bin/dsh-installer**、**bash ~/DSH-installer/install.sh**。

## 非破坏性命令速查
- 状态: **dsh-installer status --json**（读 running 字段）
- 插件列表: **dsh-installer plugin list --json**
- 插件搜索: **dsh-installer plugin search 关键词 --json**

## 规则
1. 不要为了自动化而默认追加 `-y`；只有用户明确希望非交互执行时才加。
2. `uninstall` 默认保留已登记的 `DSH_HOME` 数据。可先用 `uninstall --purge --dry-run` 预览。绝不默认加入 `--purge`、`--purge-temp` 或 `--remove-external`；这些选项会删除数据或其他安装，必须单独、再次获得用户确认。
3. 安装/移除插件后可能需要重启 Web UI 才生效。先说明影响，再按用户指示执行。
4. 要求 Node.js >= 22.19 或 >=24；缺失时安装器可能安装到用户目录。国内网络失败时可由用户选择 `--registry https://registry.npmmirror.com`。
5. 失败先查看 **dsh-installer logs -n 30**，不要通过扩大删除范围或放松 pnpm 安全闸门来“修复”。
