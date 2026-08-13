#!/usr/bin/env bash
# ============================================================================
#  DeepSeek Harness 多平台安装器 (macOS / Linux)
#
#  用法: ./install.sh [命令] [选项]
#
#  命令:
#    menu         进入交互菜单（无参数直接运行时自动进入）
#    install      安装 DeepSeek Harness（默认命令）
#    start        后台启动 Web UI
#    stop         停止 Web UI
#    restart      重启 Web UI
#    status       查看运行状态（支持 --json）
#    logs         查看运行日志（-f 持续输出，-n 行数）
#    update       更新 DSH（源码模式）/ 刷新 npx 缓存（npx 模式）
#    plugin       插件管理: add | remove | update | list | search
#    info         查看环境与安装信息（支持 --json）
#    open         在浏览器打开 Web UI
#    skill        把本安装器注册为 dsh 技能（dsh 可直接调用本工具装插件）
#    uninstall    卸载（--purge 同时删除 ~/.dsh 数据目录）
#    version      显示版本号
#
#  设计目标: 无 TTY 时自动非交互（可被 dsh/CI 直接调用），--json 输出机器
#  可读结果，稳定退出码: 0=成功 1=错误 2=服务未运行/未安装。
#
#  安装方式:
#    1) npx 快捷模式:  npx --yes @deepseek-ai/dsh web
#    2) 源码模式:      git clone https://github.com/deepseek-ai/deepseek-harness.git
#                      + pnpm install + pnpm run build + pnpm dsh web
# ============================================================================
set -uo pipefail

APP_NAME="dsh-installer"
APP_VERSION="1.2.0"
NPX_PKG="@deepseek-ai/dsh"
GITHUB_REPO="https://github.com/deepseek-ai/deepseek-harness.git"
DEFAULT_NODE_MAJOR="24"
PNPM_VERSION="11.7.0"
WEB_PROFILE="web"
DEFAULT_HOST="127.0.0.1"
DEFAULT_PORT="3080"

# ---------------------------------------------------------------- 目录布局
HOME_DIR="${HOME:?}"
CFG_DIR="${XDG_CONFIG_HOME:-$HOME_DIR/.config}/dsh-installer"
DATA_DIR="${XDG_DATA_HOME:-$HOME_DIR/.local/share}/dsh-installer"
BIN_DIR="${XDG_BIN_HOME:-$HOME_DIR/.local/bin}"
CONFIG_FILE="$CFG_DIR/config"
PID_FILE="$CFG_DIR/web.pid"
LOG_FILE="$CFG_DIR/web.log"
RUN_SCRIPT="$CFG_DIR/run-web.sh"
LAUNCHER="$BIN_DIR/dsh-web"
CLI_LINK="$BIN_DIR/dsh-installer"
NODE_DIR="$DATA_DIR/node"
DSH_HOME_DIR="${DSH_HOME:-$HOME_DIR/.dsh}"
SKILL_DIR="$DSH_HOME_DIR/skills/dsh-installer"

# ---------------------------------------------------------------- 运行时变量
OS="" ARCH="" MODE="" INSTALL_DIR="$HOME_DIR/deepseek-harness"
HOST="$DEFAULT_HOST" PORT="$DEFAULT_PORT"
REGISTRY="" API_KEY="" YES=0 NO_START=0 QUIET=0 JSON_OUT=0
NODE_MAJOR="$DEFAULT_NODE_MAJOR" CLONE_URL="" NO_SKILL=0

# 解析脚本真实路径（支持符号链接，兼容 macOS 无 readlink -f）
SCRIPT_PATH="$0"
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if [ -L "$SCRIPT_PATH" ]; then
    LINK_TARGET="$(readlink "$SCRIPT_PATH")"
    case "$LINK_TARGET" in
      /*) SCRIPT_PATH="$LINK_TARGET" ;;
      *)  SCRIPT_PATH="$(cd "$(dirname "$SCRIPT_PATH")" 2>/dev/null && pwd)/$LINK_TARGET" ;;
    esac
  else
    break
  fi
done
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" 2>/dev/null && pwd)"
case "$SCRIPT_PATH" in
  /*) : ;;
  *) SCRIPT_PATH="$SCRIPT_DIR/$SCRIPT_PATH" ;;
esac

# ---------------------------------------------------------------- 颜色与日志
if [ -t 1 ]; then
  C_RED='\033[31m'; C_GREEN='\033[32m'; C_YELLOW='\033[33m'
  C_BLUE='\033[34m'; C_CYAN='\033[36m'; C_BOLD='\033[1m'; C_RESET='\033[0m'
else
  C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_CYAN=''; C_BOLD=''; C_RESET=''
fi

info()  { [ "$QUIET" = "1" ] || printf '%s\n' "${C_CYAN}[信息]${C_RESET} $*"; }
ok()    { [ "$QUIET" = "1" ] || printf '%s\n' "${C_GREEN}[完成]${C_RESET} $*"; }
warn()  { printf '%s\n' "${C_YELLOW}[警告]${C_RESET} $*" >&2; }
err()   { printf '%s\n' "${C_RED}[错误]${C_RESET} $*" >&2; }
step()  { [ "$QUIET" = "1" ] || printf '%s\n' "${C_BOLD}==> $*${C_RESET}"; }
die()   { err "$@"; exit 1; }

# ---------------------------------------------------------------- 基础工具
confirm() {
  # confirm <提示> [默认 y|n]；非交互时按默认值决定
  local msg="$1" def="${2:-y}"
  [ "$YES" = "1" ] && return 0
  if [ ! -t 0 ]; then
    [ "$def" = "y" ] && return 0 || return 1
  fi
  local hint="Y/n"; [ "$def" = "n" ] && hint="y/N"
  printf '%s' "${C_BOLD}$msg [$hint]: ${C_RESET}"
  local ans=""
  read -r ans || ans=""
  case "$ans" in
    y|Y|yes|YES) return 0 ;;
    n|N|no|NO) return 1 ;;
    "") [ "$def" = "y" ] && return 0 || return 1 ;;
    *) return 1 ;;
  esac
}

json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# 把字符串安全地放进双引号（用于生成脚本中的 cd 等）
shell_quote() { printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\$/\\$/g')"; }

# ---------------------------------------------------------------- 平台检测
detect_platform() {
  case "$(uname -s)" in
    Darwin) OS="macos" ;;
    Linux)  OS="linux" ;;
    *) die "暂不支持的操作系统: $(uname -s)" ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64) ARCH="x64" ;;
    arm64|aarch64) ARCH="arm64" ;;
    *) die "暂不支持的 CPU 架构: $(uname -m)" ;;
  esac
}

# ---------------------------------------------------------------- 配置存取
load_config() {
  [ -f "$CONFIG_FILE" ] || return 0
  # shellcheck disable=SC1090
  . "$CONFIG_FILE"
}

save_config() {
  mkdir -p "$CFG_DIR"
  umask 077
  {
    echo "MODE=${MODE:-"npx"}"
    echo "INSTALL_DIR=${INSTALL_DIR:-$HOME_DIR/deepseek-harness}"
    echo "HOST=${HOST:-$DEFAULT_HOST}"
    echo "PORT=${PORT:-$DEFAULT_PORT}"
    [ -n "$REGISTRY" ] && echo "REGISTRY=$REGISTRY"
    echo "NODE_MAJOR=${NODE_MAJOR:-$DEFAULT_NODE_MAJOR}"
  } > "$CONFIG_FILE"
}

# ---------------------------------------------------------------- 版本工具
node_version() { node -v 2>/dev/null | tr -d 'v'; }

node_is_ok() {
  command -v node >/dev/null 2>&1 || return 1
  local v mm major minor
  v="$(node_version)" || return 1
  mm="$(printf '%s' "$v" | awk -F. '{print $1"."$2}')" || return 1
  major="${mm%%.*}"; minor="${mm##*.}"
  case "$major" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$major" -ge 24 ] && return 0
  { [ "$major" -eq 22 ] && [ "$minor" -ge 19 ]; } && return 0
  return 1
}

# ---------------------------------------------------------------- Node 安装
node_latest_version() {
  curl -fsSL "https://nodejs.org/dist/latest-v$NODE_MAJOR.x/" 2>/dev/null \
    | grep -o "node-v$NODE_MAJOR\.[0-9.]*" | head -1 | sed 's/^node-v//'
}

install_node_local() {
  step "安装 Node.js v${NODE_MAJOR}（用户级，无需 sudo）"
  command -v curl >/dev/null 2>&1 || die "需要 curl 下载 Node.js，请先安装 curl"
  local latest="" file="" ext="" url="" tmp=""
  latest="$(node_latest_version)"
  [ -n "$latest" ] || die "无法获取 Node.js 版本列表（检查网络）"
  if [ "$OS" = "macos" ]; then
    file="node-v$latest-darwin-$ARCH.tar.gz"; ext="tar.gz"
  else
    file="node-v$latest-linux-$ARCH.tar.xz"; ext="tar.xz"
  fi
  url="https://nodejs.org/dist/v$latest/$file"
  info "下载 $url"
  tmp="$(mktemp -d)" || die "创建临时目录失败"
  curl -fL --retry 3 --connect-timeout 15 -o "$tmp/$file" "$url" || die "下载 Node.js 失败"
  mkdir -p "$DATA_DIR"
  rm -rf "$NODE_DIR"
  if [ "$ext" = "tar.xz" ]; then tar -xJf "$tmp/$file" -C "$tmp"; else tar -xzf "$tmp/$file" -C "$tmp"; fi
  mv "$tmp/node-v$latest-"* "$NODE_DIR"
  rm -rf "$tmp"
  touch "$NODE_DIR/.installed-by-dsh-installer"
  mkdir -p "$BIN_DIR"
  for b in node npm npx corepack; do
    ln -sf "$NODE_DIR/bin/$b" "$BIN_DIR/$b"
  done
  export PATH="$BIN_DIR:$PATH"
  ok "Node.js v$latest 已安装到 $NODE_DIR"
  if ! printf '%s' ":$PATH:" | grep -q ":$BIN_DIR:"; then
    warn "请将 $BIN_DIR 加入 PATH:"
    warn "  export PATH=\"$BIN_DIR:\$PATH\""
    if confirm "自动写入 ~/.bashrc 与 ~/.zshrc？" "y"; then
      for rc in "$HOME_DIR/.bashrc" "$HOME_DIR/.zshrc"; do
        if ! grep -q "# dsh-installer PATH" "$rc" 2>/dev/null; then
          printf '\n# dsh-installer PATH\nexport PATH="%s:$PATH"\n' "$BIN_DIR" >> "$rc" 2>/dev/null || true
        fi
      done
      ok "已写入，重开终端后生效"
    fi
  fi
}

ensure_node() {
  if node_is_ok; then
    info "Node.js v$(node_version) 已满足要求（>=22.19 或 >=24）"
    return 0
  fi
  if command -v node >/dev/null 2>&1; then
    warn "当前 Node.js v$(node_version) 不满足要求（需要 ^22.19.0 或 >=24.0.0）"
  else
    warn "未检测到 Node.js"
  fi
  if confirm "是否自动安装 Node.js v$NODE_MAJOR 到用户目录？" "y"; then
    install_node_local
  else
    die "请先手动安装 Node.js >= 24（或 22.19+）: https://nodejs.org/"
  fi
  node_is_ok || die "Node.js 安装后仍不可用"
}

# ---------------------------------------------------------------- pnpm / git
ensure_pnpm() {
  if command -v pnpm >/dev/null 2>&1; then
    info "pnpm v$(pnpm --version 2>/dev/null) 已就绪"
    return 0
  fi
  info "安装 pnpm@$PNPM_VERSION ..."
  if npm install -g "pnpm@$PNPM_VERSION" >/dev/null 2>&1; then
    hash -r 2>/dev/null || true
    command -v pnpm >/dev/null 2>&1 && { ok "pnpm 安装完成"; return 0; }
  fi
  warn "npm 全局安装失败，尝试 corepack ..."
  corepack enable >/dev/null 2>&1 || true
  corepack prepare "pnpm@$PNPM_VERSION" --activate >/dev/null 2>&1 || true
  hash -r 2>/dev/null || true
  if command -v pnpm >/dev/null 2>&1; then ok "pnpm 安装完成"; return 0; fi
  warn "pnpm 安装失败：插件管理功能将不可用"
  warn "可手动执行: npm install -g pnpm@$PNPM_VERSION"
  return 1
}

ensure_git() {
  command -v git >/dev/null 2>&1 && return 0
  warn "未检测到 git（源码安装需要）"
  if [ "$OS" = "macos" ]; then
    if command -v brew >/dev/null 2>&1; then
      confirm "通过 Homebrew 安装 git？" "y" && brew install git && return 0
    else
      warn "请执行: xcode-select --install  或安装 Homebrew 后 brew install git"
    fi
  else
    if [ "$(id -u)" = "0" ] && command -v apt-get >/dev/null 2>&1; then
      apt-get install -y git && return 0
    fi
    warn "请用系统包管理器安装 git，例如: sudo apt install git / sudo dnf install git"
  fi
  die "git 不可用，无法进行源码安装"
}

# ---------------------------------------------------------------- 参数校验
validate_config() {
  case "$HOST" in
    127.0.0.1|0.0.0.0) ;;
    *) die "无效 host: ${HOST}（仅支持 127.0.0.1 或 0.0.0.0）" ;;
  esac
  case "$PORT" in
    ''|*[!0-9]*) die "无效端口: $PORT" ;;
  esac
  if [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
    die "端口需在 1-65535 之间（不接受 0）"
  fi
  if [ -n "$REGISTRY" ]; then
    case "$REGISTRY" in
      http://*|https://*) ;;
      *) die "无效 registry: 需以 http:// 或 https:// 开头" ;;
    esac
    if printf '%s' "$REGISTRY" | grep -qE '[[:space:]"&|<>^`]'; then
      die "registry 含非法字符"
    fi
  fi
  if [ -n "$CLONE_URL" ] && printf '%s' "$CLONE_URL" | grep -qE '[[:space:]"]'; then
    die "clone-url 含非法字符"
  fi
  if [ "$HOST" = "0.0.0.0" ]; then
    confirm "警告：绑定 0.0.0.0 会把 Web UI 暴露到局域网（当前无 TLS/认证）。仍要继续？" "n" \
      || die "已取消（改用默认 127.0.0.1 即可）"
  fi
}

# ---------------------------------------------------------------- 运行命令构造
reg_prefix() {
  [ -n "$REGISTRY" ] && printf 'env npm_config_registry=%s ' "$REGISTRY" || true
}

# 以 npm 实际配置的缓存目录为准（用户可能自定义过 cache 路径）
npx_cache_dir() {
  local c=""
  if command -v npm >/dev/null 2>&1; then
    c="$(npm config get cache 2>/dev/null | tail -1)"
  fi
  [ -n "$c" ] && printf '%s' "$c" || printf '%s' "$HOME_DIR/.npm"
}

# npm 原生卸载 + 清 npx 缓存（npx 缓存包无专用卸载命令，官方做法即删 _npx 目录）
npm_uninstall_dsh() {
  if command -v npm >/dev/null 2>&1; then
    npm uninstall -g "$NPX_PKG" >/dev/null 2>&1 || true
  fi
  rm -rf "$(npx_cache_dir)/_npx"
}

# 纯只读扫描：其他方式安装的 dsh 全局包（npm/pnpm 全局、nvm/fnm/volta 各 Node 版本）
# 输出格式: global:<路径>  —— 不做任何删除动作
scan_external_pkgs() {
  local root="" d="" p=""
  if command -v npm >/dev/null 2>&1; then
    root="$(npm root -g 2>/dev/null | tail -1)"
    [ -n "$root" ] && [ -d "$root/@deepseek-ai/dsh" ] && echo "global:$root/@deepseek-ai/dsh"
  fi
  if command -v pnpm >/dev/null 2>&1; then
    root="$(pnpm root -g 2>/dev/null | tail -1)"
    [ -n "$root" ] && [ -d "$root/@deepseek-ai/dsh" ] && echo "global:$root/@deepseek-ai/dsh"
  fi
  for base in \
    "$HOME_DIR/.nvm/versions/node" \
    "$HOME_DIR/.volta/tools/image/node" \
    "${XDG_DATA_HOME:-$HOME_DIR/.local/share}/fnm/node-versions" \
    "$HOME_DIR/.local/share/fnm/node-versions" \
    "$HOME_DIR/Library/Application Support/fnm/node-versions"; do
    [ -d "$base" ] || continue
    for d in "$base"/*/; do
      [ -d "$d" ] || continue
      for p in "$d/lib/node_modules/@deepseek-ai/dsh" "$d/installation/lib/node_modules/@deepseek-ai/dsh"; do
        [ -d "$p" ] && echo "global:$p"
      done
    done
  done
}

# 纯只读扫描：常见位置的源码仓库。输出格式: repo:<路径>
scan_source_repos() {
  local base="" candidate=""
  for base in "$HOME_DIR" "$HOME_DIR/Dev" "$HOME_DIR/dev" "$HOME_DIR/Development" "$HOME_DIR/development" \
      "$HOME_DIR/projects" "$HOME_DIR/code" "$HOME_DIR/git" "$HOME_DIR/repos" \
      "$HOME_DIR/source" "$HOME_DIR/src" "$HOME_DIR/workspace" \
      "$HOME_DIR/Desktop" "$HOME_DIR/Documents" "$HOME_DIR/Downloads"; do
    candidate="$base/deepseek-harness"
    [ -d "$candidate/.git" ] && repo_marker "$candidate" && echo "repo:$candidate"
  done
}

# 删除归属明确的 dsh shim（symlink 指向或文件内容包含 @deepseek-ai/dsh 才算归属）
cleanup_owned_shims() {
  local d="" shim="" target=""
  for base in \
    "$HOME_DIR/.nvm/versions/node" \
    "$HOME_DIR/.volta/tools/image/node" \
    "${XDG_DATA_HOME:-$HOME_DIR/.local/share}/fnm/node-versions" \
    "$HOME_DIR/.local/share/fnm/node-versions" \
    "$HOME_DIR/Library/Application Support/fnm/node-versions"; do
    [ -d "$base" ] || continue
    for d in "$base"/*/; do
      [ -d "$d" ] || continue
      for shim in dsh dsh.cmd dsh.ps1 dsh-pwsh; do
        for target in "$d/bin/$shim" "$d/installation/bin/$shim"; do
          [ -e "$target" ] || continue
          if [ -L "$target" ]; then
            readlink "$target" 2>/dev/null | grep -q '@deepseek-ai/dsh' && rm -f "$target"
          elif [ -f "$target" ] && grep -q '@deepseek-ai/dsh' "$target" 2>/dev/null; then
            rm -f "$target"
          fi
        done
      done
    done
  done
}

# 统一执行 dsh 命令（自动选择 npx / 源码运行方式）
dsh_run() {
  local prefix
  prefix="$(reg_prefix)"
  if [ "${MODE:-npx}" = "npx" ]; then
    ( cd "$HOME_DIR" && sh -c "${prefix}npx --yes $NPX_PKG $*" )
  else
    ( cd "${INSTALL_DIR:-$HOME_DIR/deepseek-harness}" && sh -c "${prefix}pnpm dsh $*" )
  fi
}

# 生成启动脚本（由 start 后台执行）
write_run_script() {
  mkdir -p "$CFG_DIR"
  local run_dir="$HOME_DIR"
  [ "${MODE:-npx}" = "source" ] && run_dir="${INSTALL_DIR:-$HOME_DIR/deepseek-harness}"
  {
    echo '#!/usr/bin/env bash'
    echo "# Generated by $APP_NAME $APP_VERSION — do not edit."
    printf 'export PATH="%s:$PATH"\n' "$BIN_DIR"
    if [ -n "$REGISTRY" ]; then printf 'export npm_config_registry=%s\n' "$REGISTRY"; fi
    printf 'cd %s\n' "$(shell_quote "$run_dir")"
    if [ "${MODE:-npx}" = "npx" ]; then
      printf 'exec npx --yes %s web --host %s --port %s\n' "$NPX_PKG" "$HOST" "$PORT"
    else
      printf 'exec pnpm dsh web --host %s --port %s\n' "$HOST" "$PORT"
    fi
  } > "$RUN_SCRIPT"
  chmod +x "$RUN_SCRIPT"
}

# ---------------------------------------------------------------- 服务管理
port_open() {
  if command -v curl >/dev/null 2>&1; then
    curl -fsS -o /dev/null --max-time 2 "http://127.0.0.1:$PORT/" 2>/dev/null && return 0
  fi
  (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null && return 0
  return 1
}

web_url() { echo "http://$HOST:$PORT"; }

ps_cmdline() { ps -p "$1" -o command= 2>/dev/null | head -1; }

# 进程存活即可（用于 status 展示 / start 成功判断；只读，无击杀风险）
our_pid_running() {
  [ -f "$PID_FILE" ] || return 1
  local pid=""
  pid="$(sed -n 's/^PID=//p' "$PID_FILE" 2>/dev/null)"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

# 严格身份校验（用于 stop 击杀前确认）：
# 0=确认是本工具的进程  1=身份不符（PID 被复用）  2=无法读取命令行（ps 不可用）
pid_identity_ok() {
  [ -f "$PID_FILE" ] || return 1
  local pid="" expect="" cmdline=""
  pid="$(sed -n 's/^PID=//p' "$PID_FILE" 2>/dev/null)"
  expect="$(sed -n 's/^EXPECT=//p' "$PID_FILE" 2>/dev/null)"
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  cmdline="$(ps_cmdline "$pid")"
  if [ -z "$cmdline" ]; then
    return 2
  fi
  if [ -n "$expect" ]; then
    case "$cmdline" in
      *"$expect"*) : ;;
      *) return 1 ;;
    esac
  fi
  case "$cmdline" in
    *"dsh web"*) return 0 ;;
    *) return 1 ;;
  esac
}

# 运行中 = PID 文件进程存活；端口探测仅用于“被占用”提示，不作为身份认证
is_running() { our_pid_running; }

cmd_start() {
  load_config
  [ -n "${MODE:-}" ] || MODE="npx"
  validate_config
  if [ "$MODE" = "source" ] && [ ! -d "${INSTALL_DIR:-$HOME_DIR/deepseek-harness}" ]; then
    die "未找到源码目录 ${INSTALL_DIR:-}，请先执行: $0 install -y --mode source"
  fi
  if our_pid_running; then
    info "Web UI 已在运行: $(web_url)"
    [ "$JSON_OUT" = "1" ] && printf '{"running":true,"url":"%s"}\n' "$(web_url)"
    return 0
  fi
  if port_open; then
    die "端口 $PORT 已被其他程序占用（非本工具管理的进程），请更换端口或自行处理"
  fi
  write_run_script
  info "后台启动 Web UI ..."
  nohup "$RUN_SCRIPT" >>"$LOG_FILE" 2>&1 &
  local pid=$!
  printf 'PID=%s\nEXPECT=web --host %s --port %s\n' "$pid" "$HOST" "$PORT" > "$PID_FILE"
  local i
  for i in $(seq 1 60); do
    port_open && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 1
  done
  if our_pid_running && port_open; then
    ok "Web UI 已启动: $(web_url)  (PID $pid)"
    [ "$JSON_OUT" = "1" ] && printf '{"running":true,"url":"%s","pid":%s}\n' "$(web_url)" "$pid"
    return 0
  fi
  err "启动失败，最近日志:"
  tail -n 10 "$LOG_FILE" 2>/dev/null | sed 's/^/    /' >&2 || true
  rm -f "$PID_FILE"
  return 1
}

cmd_stop() {
  load_config
  [ -n "${MODE:-}" ] || MODE="npx"
  local pid="$(sed -n 's/^PID=//p' "$PID_FILE" 2>/dev/null)"
  if ! our_pid_running; then
    info "未找到本工具管理的 Web UI 进程"
    if port_open; then
      warn "端口 $PORT 被其他程序占用，本工具不做处理（如确属 dsh 请手动停止）"
    fi
    [ "$JSON_OUT" = "1" ] && printf '{"running":false}\n'
    return 2
  fi
  local idcheck=0
  pid_identity_ok
  idcheck=$?
  if [ "$idcheck" -eq 2 ]; then
    err "无法读取进程命令行（ps 不可用），拒绝击杀以免误伤：请手动确认 PID $pid 后自行停止"
    return 1
  fi
  if [ "$idcheck" -ne 0 ]; then
    err "PID 文件与当前进程身份不符（PID 可能被复用），拒绝击杀 PID $pid"
    rm -f "$PID_FILE"
    return 1
  fi
  info "停止 Web UI ..."
  kill -TERM "$pid" 2>/dev/null || true
  local i
  for i in $(seq 1 10); do
    our_pid_running || break
    sleep 1
  done
  if our_pid_running; then
    kill -KILL "$pid" 2>/dev/null || true
    sleep 1
  fi
  rm -f "$PID_FILE"
  if our_pid_running; then
    err "停止失败，进程 $pid 仍在运行"
    return 1
  fi
  ok "Web UI 已停止"
  [ "$JSON_OUT" = "1" ] && printf '{"running":false}\n'
  return 0
}

cmd_restart() { cmd_stop >/dev/null 2>&1 || true; cmd_start; }

# 安装锚点：配置文件存在（记录过一次安装），源码模式还需仓库标记在
is_installed() {
  [ -f "$CONFIG_FILE" ] || return 1
  if [ "${MODE:-npx}" = "source" ]; then
    repo_marker "${INSTALL_DIR:-$HOME_DIR/deepseek-harness}" || return 1
  fi
  return 0
}

cmd_status() {
  load_config
  [ -n "${MODE:-}" ] || MODE="npx"
  local pid="$(sed -n 's/^PID=//p' "$PID_FILE" 2>/dev/null)"
  local installed=0 running=0
  is_installed && installed=1
  our_pid_alive && running=1
  if [ "$JSON_OUT" = "1" ]; then
    if [ "$running" = "1" ]; then
      printf '{"installed":%s,"running":true,"mode":"%s","host":"%s","port":"%s","url":"%s","pid":%s}\n' \
        "$installed" "${MODE:-npx}" "$HOST" "$PORT" "$(web_url)" "${pid:-null}"
    else
      printf '{"installed":%s,"running":false,"mode":"%s","host":"%s","port":"%s","url":"%s","pid":null}\n' \
        "$installed" "${MODE:-npx}" "$HOST" "$PORT" "$(web_url)"
    fi
    [ "$installed" = "1" ] && return 0 || return 2
  fi
  printf '%s\n' "${C_BOLD}DeepSeek Harness 状态${C_RESET}"
  printf '  安装状态 : %s\n' "$([ "$installed" = "1" ] && echo '已安装' || echo '未安装')"
  printf '  安装模式 : %s\n' "${MODE:-npx}"
  printf '  访问地址 : %s\n' "$(web_url)"
  printf '  日志文件 : %s\n' "$LOG_FILE"
  if [ "$running" = "1" ]; then
    printf '  运行状态 : %s%s运行中%s (PID %s)\n' "$C_GREEN" "$C_BOLD" "$C_RESET" "${pid:-未知}"
  else
    printf '  运行状态 : %s未运行%s\n' "$C_YELLOW" "$C_RESET"
    if port_open; then warn "注意: 端口 $PORT 被其他程序占用（非本工具管理）"; fi
  fi
  [ "$installed" = "1" ] && return 0 || return 2
}

cmd_logs() {
  load_config
  local follow=0 lines=50
  while [ $# -gt 0 ]; do
    case "$1" in
      -f|--follow) follow=1; shift ;;
      -n|--lines) lines="${2:-50}"; shift 2 ;;
      *) shift ;;
    esac
  done
  [ -f "$LOG_FILE" ] || die "日志文件不存在（尚未启动过）: $LOG_FILE"
  if [ "$follow" = "1" ]; then
    tail -n "$lines" -f "$LOG_FILE"
  else
    tail -n "$lines" "$LOG_FILE"
  fi
}

cmd_open() {
  load_config
  detect_platform
  local url; url="$(web_url)"
  if [ "$OS" = "macos" ] && command -v open >/dev/null 2>&1; then open "$url"
  elif command -v xdg-open >/dev/null 2>&1; then xdg-open "$url" >/dev/null 2>&1
  else info "请在浏览器打开: $url"; fi
}

# ---------------------------------------------------------------- 安装
repo_marker() {
  [ -f "$1/package.json" ] && grep -q '"name": *"@deepseek-ai/dsh-root"' "$1/package.json" 2>/dev/null
}

install_npx() {
  step "npx 快捷安装（预取官方发布包）"
  local out=""
  if out="$(dsh_run --version 2>&1)"; then
    info "dsh 版本: $(printf '%s' "$out" | grep -v '^npm notice' | tail -1)"
  elif out="$(dsh_run --help 2>&1)"; then
    info "dsh CLI 可用"
  else
    printf '%s' "$out" | tail -n 15 | sed 's/^/    /' >&2
    die "npx 安装失败，请检查网络（国内可加 --registry https://registry.npmmirror.com 重试）"
  fi
  ok "npx 模式安装完成（每次启动自动使用最新发布版）"
}

install_source() {
  step "源码安装"
  local repo_url="${CLONE_URL:-$GITHUB_REPO}"
  if [ -d "$INSTALL_DIR/.git" ] && repo_marker "$INSTALL_DIR"; then
    info "检测到现有仓库 ${INSTALL_DIR}，执行 git pull 更新"
    ( cd "$INSTALL_DIR" && git pull --ff-only ) || warn "git pull 失败，继续使用现有代码"
  elif [ -e "$INSTALL_DIR" ] && [ -n "$(ls -A "$INSTALL_DIR" 2>/dev/null)" ]; then
    die "目录 $INSTALL_DIR 已存在且不是 DeepSeek Harness 仓库，请换用 --dir 指定其他目录"
  else
    info "克隆 $repo_url → $INSTALL_DIR"
    git clone --depth 1 "$repo_url" "$INSTALL_DIR" || die "克隆失败（可加 --clone-url 指定镜像地址）"
  fi
  info "安装依赖 pnpm install（首次约需几分钟）..."
  local prefix; prefix="$(reg_prefix)"
  ( cd "$INSTALL_DIR" && sh -c "${prefix}pnpm install" ) || die "pnpm install 失败"
  info "构建 pnpm run build ..."
  ( cd "$INSTALL_DIR" && sh -c "${prefix}pnpm run build" ) || die "pnpm run build 失败"
  ok "源码安装完成: $INSTALL_DIR"
}

usage_install() {
  cat <<'EOF'
用法: ./install.sh install [选项]

  -m, --mode npx|source   安装方式: npx 快捷（默认）/ source 源码
  -d, --dir <路径>        源码模式的安装目录（默认 ~/deepseek-harness）
  -p, --port <端口>       Web UI 端口（默认 3080）
  -H, --host <地址>       绑定地址（默认 127.0.0.1）
  --registry <URL>        npm 镜像（国内网络可加 https://registry.npmmirror.com）
  --clone-url <URL>       git 克隆地址（默认官方 GitHub 仓库，可用镜像替代）
  --api-key <密钥>        写入 DEEPSEEK_API_KEY 到 ~/.dsh/.env
  --node-version <主版本> 自动安装的 Node 主版本（默认 24）
  --no-start              安装后不启动
  --no-skill              不注册 dsh 技能
  -y, --yes               非交互模式
  -q, --quiet             只输出错误
EOF
}

cmd_install() {
  # ---- 解析参数 ----
  local arg_mode="" arg_dir="" arg_port="" arg_host="" arg_registry=""
  local arg_key="" arg_clone="" arg_node=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -m|--mode) arg_mode="$2"; shift 2 ;;
      --mode=*) arg_mode="${1#*=}"; shift ;;
      -d|--dir) arg_dir="$2"; shift 2 ;;
      --dir=*) arg_dir="${1#*=}"; shift ;;
      -p|--port) arg_port="$2"; shift 2 ;;
      --port=*) arg_port="${1#*=}"; shift ;;
      -H|--host) arg_host="$2"; shift 2 ;;
      --host=*) arg_host="${1#*=}"; shift ;;
      --registry) arg_registry="$2"; shift 2 ;;
      --registry=*) arg_registry="${1#*=}"; shift ;;
      --api-key) arg_key="$2"; shift 2 ;;
      --api-key=*) arg_key="${1#*=}"; shift ;;
      --node-version) arg_node="$2"; shift 2 ;;
      --node-version=*) arg_node="${1#*=}"; shift ;;
      --clone-url) arg_clone="$2"; shift 2 ;;
      --clone-url=*) arg_clone="${1#*=}"; shift ;;
      -y|--yes) YES=1; shift ;;
      --no-start) NO_START=1; shift ;;
      --no-skill) NO_SKILL=1; shift ;;
      -q|--quiet) QUIET=1; shift ;;
      -h|--help) usage_install; return 0 ;;
      *) die "未知选项: $1（查看帮助: $0 install --help）" ;;
    esac
  done

  detect_platform
  load_config
  # 命令行参数覆盖已存配置
  [ -n "$arg_mode" ] && MODE="$arg_mode"
  [ -n "$arg_dir" ] && INSTALL_DIR="$arg_dir"
  [ -n "$arg_port" ] && PORT="$arg_port"
  [ -n "$arg_host" ] && HOST="$arg_host"
  [ -n "$arg_registry" ] && REGISTRY="$arg_registry"
  [ -n "$arg_key" ] && API_KEY="$arg_key"
  [ -n "$arg_node" ] && NODE_MAJOR="$arg_node"
  [ -n "$arg_clone" ] && CLONE_URL="$arg_clone"
  [ -n "$PORT" ] || PORT="$DEFAULT_PORT"
  [ -n "$HOST" ] || HOST="$DEFAULT_HOST"
  [ -n "$INSTALL_DIR" ] || INSTALL_DIR="$HOME_DIR/deepseek-harness"
  validate_config

  printf '%s\n' "${C_BOLD}${C_BLUE}  DeepSeek Harness 多平台安装器 v$APP_VERSION ($OS/$ARCH)${C_RESET}"
  echo

  if [ -z "$MODE" ]; then
    if [ "$YES" = "1" ] || [ ! -t 0 ]; then
      MODE="npx"
    else
      info "请选择安装方式:"
      echo "  [1] npx 快捷安装（推荐）— 运行 npm 官方发布包，启动快、自动获取更新"
      echo "  [2] 源码安装 — git clone 官方仓库并本地构建，适合读改源码"
      local choice=""
      printf '%s' "${C_BOLD}请输入 1 或 2 [1]: ${C_RESET}"
      read -r choice || choice=""
      case "${choice:-1}" in
        1) MODE="npx" ;;
        2) MODE="source" ;;
        *) die "无效选择: $choice" ;;
      esac
    fi
  fi
  case "$MODE" in
    npx|source) ;;
    *) die "无效模式 ${MODE}（可选 npx | source）" ;;
  esac

  # ---- 依赖 ----
  info "安装模式: $MODE"
  ensure_node
  if [ "$MODE" = "source" ]; then
    ensure_git
    ensure_pnpm || die "pnpm 不可用（源码模式需要）"
  fi
  # npx 模式不强制安装 pnpm（仅插件管理需要，届时按需安装）

  # ---- 安装 ----
  case "$MODE" in
    npx) install_npx ;;
    source) install_source ;;
  esac

  # ---- API Key ----
  if [ -n "$API_KEY" ]; then
    mkdir -p "$DSH_HOME_DIR"
    local env_file="$DSH_HOME_DIR/.env"
    if grep -q '^DEEPSEEK_API_KEY=' "$env_file" 2>/dev/null; then
      sed -i.bak "s|^DEEPSEEK_API_KEY=.*|DEEPSEEK_API_KEY=$API_KEY|" "$env_file" && rm -f "$env_file.bak"
    else
      echo "DEEPSEEK_API_KEY=$API_KEY" >> "$env_file"
    fi
    chmod 600 "$env_file"
    ok "API Key 已写入 ${env_file}（也可稍后在 Web UI 设置页配置）"
  fi

  # ---- 启动器 / CLI 链接 / 技能 ----
  write_run_script
  write_launcher
  install_skill || true
  save_config

  echo
  ok "安装完成！"
  echo "  启动 Web UI : $(web_url)"
  echo "  下次启动    : dsh-web  或  $0 start"
  echo "  插件管理    : $0 plugin add <包名|github:用户/仓库|./路径>"
  echo "  卸载        : $0 uninstall"

  if [ "$NO_START" = "0" ]; then
    if confirm "立即启动 Web UI？" "y"; then
      cmd_start
    fi
  fi
}

# ---------------------------------------------------------------- 启动器/链接
write_launcher() {
  mkdir -p "$BIN_DIR"
  local run_dir="$HOME_DIR"
  [ "${MODE:-npx}" = "source" ] && run_dir="${INSTALL_DIR:-$HOME_DIR/deepseek-harness}"
  {
    echo '#!/usr/bin/env bash'
    echo "# Generated by $APP_NAME $APP_VERSION — do not edit."
    printf 'export PATH="%s:$PATH"\n' "$BIN_DIR"
    if [ -n "$REGISTRY" ]; then printf 'export npm_config_registry=%s\n' "$REGISTRY"; fi
    printf 'cd %s\n' "$(shell_quote "$run_dir")"
    if [ "${MODE:-npx}" = "npx" ]; then
      printf 'exec npx --yes %s web --host %s --port %s\n' "$NPX_PKG" "$HOST" "$PORT"
    else
      printf 'exec pnpm dsh web --host %s --port %s\n' "$HOST" "$PORT"
    fi
  } > "$LAUNCHER"
  chmod +x "$LAUNCHER"
  ln -sf "$SCRIPT_PATH" "$CLI_LINK"
  if ! printf '%s' ":$PATH:" | grep -q ":$BIN_DIR:"; then
    warn "提示: $BIN_DIR 不在 PATH 中"
    warn "  执行: export PATH=\"$BIN_DIR:\$PATH\"（或加入 ~/.bashrc / ~/.zshrc）"
  fi
}

# ---------------------------------------------------------------- 插件管理
plugin_profile_dir() { printf '%s/profiles/%s' "$DSH_HOME_DIR" "$WEB_PROFILE"; }

cmd_plugin() {
  load_config
  [ -n "${MODE:-}" ] || MODE="npx"
  local profile="$WEB_PROFILE" action="" args=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) JSON_OUT=1; shift ;;
      --profile) profile="$2"; shift 2 ;;
      --profile=*) profile="${1#*=}"; shift ;;
      -q|--quiet) QUIET=1; shift ;;
      *)
        if [ -z "$action" ]; then action="$1"; else args+=("$1"); fi
        shift ;;
    esac
  done
  [ -n "$action" ] || action="list"
  case "$action" in
    add|install|i)            dsh_plugin_run "$profile" add "${args[@]}" ;;
    remove|rm|uninstall|del)  dsh_plugin_run "$profile" remove "${args[@]}" ;;
    update|upgrade|up)        dsh_plugin_run "$profile" update "${args[@]}" ;;
    list|ls)
      if [ "$JSON_OUT" = "1" ]; then plugin_list_json "$profile"; else plugin_list_text "$profile"; fi ;;
    search|s)                 plugin_search "${args[@]}" ;;
    *) err "用法: $0 plugin <add|remove|update|list|search> [参数]"; return 1 ;;
  esac
}

dsh_plugin_run() {
  # dsh_plugin_run <profile> <pnpm子命令> <参数...>
  local profile="$1" action="$2"; shift 2
  command -v pnpm >/dev/null 2>&1 || { warn "插件管理需要 pnpm，尝试安装 ..."; ensure_pnpm || die "pnpm 不可用"; }
  local rc=0
  if [ "${MODE:-npx}" = "npx" ]; then
    if [ -n "$REGISTRY" ]; then
      ( cd "$HOME_DIR" && env "npm_config_registry=$REGISTRY" npx --yes "$NPX_PKG" plugin --profile "$profile" "$action" "$@" )
    else
      ( cd "$HOME_DIR" && npx --yes "$NPX_PKG" plugin --profile "$profile" "$action" "$@" )
    fi
  else
    if [ -n "$REGISTRY" ]; then
      ( cd "${INSTALL_DIR:-$HOME_DIR/deepseek-harness}" && env "npm_config_registry=$REGISTRY" pnpm dsh plugin --profile "$profile" "$action" "$@" )
    else
      ( cd "${INSTALL_DIR:-$HOME_DIR/deepseek-harness}" && pnpm dsh plugin --profile "$profile" "$action" "$@" )
    fi
  fi
  rc=$?
  if [ "$rc" -ne 0 ]; then
    warn "pnpm 拒绝了本次操作（可能是依赖的构建脚本需审批——安全闸门，不做全局放松）"
    warn "  交互终端中可直接按 pnpm 提示批准；或手动执行:"
    warn "  dsh plugin --profile $profile approve-builds"
  fi
  return $rc
}

plugin_list_json() {
  local profile="$1" dir
  dir="$(printf '%s/profiles/%s' "$DSH_HOME_DIR" "$profile")"
  node -e 'const fs=require("fs");const dir=process.argv[1];const f=dir+"/package.json";let plugins=[],bundles=[];if(fs.existsSync(f)){const p=JSON.parse(fs.readFileSync(f,"utf8"));plugins=Object.keys(p.dependencies||{}).map(n=>({name:n,version:p.dependencies[n]||""}));bundles=(p.dsh&&p.dsh.profile&&p.dsh.profile.bundles)||[];}process.stdout.write(JSON.stringify({profile:process.argv[2]||"web",plugins,bundles}))' "$dir" "$profile"
  echo
}

plugin_list_text() {
  local profile="$1" dir
  dir="$(printf '%s/profiles/%s' "$DSH_HOME_DIR" "$profile")"
  node -e 'const fs=require("fs");const dir=process.argv[1];const f=dir+"/package.json";let plugins=[],bundles=[];if(fs.existsSync(f)){const p=JSON.parse(fs.readFileSync(f,"utf8"));plugins=Object.keys(p.dependencies||{}).map(n=>({name:n,version:p.dependencies[n]||""}));bundles=(p.dsh&&p.dsh.profile&&p.dsh.profile.bundles)||[];}console.log("Profile: "+(process.argv[2]||"web"));console.log("  插件:");if(!plugins.length){console.log("    (无)")}for(const x of plugins){console.log("    - "+x.name+"@"+x.version)}console.log("  激活的组合包(bundles):");if(!bundles.length){console.log("    (无)")}for(const b of bundles){console.log("    - "+b)}' "$dir" "$profile"
}

plugin_search() {
  local kw="${1:-dsh-plugin}"
  local raw=""
  if [ -n "$REGISTRY" ]; then
    raw="$(env "npm_config_registry=$REGISTRY" npm search --json "$kw" 2>/dev/null || true)"
  else
    raw="$(npm search --json "$kw" 2>/dev/null || true)"
  fi
  [ -n "$raw" ] || die "插件搜索失败（检查网络或 npm registry）"
  if [ "$JSON_OUT" = "1" ]; then
    printf '%s\n' "$raw" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const a=JSON.parse(s);console.log(JSON.stringify(a.slice(0,30).map(p=>({name:p.name,version:p.version,description:p.description||""})),null,2))}catch(e){console.log(s)}})'
    return 0
  fi
  printf '%s\n' "$raw" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const a=JSON.parse(s);if(!a.length){console.log("  未找到相关插件")}for(const p of a.slice(0,20)){console.log("  "+(p.name||"")+"@"+(p.version||"")+"\n    "+(p.description||""))}}catch(e){console.log(s)}})'
}

# ---------------------------------------------------------------- 更新
cmd_update() {
  load_config
  [ -n "${MODE:-}" ] || MODE="npx"
  local was_running=0
  is_running && was_running=1
  if [ "${MODE:-npx}" = "npx" ]; then
    info "npx 模式每次启动都会拉取最新发布版；现在清理本地缓存"
    npm_uninstall_dsh
    ok "npx 缓存已清理，下次启动即用最新版"
  else
    info "更新源码 ..."
    ( cd "$INSTALL_DIR" && git pull --ff-only ) || die "git pull 失败"
    local prefix; prefix="$(reg_prefix)"
    ( cd "$INSTALL_DIR" && sh -c "${prefix}pnpm install" ) || die "pnpm install 失败"
    ( cd "$INSTALL_DIR" && sh -c "${prefix}pnpm run build" ) || die "pnpm run build 失败"
    ok "源码更新完成"
  fi
  if [ "$was_running" = "1" ]; then
    info "重启 Web UI ..."
    cmd_stop >/dev/null 2>&1 || true
    cmd_start
  fi
}

# ---------------------------------------------------------------- 信息
cmd_info() {
  detect_platform
  load_config
  [ -n "${MODE:-}" ] || MODE="npx"
  local nv="未安装" pv="未安装" gv="未安装"
  command -v node >/dev/null 2>&1 && nv="v$(node_version)"
  command -v pnpm >/dev/null 2>&1 && pv="v$(pnpm --version 2>/dev/null)"
  command -v git  >/dev/null 2>&1 && gv="$(git --version 2>/dev/null | awk '{print $3}')"
  local running=0 pid=""
  is_running && running=1
  pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  if [ "$JSON_OUT" = "1" ]; then
    printf '{"app":"%s","version":"%s","os":"%s","arch":"%s","mode":"%s","installDir":"%s","dshHome":"%s","node":"%s","nodeOk":%s,"pnpm":"%s","git":"%s","host":"%s","port":"%s","url":"%s","running":%s,"pid":%s,"log":"%s"}\n' \
      "$APP_NAME" "$APP_VERSION" "$OS" "$ARCH" "${MODE:-npx}" "${INSTALL_DIR:-$HOME_DIR/deepseek-harness}" \
      "$DSH_HOME_DIR" "$nv" "$(node_is_ok && echo true || echo false)" "$pv" "$gv" \
      "$HOST" "$PORT" "$(web_url)" "$running" "${pid:-null}" "$LOG_FILE"
    return 0
  fi
  printf '%s\n' "${C_BOLD}${C_BLUE}  DeepSeek Harness 环境信息${C_RESET}"
  printf '  安装器     : %s v%s\n' "$APP_NAME" "$APP_VERSION"
  printf '  系统       : %s / %s\n' "$OS" "$ARCH"
  printf '  Node.js    : %s\n' "$nv"
  printf '  pnpm       : %s\n' "$pv"
  printf '  git        : %s\n' "$gv"
  printf '  安装模式   : %s\n' "${MODE:-npx}"
  printf '  安装目录   : %s\n' "${INSTALL_DIR:-$HOME_DIR/deepseek-harness}"
  printf '  数据目录   : %s\n' "$DSH_HOME_DIR"
  printf '  访问地址   : %s\n' "$(web_url)"
  printf '  日志文件   : %s\n' "$LOG_FILE"
  if [ "$running" = "1" ]; then
    printf '  运行状态   : %s运行中%s (PID %s)\n' "$C_GREEN" "$C_RESET" "${pid:-未知}"
  else
    printf '  运行状态   : %s未运行%s\n' "$C_YELLOW" "$C_RESET"
  fi
}

# ---------------------------------------------------------------- dsh 技能
install_skill() {
  [ "$NO_SKILL" = "1" ] && return 0
  mkdir -p "$SKILL_DIR" || { warn "创建技能目录失败: $SKILL_DIR"; return 1; }
  cat > "$SKILL_DIR/SKILL.md" <<'SKILL_EOF'
---
name: dsh-installer
description: DeepSeek Harness 安装、服务与插件管理工具。当用户要求安装/更新/卸载 DeepSeek Harness，安装/移除/搜索 dsh 插件，或启动/停止/查看 Web UI 服务时使用。
---

# DeepSeek Harness 安装器（dsh-installer）

通过 dsh-installer 命令管理 DeepSeek Harness 本体与插件。所有命令必须非交互（加 -y），机器结果用 --json。

## 定位安装器
优先执行 **command -v dsh-installer**；否则依次尝试 **~/.local/bin/dsh-installer**、**bash ~/DSH-installer/install.sh**。

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
3. 要求 Node.js >= 22.19 或 >= 24；缺失时安装器自动装到用户目录（无需 sudo）。
4. 国内网络失败时加 **--registry https://registry.npmmirror.com** 重试。
SKILL_EOF
  ok "已注册 dsh 技能: $SKILL_DIR/SKILL.md（dsh 可直接调用本安装器）"
}

cmd_skill() {
  load_config
  install_skill
}

# ---------------------------------------------------------------- 交互菜单
menu_banner() {
  load_config
  [ -n "${MODE:-}" ] || MODE="npx"
  local running=0
  is_running && running=1
  printf '\n%s%s  DeepSeek Harness 安装器 v%s —— 主菜单%s\n' "$C_BOLD" "$C_BLUE" "$APP_VERSION" "$C_RESET"
  printf '  安装模式: %s | 访问地址: %s | ' "${MODE:-未安装}" "$(web_url)"
  if [ "$running" = "1" ]; then printf '%s运行中%s\n' "$C_GREEN" "$C_RESET"; else printf '%s未运行%s\n' "$C_YELLOW" "$C_RESET"; fi
  echo
}

menu_install() {
  echo "  安装方式:"
  echo "    [1] npx 快捷安装（推荐）—— npm 官方发布包，启动快、自动更新"
  echo "    [2] 源码安装 —— git clone 官方仓库并本地构建"
  printf '%s' "${C_BOLD}请选择 [1]: ${C_RESET}"
  local c=""
  read -r c || c=""
  case "${c:-1}" in
    1) MODE="npx" ;;
    2) MODE="source" ;;
    *) warn "无效选择"; return ;;
  esac
  local extra=() port="" dir=""
  extra+=(--mode "$MODE")
  printf '%s' "${C_BOLD}Web UI 端口 [${PORT:-3080}]: ${C_RESET}"
  read -r port || port=""
  [ -n "$port" ] && extra+=(--port "$port")
  if [ "$MODE" = "source" ]; then
    printf '%s' "${C_BOLD}安装目录 [${INSTALL_DIR:-$HOME_DIR/deepseek-harness}]: ${C_RESET}"
    read -r dir || dir=""
    [ -n "$dir" ] && extra+=(--dir "$dir")
  fi
  echo
  cmd_install "${extra[@]}"
}

menu_plugin() {
  while true; do
    echo
    echo "  插件管理:"
    echo "    [1] 安装插件"
    echo "    [2] 移除插件"
    echo "    [3] 更新全部插件"
    echo "    [4] 插件列表"
    echo "    [5] 搜索插件"
    echo "    [0] 返回主菜单"
    printf '%s' "${C_BOLD}请选择 [0]: ${C_RESET}"
    local c="" p=""
    read -r c || c=""
    case "${c:-0}" in
      0|"") return ;;
      1)
        printf '%s' "${C_BOLD}插件来源（npm 包名 | github:用户/仓库 | 本地路径 | .tgz）: ${C_RESET}"
        read -r p || p=""
        if [ -n "$p" ]; then cmd_plugin add "$p"; else warn "未输入插件来源"; fi
        ;;
      2)
        printf '%s' "${C_BOLD}要移除的插件包名: ${C_RESET}"
        read -r p || p=""
        if [ -n "$p" ]; then cmd_plugin remove "$p"; else warn "未输入包名"; fi
        ;;
      3) cmd_plugin update ;;
      4) cmd_plugin list ;;
      5)
        printf '%s' "${C_BOLD}搜索关键词（回车=全部 dsh-plugin）: ${C_RESET}"
        read -r p || p=""
        cmd_plugin search "${p:-dsh-plugin}"
        ;;
      *) warn "无效选择: $c" ;;
    esac
  done
}

menu_uninstall() {
  echo
  echo "  卸载选项:"
  echo "    [1] 卸载本工具安装的 DSH（默认，安全；保留 ~/.dsh 数据）"
  echo "    [2] 卸载并删除 ~/.dsh 数据（二次确认）"
  echo "    [3] 扫描并清理外部安装（危险：默认取消、逐项展示、脏仓库拒绝）"
  echo "    [0] 返回主菜单"
  printf '%s' "${C_BOLD}请选择 [0]: ${C_RESET}"
  local c=""
  read -r c || c=""
  case "${c:-0}" in
    0|"") return ;;
    1) cmd_uninstall ;;
    2) cmd_uninstall --purge ;;
    3) cmd_remove_external ;;
    *) warn "无效选择: $c" ;;
  esac
}

run_menu() {
  while true; do
    menu_banner
    echo "  请选择操作:"
    echo "    [1]  安装 DeepSeek Harness"
    echo "    [2]  启动 Web UI"
    echo "    [3]  停止 Web UI"
    echo "    [4]  重启 Web UI"
    echo "    [5]  查看运行状态"
    echo "    [6]  查看日志"
    echo "    [7]  在浏览器打开 Web UI"
    echo "    [8]  插件管理"
    echo "    [9]  更新 DSH"
    echo "    [10] 环境信息"
    echo "    [11] 注册 dsh 技能"
    echo "    [12] 卸载"
    echo "    [0]  退出"
    printf '%s' "${C_BOLD}请输入数字 [0]: ${C_RESET}"
    local c=""
    read -r c || c=""
    case "${c:-0}" in
      0|"") echo; info "再见！"; return 0 ;;
      1) menu_install ;;
      2) cmd_start ;;
      3) cmd_stop ;;
      4) cmd_restart ;;
      5) cmd_status ;;
      6) cmd_logs ;;
      7) cmd_open ;;
      8) menu_plugin ;;
      9) cmd_update ;;
      10) cmd_info ;;
      11) cmd_skill ;;
      12) menu_uninstall ;;
      *) warn "无效选择: $c" ;;
    esac
  done
}

# ---------------------------------------------------------------- 卸载
cmd_uninstall() {
  local purge=0 extra_dir="" remove_external=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --purge) purge=1; shift ;;
      --remove-external) remove_external=1; shift ;;
      -d|--dir) extra_dir="$2"; shift 2 ;;
      --dir=*) extra_dir="${1#*=}"; shift ;;
      -y|--yes) YES=1; shift ;;
      -q|--quiet) QUIET=1; shift ;;
      *) die "未知选项: $1" ;;
    esac
  done
  load_config
  [ -n "${MODE:-}" ] || MODE="npx"

  if [ ! -t 0 ] && [ "$YES" != "1" ]; then
    die "卸载需确认：非交互调用请加 -y"
  fi
  if ! confirm "确定卸载本工具安装的 DeepSeek Harness？" "n"; then
    info "已取消"
    return 0
  fi

  info "停止服务 ..."
  cmd_stop >/dev/null 2>&1 || true

  # ---- 只清理本工具确认拥有的资源（默认不扫、不猜、不扩大范围）----
  if [ "${MODE:-npx}" = "source" ]; then
    if [ -d "$INSTALL_DIR" ] && repo_marker "$INSTALL_DIR"; then
      if [ "$INSTALL_DIR" = "/" ] || [ "$INSTALL_DIR" = "$HOME_DIR" ]; then
        warn "拒绝删除不安全路径: $INSTALL_DIR"
      elif [ -n "$(git -C "$INSTALL_DIR" status --porcelain 2>/dev/null)" ]; then
        if confirm "源码目录存在未提交改动，仍要删除？" "n"; then
          rm -rf "$INSTALL_DIR" && ok "已删除源码目录: $INSTALL_DIR"
        else
          warn "已跳过源码目录: $INSTALL_DIR"
        fi
      else
        info "删除源码目录: $INSTALL_DIR"
        rm -rf "$INSTALL_DIR"
      fi
    else
      info "源码目录不存在或非本安装器管理，跳过"
    fi
  else
    info "清理 npx 缓存中的 dsh ..."
    rm -rf "$(npx_cache_dir)/_npx"
  fi

  [ -f "$LAUNCHER" ] && rm -f "$LAUNCHER"
  [ -L "$CLI_LINK" ] && rm -f "$CLI_LINK"
  [ -d "$SKILL_DIR" ] && rm -rf "$SKILL_DIR"
  [ -f "$NODE_DIR/.installed-by-dsh-installer" ] && rm -rf "$NODE_DIR"
  for b in node npm npx corepack; do
    if [ -L "$BIN_DIR/$b" ] && [ -e "$BIN_DIR/$b" ] && [ "$(readlink "$BIN_DIR/$b" 2>/dev/null)" = "$NODE_DIR/bin/$b" ]; then
      rm -f "$BIN_DIR/$b"
    fi
  done
  rm -rf "$CFG_DIR"
  rmdir "$BIN_DIR" 2>/dev/null || true

  if [ "$purge" = "1" ]; then
    if [ "$DSH_HOME_DIR" = "$HOME_DIR" ] || [ "$DSH_HOME_DIR" = "/" ] || [ "${DSH_HOME_DIR##*/}" != ".dsh" ]; then
      die "拒绝删除不安全路径: ${DSH_HOME_DIR}（--purge 仅允许删除 ~/.dsh 形态的数据目录）"
    fi
    if confirm "同时删除全部数据目录 ${DSH_HOME_DIR}（会话、配置、插件全部丢失）？" "n"; then
      rm -rf "$DSH_HOME_DIR"
      ok "已删除数据目录"
    else
      info "保留数据目录: $DSH_HOME_DIR"
    fi
  fi

  ok "卸载完成"
  [ "$purge" = "1" ] || info "提示: 数据目录 $DSH_HOME_DIR 已保留，如需彻底删除请用 --purge"
  if [ "${MODE:-npx}" = "npx" ]; then
    info "说明: npx 模式无驻留安装，npx @deepseek-ai/dsh web 本身随时可再次运行（已清理缓存/启动器/技能）"
  fi

  # 外部安装清理是独立的危险操作，默认不执行
  if [ "$remove_external" = "1" ]; then
    cmd_remove_external "$extra_dir"
  elif [ -n "$extra_dir" ]; then
    warn "提示: --dir 仅在 --remove-external 时生效"
  fi
}

# 扫描并清理外部安装（独立危险操作：先展示清单，默认取消）
cmd_remove_external() {
  local extra_dir="${1:-}"
  local found="" line="" type="" path=""
  found="$( { scan_external_pkgs; scan_source_repos; } | sort -u )"
  if [ -n "$extra_dir" ] && repo_marker "$extra_dir"; then
    found="$(printf '%s\nrepo:%s\n' "$found" "$extra_dir" | sort -u)"
  fi
  if [ -z "$found" ]; then
    info "未发现其他方式安装的 DeepSeek Harness"
    return 0
  fi
  echo
  warn "以下为本工具之外的安装（先展示清单，默认不删除）:"
  printf '%s\n' "$found" | sed 's/^/    /'
  echo
  if ! confirm "确认清理以上全部外部安装？" "n"; then
    info "已取消（核对清单后再执行）"
    return 0
  fi
  # 原生卸载（确认之后才执行）
  if command -v npm >/dev/null 2>&1; then npm uninstall -g "$NPX_PKG" >/dev/null 2>&1 || true; fi
  if command -v pnpm >/dev/null 2>&1; then pnpm uninstall -g "$NPX_PKG" >/dev/null 2>&1 || true; fi
  if command -v yarn >/dev/null 2>&1; then yarn global remove "$NPX_PKG" >/dev/null 2>&1 || true; fi
  # 删除剩余候选
  printf '%s\n' "$found" | while IFS= read -r line; do
    [ -n "$line" ] || continue
    type="${line%%:*}"; path="${line#*:}"
    case "$type" in
      global)
        [ -d "$path" ] && rm -rf "$path" && ok "已删除全局安装: $path"
        ;;
      repo)
        if [ "$path" = "/" ] || [ "$path" = "$HOME_DIR" ]; then
          warn "拒绝删除不安全路径: $path"
        elif [ -n "$(git -C "$path" status --porcelain 2>/dev/null)" ]; then
          warn "仓库有未提交改动，跳过: $path"
        else
          rm -rf "$path" && ok "已删除源码仓库: $path"
        fi
        ;;
    esac
  done
  # 只清理能证明归属的 dsh shim
  cleanup_owned_shims
  if command -v dsh >/dev/null 2>&1; then
    warn "PATH 中仍存在 dsh 命令: $(command -v dsh)（如仍存在请手动处理）"
  fi
  ok "外部安装清理流程结束"
}

# ---------------------------------------------------------------- 帮助
usage() {
  cat <<'EOF'
DeepSeek Harness 多平台安装器 (macOS / Linux)

用法: ./install.sh [命令] [选项]

命令:
  menu         进入交互菜单（无参数直接运行时自动进入）
  install      安装 DeepSeek Harness（默认命令）
  start        后台启动 Web UI
  stop         停止 Web UI
  restart      重启 Web UI
  status       查看运行状态（--json 输出机器可读结果）
  logs         查看运行日志（-f 持续输出，-n 行数）
  update       更新 DSH（源码模式）/ 刷新 npx 缓存（npx 模式）
  plugin       插件管理: add | remove | update | list | search
  info         查看环境与安装信息（--json）
  open         在浏览器打开 Web UI
  skill        把本安装器注册为 dsh 技能（dsh 可直接调用本工具）
  uninstall    卸载本工具安装的 DSH（--purge 删数据；--remove-external 清理外部安装）
  remove-external  扫描并清理外部安装（独立危险操作，先展示清单默认取消）
  version      显示版本号

通用选项:
  -y, --yes    非交互模式（供 dsh/CI 调用）
  -q, --quiet  只输出错误
  --json       机器可读输出（status/info/plugin list/search）
  -h, --help   帮助

退出码: 0=成功  1=错误  2=服务未运行/未安装

示例:
  ./install.sh install                          # 交互式安装（默认 npx 模式）
  ./install.sh install -y --mode source         # 非交互源码安装
  ./install.sh install -y --port 8080 --registry https://registry.npmmirror.com
  ./install.sh plugin add github:somebody/awesome-dsh-plugin -y
  ./install.sh status --json
EOF
}

# ---------------------------------------------------------------- 入口
main() {
  local cmd="${1:-}"
  if [ -z "$cmd" ]; then
    # 无参数：交互终端进入菜单；非交互（dsh/CI）保持默认安装行为
    if [ -t 0 ] && [ -t 1 ]; then
      run_menu
      return 0
    fi
    cmd="install"
  fi
  shift || true
  case "$cmd" in
    menu) run_menu ;;
    install) cmd_install "$@" ;;
    start) cmd_start "$@" ;;
    stop) cmd_stop "$@" ;;
    restart) cmd_restart "$@" ;;
    status)
      while [ $# -gt 0 ]; do
        case "$1" in
          --json) JSON_OUT=1; shift ;;
          -q|--quiet) QUIET=1; shift ;;
          *) shift ;;
        esac
      done
      cmd_status ;;
    logs) cmd_logs "$@" ;;
    update) cmd_update "$@" ;;
    plugin) cmd_plugin "$@" ;;
    info)
      while [ $# -gt 0 ]; do
        case "$1" in
          --json) JSON_OUT=1; shift ;;
          -q|--quiet) QUIET=1; shift ;;
          *) shift ;;
        esac
      done
      cmd_info ;;
    open) cmd_open ;;
    skill) cmd_skill ;;
    uninstall) cmd_uninstall "$@" ;;
    remove-external) cmd_remove_external ;;
    version|-V|--version) echo "$APP_VERSION" ;;
    -h|--help|help|"") usage ;;
    *) usage >&2; exit 1 ;;
  esac
}

main "$@"
