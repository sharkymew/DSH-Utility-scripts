#Requires -Version 5.1
# ============================================================================
#  DeepSeek Harness 多平台安装器 (Windows)
#
#  用法: powershell -ExecutionPolicy Bypass -File install.ps1 [命令] [选项]
#
#  命令:
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
#    skill        可选注册 dsh 技能（实验性，未经完整测试）
#    uninstall    卸载（--purge 删除 DSH_HOME；--dry-run 预览；--purge-temp 清临时残留）
#    version      显示版本号
#
#  设计目标: 无交互会话时自动非交互（可被 dsh/CI 直接调用），--json 输出
#  机器可读结果，稳定退出码: 0=成功 1=错误 2=服务未运行/未安装。
# ============================================================================
param(
  [Parameter(Position = 0)][string]$Command = "install",
  [Parameter(ValueFromRemainingArguments = $true)][object[]]$RestArgs = @()
)
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------- 常量
$script:AppName = "dsh-installer"
$script:AppVersion = "1.3.0"
$script:NpxPkg = "@deepseek-ai/dsh"
$script:GithubRepo = "https://github.com/deepseek-ai/deepseek-harness.git"
$script:DefaultNodeMajor = "24"
$script:PnpmVersion = "11.7.0"
$script:WebProfile = "web"
$script:DefaultBindHost = "127.0.0.1"
$script:DefaultPort = 3080

# ---------------------------------------------------------------- 目录
if (-not $env:USERPROFILE) { $env:USERPROFILE = $env:HOME }
$script:HomeDir = $env:USERPROFILE
$script:IsWin = ($env:OS -eq "Windows_NT")
if ($env:LOCALAPPDATA) { $script:LocalAppData = $env:LOCALAPPDATA }
else { $script:LocalAppData = Join-Path $HomeDir "AppData/Local" }
$script:CfgDir = Join-Path $LocalAppData "dsh-installer"
$script:BinDir = Join-Path $CfgDir "bin"
$script:ConfigFile = Join-Path $CfgDir "config.json"
$script:PidFile = Join-Path $CfgDir "web.pid"
$script:LogFile = Join-Path $CfgDir "web.log"
$script:ErrLogFile = Join-Path $CfgDir "web.err.log"
$script:RunScript = Join-Path $CfgDir "run-web.cmd"
$script:Launcher = Join-Path $BinDir "dsh-web.cmd"
$script:CliLink = Join-Path $BinDir "dsh-installer.cmd"
$script:NodeDir = Join-Path $CfgDir "node"
$script:DshHomeOverride = $env:DSH_HOME
if (-not [string]::IsNullOrWhiteSpace($env:DSH_HOME)) { $script:DshHome = $env:DSH_HOME }
else { $script:DshHome = Join-Path $HomeDir ".dsh" }
$script:SkillDir = Join-Path $DshHome "skills/dsh-installer"
$script:SkillMarker = Join-Path $SkillDir ".installed-by-dsh-installer"
# 源码归属标记放在 .git 内，避免污染用户工作区或触发“未提交变更”判定。
$script:SourceMarkerName = ".git/dsh-installer-owned"
if ($PSCommandPath) { $script:PsScriptPath = (Resolve-Path $PSCommandPath).Path }
elseif ($PSScriptRoot) { $script:PsScriptPath = Join-Path $PSScriptRoot "install.ps1" }
else { $script:PsScriptPath = Join-Path (Get-Location) "install.ps1" }

# ---------------------------------------------------------------- 状态
$script:Mode = $null
$script:InstallDir = Join-Path $HomeDir "deepseek-harness"
$script:BindHost = $DefaultBindHost
$script:Port = $DefaultPort
$script:Registry = ""
$script:ApiKey = ""
$script:Yes = $false
$script:Quiet = $false
$script:JsonOut = $false
$script:NoStart = $false
$script:NodeMajor = $DefaultNodeMajor
$script:CloneUrl = ""

# ---------------------------------------------------------------- 输出
function Write-Info([string]$msg) { if (-not $script:Quiet) { Write-Host "[信息] $msg" -ForegroundColor Cyan } }
function Write-Ok([string]$msg)   { if (-not $script:Quiet) { Write-Host "[完成] $msg" -ForegroundColor Green } }
function Write-Warn([string]$msg) { Write-Host "[警告] $msg" -ForegroundColor Yellow }
function Write-Err([string]$msg)  { Write-Host "[错误] $msg" -ForegroundColor Red }
function Write-Step([string]$msg) { if (-not $script:Quiet) { Write-Host "==> $msg" -ForegroundColor White } }
function Exit-Die([string]$msg)   { Write-Err $msg; exit 1 }

# ---------------------------------------------------------------- 基础工具
function Confirm-Action([string]$msg, [bool]$defaultYes) {
  if ($script:Yes) { return $true }
  if (-not [Environment]::UserInteractive) { return $defaultYes }
  $hint = "Y/n"; if (-not $defaultYes) { $hint = "y/N" }
  $ans = Read-Host -Prompt "$msg [$hint]"
  if ([string]::IsNullOrWhiteSpace($ans)) { return $defaultYes }
  return ($ans -match "^(y|yes)$")
}

# 外部安装清理不接受普通 -y 自动确认：必须在可交互终端中再次明确同意。
function Confirm-ExternalRemoval([string]$msg) {
  if (-not [Environment]::UserInteractive -or [Console]::IsInputRedirected) {
    Write-Err "外部安装清理只能在可交互终端中确认，拒绝在 -y/CI 模式执行"
    return $false
  }
  $ans = Read-Host -Prompt "$msg [y/N]"
  return ($ans -match "^(y|yes)$")
}

function Set-CommandFlags([object[]]$argsList, [bool]$allowJson = $false) {
  foreach ($arg in @($argsList)) {
    switch ([string]$arg) {
      "-y" { $script:Yes = $true }
      "--yes" { $script:Yes = $true }
      "-q" { $script:Quiet = $true }
      "--quiet" { $script:Quiet = $true }
      "--json" {
        if (-not $allowJson) { Exit-Die "此命令不支持 --json" }
        $script:JsonOut = $true
      }
      "-h" { Show-Usage; exit 0 }
      "--help" { Show-Usage; exit 0 }
      default { Exit-Die "未知选项: $arg" }
    }
  }
}

function Add-ToUserPath([string]$dir) {
  $p = [Environment]::GetEnvironmentVariable("Path", "User")
  if (-not $p) { $p = "" }
  $parts = @($p -split ";")
  if ($parts -notcontains $dir) {
    $newPath = ($p.TrimEnd(";") + ";" + $dir)
    [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
    $m = [Environment]::GetEnvironmentVariable("Path", "Machine")
    if (-not $m) { $m = "" }
    $u = [Environment]::GetEnvironmentVariable("Path", "User")
    if (-not $u) { $u = "" }
    $env:Path = $m + ";" + $u
  }
}

function Get-ExeName([string]$base) {
  if ($script:IsWin) { return ($base + ".cmd") }
  return $base
}

function Get-Arch {
  $arch = $env:PROCESSOR_ARCHITECTURE
  if ($arch -eq "AMD64") { return "x64" }
  if ($arch -eq "ARM64") { return "arm64" }
  return "x64"
}

function ConvertTo-AbsolutePath([string]$path) {
  if ($path -eq "~") { $path = $HomeDir }
  elseif ($path.StartsWith("~/") -or $path.StartsWith("~\")) { $path = Join-Path $HomeDir $path.Substring(2) }
  if (-not [IO.Path]::IsPathRooted($path)) { $path = Join-Path (Get-Location).Path $path }
  return [IO.Path]::GetFullPath($path)
}

function Set-DshHome {
  if ([string]::IsNullOrWhiteSpace($script:DshHome)) { $script:DshHome = Join-Path $HomeDir ".dsh" }
  if ($script:DshHome -match "[\r\n]") { Exit-Die "DSH_HOME 不能包含换行符" }
  $script:DshHome = ConvertTo-AbsolutePath $script:DshHome
  $script:SkillDir = Join-Path $DshHome "skills/dsh-installer"
  $script:SkillMarker = Join-Path $SkillDir ".installed-by-dsh-installer"
  $env:DSH_HOME = $DshHome
}

function Test-SafeCleanupPath([string]$path) {
  $full = (ConvertTo-AbsolutePath $path).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
  $root = [IO.Path]::GetPathRoot((ConvertTo-AbsolutePath $path)).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
  if ($full -eq $root) { return $false }
  $protected = @($HomeDir, (Split-Path $PsScriptPath -Parent), "/usr", "/opt", "/etc", "/var", "/tmp", "/home", "/workspace")
  if ($script:IsWin) { $protected = @($HomeDir, (Split-Path $PsScriptPath -Parent), $env:SystemRoot, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData) }
  foreach ($item in $protected) {
    if (-not $item) { continue }
    $item = (ConvertTo-AbsolutePath $item).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    if (($full -eq $item) -or $item.StartsWith($full + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { return $false }
  }
  $current = ConvertTo-AbsolutePath $path
  while ($current) {
    if (Test-Path -LiteralPath $current) {
      $entry = Get-Item -LiteralPath $current -Force
      if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) { return $false }
    }
    $parent = Split-Path $current -Parent
    if ($parent -eq $current) { break }
    $current = $parent
  }
  return $true
}

function Assert-PurgeHome {
  if (-not (Test-SafeCleanupPath $DshHome)) { Exit-Die "拒绝删除不安全的数据路径: $DshHome" }
  if ((Test-Path -LiteralPath $DshHome) -and (Split-Path $DshHome -Leaf) -ne ".dsh" -and
      -not (Test-Path -LiteralPath (Join-Path $DshHome ".dsh-installer-home")) -and
      -not (Test-Path -LiteralPath (Join-Path $DshHome "profiles"))) {
    Exit-Die "自定义 DSH_HOME 缺少归属证据，保留: $DshHome"
  }
}

# ---------------------------------------------------------------- 配置
function Load-Config {
  if (Test-Path $ConfigFile) {
    $saved = Get-Content $ConfigFile -Raw | ConvertFrom-Json
    if (-not $script:Mode) { $script:Mode = $saved.mode }
    if ($saved.installDir) { $script:InstallDir = $saved.installDir }
    if ($saved.host) { $script:BindHost = $saved.host }
    if ($saved.port) { $script:Port = [int]$saved.port }
    if ($saved.registry) { $script:Registry = $saved.registry }
    if ($saved.nodeMajor) { $script:NodeMajor = $saved.nodeMajor }
    if ($saved.dshHome -and [string]::IsNullOrWhiteSpace($DshHomeOverride)) { $script:DshHome = $saved.dshHome }
  }
  Set-DshHome
  $privatePnpm = Join-Path $CfgDir "pnpm"
  if (Test-Path (Join-Path $privatePnpm ".installed-by-dsh-installer")) { $env:Path = $privatePnpm + [IO.Path]::PathSeparator + $env:Path }
}

function Save-Config {
  New-Item -ItemType Directory -Path $CfgDir -Force | Out-Null
  $cfg = [ordered]@{
    mode = $script:Mode
    installDir = $script:InstallDir
    host = $script:BindHost
    port = $script:Port
    registry = $script:Registry
    nodeMajor = $script:NodeMajor
    dshHome = $script:DshHome
  }
  $cfg | ConvertTo-Json | Set-Content -Path $ConfigFile -Encoding UTF8
}

# ---------------------------------------------------------------- 版本工具
function Get-NodeVersion {
  try {
    $v = (& node -v 2>$null | Select-Object -First 1)
    return $v.TrimStart("v")
  } catch { return "" }
}

function Test-NodeOk {
  $v = Get-NodeVersion
  if (-not $v) { return $false }
  $parts = $v.Split(".")
  if ($parts.Length -lt 2) { return $false }
  $major = 0; $minor = 0
  [int]::TryParse($parts[0], [ref]$major) | Out-Null
  [int]::TryParse($parts[1], [ref]$minor) | Out-Null
  if ($major -ge 24) { return $true }
  if ($major -eq 22 -and $minor -ge 19) { return $true }
  return $false
}

# ---------------------------------------------------------------- Node 安装
function Install-NodeViaWinget {
  if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { return $false }
  Write-Info "通过 winget 安装 Node.js LTS ..."
  & winget install --id OpenJS.NodeJS.LTS -e --silent --accept-package-agreements --accept-source-agreements
  if ($LASTEXITCODE -ne 0) { return $false }
  # 刷新当前进程 PATH（安装器新写入的 PATH 不会自动生效）
  $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
  return $true
}

function Install-NodeViaZip {
  Write-Step "下载 Node.js v$NodeMajor（用户级，无需管理员）"
  $wc = New-Object System.Net.WebClient
  $html = $wc.DownloadString("https://nodejs.org/dist/latest-v$NodeMajor.x/")
  $arch = Get-Arch
  $file = ($html -split '"' | Where-Object { $_ -like "node-v$NodeMajor.*-win-$arch.zip" } | Select-Object -First 1)
  if (-not $file) { Exit-Die "无法解析 Node.js 最新版本（检查网络）" }
  $ver = $file.Replace("node-v", "").Replace("-win-$arch.zip", "")
  $url = "https://nodejs.org/dist/v$ver/$file"
  Write-Info "下载 $url"
  $zip = Join-Path $env:TEMP $file
  $wc.DownloadFile($url, $zip)
  New-Item -ItemType Directory -Path $CfgDir -Force | Out-Null
  # 仅当旧目录带有本工具 marker 时才删除（防止误删用户同名目录）
  if ((Test-Path $NodeDir) -and (Test-Path (Join-Path $NodeDir ".installed-by-dsh-installer"))) {
    Remove-Item $NodeDir -Recurse -Force
  } elseif (Test-Path $NodeDir) {
    Exit-Die "检测到已存在的非本安装器 Node 目录: $NodeDir，拒绝覆盖"
  }
  Expand-Archive -Path $zip -DestinationPath $CfgDir -Force
  $extracted = Join-Path $CfgDir $file.Replace(".zip", "")
  Rename-Item -LiteralPath $extracted -NewName "node"
  Remove-Item $zip -Force -ErrorAction SilentlyContinue
  New-Item -ItemType File -Path (Join-Path $NodeDir ".installed-by-dsh-installer") -Force | Out-Null
  Add-ToUserPath $NodeDir
  $env:Path = $NodeDir + ";" + $env:Path
  Write-Ok "Node.js v$ver 已安装到 $NodeDir"
}

function Ensure-Node {
  if (Test-NodeOk) {
    Write-Info "Node.js v$(Get-NodeVersion) 已满足要求（>=22.19 或 >=24）"
    return
  }
  if (Get-Command node -ErrorAction SilentlyContinue) {
    Write-Warn "当前 Node.js v$(Get-NodeVersion) 不满足要求（需要 ^22.19.0 或 >=24.0.0）"
  } else {
    Write-Warn "未检测到 Node.js"
  }
  if (-not (Confirm-Action "是否自动安装 Node.js v$NodeMajor？" $true)) {
    Exit-Die "请先手动安装 Node.js >= 24（或 22.19+）: https://nodejs.org/"
  }
  Install-NodeViaZip
  if (-not (Test-NodeOk)) { Exit-Die "Node.js 安装后仍不可用" }
}

# ---------------------------------------------------------------- pnpm / git
function Ensure-Pnpm {
  $prefix = Join-Path $CfgDir "pnpm"
  if (Test-Path (Join-Path $prefix ".installed-by-dsh-installer")) { $env:Path = $prefix + [IO.Path]::PathSeparator + $env:Path }
  if (Get-Command pnpm -ErrorAction SilentlyContinue) {
    Write-Info "pnpm 已就绪"
    return $true
  }
  if ((Test-Path $prefix) -and -not (Test-Path (Join-Path $prefix ".installed-by-dsh-installer"))) { Exit-Die "pnpm 目录不属于本安装器: $prefix" }
  New-Item -ItemType Directory -Path $prefix -Force | Out-Null
  New-Item -ItemType File -Path (Join-Path $prefix ".installed-by-dsh-installer") -Force | Out-Null
  Write-Info "安装 pnpm@$PnpmVersion 到 $prefix ..."
  & npm install --global --prefix $prefix "pnpm@$PnpmVersion"
  if ($LASTEXITCODE -ne 0) { return $false }
  $env:Path = $prefix + [IO.Path]::PathSeparator + $env:Path
  return [bool](Get-Command pnpm -ErrorAction SilentlyContinue)
}

function Ensure-Git {
  if (Get-Command git -ErrorAction SilentlyContinue) { return $true }
  Write-Warn "未检测到 git（源码安装需要）"
  if (Get-Command winget -ErrorAction SilentlyContinue) {
    if (Confirm-Action "通过 winget 安装 Git？" $true) {
      & winget install --id Git.Git -e --silent --accept-package-agreements --accept-source-agreements
      $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
      if (Get-Command git -ErrorAction SilentlyContinue) { return $true }
    }
  }
  Write-Warn "请手动安装 git: https://git-scm.com/download/win"
  Exit-Die "git 不可用，无法进行源码安装"
}

# ---------------------------------------------------------------- 服务管理
function Test-Port([int]$port) {
  $tcp = New-Object System.Net.Sockets.TcpClient
  try {
    $ar = $tcp.BeginConnect("127.0.0.1", $port, $null, $null)
    if ($ar.AsyncWaitHandle.WaitOne(2000)) { $tcp.EndConnect($ar); return $true }
    return $false
  } catch { return $false }
  finally { $tcp.Close() }
}

function Get-WebUrl { return ("http://" + $BindHost + ":" + $Port) }

# 读取 PID 文件信息。旧版纯数字 PID 仅用于诊断，绝不用于击杀进程。
function Get-PidInfo {
  if (-not (Test-Path $PidFile)) { return $null }
  $raw = Get-Content $PidFile -Raw -ErrorAction SilentlyContinue
  if (-not $raw) { return $null }
  $info = $null
  try { $info = $raw | ConvertFrom-Json } catch { }
  if ($info -and $info.pid) { return $info }
  $num = 0
  if ([int]::TryParse($raw.Trim(), [ref]$num)) { return [ordered]@{ pid = $num; legacy = $true } }
  return $null
}

# 身份校验后的本工具进程；无法确认时返回 $null（原因见 $script:IdentityStatus）
function Get-OwnProcess {
  $script:IdentityStatus = "not-running"
  $info = Get-PidInfo
  if (-not $info) { return $null }
  if (-not $info.start -or -not $info.script) {
    $script:IdentityStatus = "unverifiable"
    return $null
  }
  $proc = Get-Process -Id ([int]$info.pid) -ErrorAction SilentlyContinue
  if (-not $proc) { return $null }
  try {
    if ($proc.StartTime.ToString("o") -ne $info.start) {
      $script:IdentityStatus = "mismatch"
      return $null
    }
  } catch { }
  if ($script:IsWin) {
    try {
      $cim = Get-CimInstance Win32_Process -Filter ("ProcessId = " + [int]$info.pid) -ErrorAction SilentlyContinue
      if (-not $cim) { $script:IdentityStatus = "unverifiable"; return $null }
      if ($cim.CommandLine -notlike ("*" + $info.script + "*")) {
        $script:IdentityStatus = "mismatch"
        return $null
      }
    } catch { $script:IdentityStatus = "unverifiable"; return $null }
  }
  return $proc
}

# 只有通过身份校验的进程才视为本工具正在运行。
function Test-Running {
  return ($null -ne (Get-OwnProcess))
}

# 参数校验：host/port/registry 白名单与格式约束
function Test-ValidConfig {
  if (($BindHost -ne "127.0.0.1") -and ($BindHost -ne "0.0.0.0")) {
    Exit-Die "无效 host: $BindHost（仅支持 127.0.0.1 或 0.0.0.0）"
  }
  if (($Port -lt 1) -or ($Port -gt 65535)) {
    Exit-Die "端口需在 1-65535 之间（不接受 0）"
  }
  if ($Registry) {
    if ($Registry -notmatch "^https?://") {
      Exit-Die "无效 registry: 需以 http:// 或 https:// 开头"
    }
    if ($Registry -match '[\s"&|<>^]') {
      Exit-Die "registry 含非法字符"
    }
  }
  if ($script:CloneUrl -and ($script:CloneUrl -match '[\s"]')) {
    Exit-Die "clone-url 含非法字符"
  }
  if ($BindHost -eq "0.0.0.0") {
    if (-not (Confirm-Action "警告：绑定 0.0.0.0 会把 Web UI 暴露到局域网（当前无 TLS；最新版使用进程访问令牌，请妥善保管启动日志）。仍要继续？" $false)) {
      Exit-Die "已取消（改用默认 127.0.0.1 即可）"
    }
  }
}

function Write-CmdScript([string]$path, [object]$lines) {
  $encoding = New-Object System.Text.UTF8Encoding($false)
  [IO.File]::WriteAllLines($path, [string[]]@($lines), $encoding)
}

function Write-RunScript {
  New-Item -ItemType Directory -Path $CfgDir -Force | Out-Null
  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add("@echo off")
  $lines.Add("rem Generated by $AppName $AppVersion")
  $lines.Add("chcp 65001 >nul")
  $lines.Add("setlocal DisableDelayedExpansion")
  $lines.Add('set "DSH_HOME=' + $DshHome.Replace('%', '%%') + '"')
  $lines.Add('set "PATH=' + (Join-Path $CfgDir 'pnpm').Replace('%', '%%') + ';%PATH%"')
  if ($Mode -eq "source") {
    $lines.Add('cd /d "' + $InstallDir.Replace('%', '%%') + '"')
  } else {
    $lines.Add('cd /d "%USERPROFILE%"')
  }
  if ($Registry) { $lines.Add('set "NPM_CONFIG_REGISTRY=' + $Registry + '"') }
  if ($Mode -eq "source") {
    $lines.Add("call pnpm.cmd dsh web --host $BindHost --port $Port --no-open")
  } else {
    $lines.Add("call npx.cmd --yes $NpxPkg web --host $BindHost --port $Port --no-open")
  }
  Write-CmdScript $RunScript $lines
}

function Start-Web {
  Load-Config
  if (-not $script:Mode) { $script:Mode = "npx" }
  Test-ValidConfig
  if ($Mode -eq "source" -and -not (Test-Path $InstallDir)) {
    Exit-Die "未找到源码目录 $InstallDir，请先执行: install.ps1 install -y --mode source"
  }
  if (Test-Running) {
    Write-Info "Web UI 已在运行: $(Get-WebUrl)"
    if ($script:JsonOut) { [ordered]@{ running = $true; url = (Get-WebUrl) } | ConvertTo-Json -Compress }
    return
  }
  if (Test-Port $Port) {
    Exit-Die "端口 $Port 已被其他程序占用（非本工具管理的进程），请更换端口或自行处理"
  }
  Write-RunScript
  Write-Info "后台启动 Web UI ..."
  Remove-Item $LogFile, $ErrLogFile -Force -ErrorAction SilentlyContinue
  $arg = '"' + $RunScript + '"'
  $p = Start-Process -FilePath "cmd.exe" -ArgumentList @("/c", $arg) -WindowStyle Hidden -RedirectStandardOutput $LogFile -RedirectStandardError $ErrLogFile -PassThru
  $startStr = ""
  try {
    $proc2 = Get-Process -Id $p.Id -ErrorAction SilentlyContinue
    if ($proc2) { $startStr = $proc2.StartTime.ToString("o") }
  } catch { }
  [ordered]@{ pid = $p.Id; start = $startStr; script = $RunScript } | ConvertTo-Json -Compress | Set-Content -Path $PidFile
  for ($i = 0; $i -lt 60; $i++) {
    if (Test-Port $Port) { break }
    if (-not (Get-Process -Id $p.Id -ErrorAction SilentlyContinue)) { break }
    Start-Sleep -Seconds 1
  }
  if ((Test-Running) -and (Test-Port $Port)) {
    Write-Ok "Web UI 已启动: $(Get-WebUrl)  (PID $($p.Id))"
    if ($script:JsonOut) {
      [ordered]@{ running = $true; url = (Get-WebUrl); pid = $p.Id } | ConvertTo-Json -Compress
    }
    return
  }
  Write-Err "启动失败，最近日志:"
  Get-Content $LogFile -Tail 10 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "    $_" }
  Get-Content $ErrLogFile -Tail 10 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "    $_" }
  Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
  exit 1
}

function Stop-Web {
  Load-Config
  if (-not $script:Mode) { $script:Mode = "npx" }
  $own = Get-OwnProcess
  if (-not $own) {
    if ($script:IdentityStatus -eq "mismatch") {
      Write-Err "PID 文件与当前进程身份不符（PID 可能被复用），拒绝击杀"
      Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
      return 1
    }
    if ($script:IdentityStatus -eq "unverifiable") {
      Write-Err "无法验证进程身份，拒绝击杀以免误伤：请手动确认后自行停止"
      return 1
    }
    Write-Info "未找到本工具管理的 Web UI 进程"
    if (Test-Port $Port) {
      Write-Warn "端口 $Port 被其他程序占用，本工具不做处理（如确属 dsh 请手动停止）"
    }
    if ($script:JsonOut) { [Console]::Out.WriteLine(([ordered]@{ running = $false } | ConvertTo-Json -Compress)) }
    return 2
  }
  Write-Info "停止 Web UI ..."
  # 整体 try/catch：任何一步失败都不能中断调用方（卸载等流程继续走）
  try {
    if ($script:IsWin) {
      & taskkill /PID $own.Id /T /F 2>$null | Out-Null
    } else {
      Stop-Process -Id $own.Id -Force -ErrorAction SilentlyContinue
    }
  } catch { }
  for ($i = 0; $i -lt 10; $i++) {
    if (-not (Get-Process -Id $own.Id -ErrorAction SilentlyContinue)) { break }
    Start-Sleep -Milliseconds 500
  }
  Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
  if (Get-Process -Id $own.Id -ErrorAction SilentlyContinue) {
    Write-Err "停止失败，进程 $($own.Id) 仍在运行"
    return 1
  }
  Write-Ok "Web UI 已停止"
  if ($script:JsonOut) { [Console]::Out.WriteLine(([ordered]@{ running = $false } | ConvertTo-Json -Compress)) }
  return 0
}

function Restart-Web {
  $stopResult = Stop-Web
  if ($stopResult -eq 1) { return 1 }
  Start-Web
}

# 安装锚点：配置文件存在（记录过一次安装），源码模式还需仓库标记在
function Test-Installed {
  if (-not (Test-Path $ConfigFile)) { return $false }
  if ($Mode -eq "source") { return (Test-RepoMarker $InstallDir) }
  return $true
}

function Get-Status {
  Load-Config
  if (-not $script:Mode) { $script:Mode = "npx" }
  $installed = Test-Installed
  $running = Test-Running
  $pidVal = $null
  $info = Get-PidInfo
  if ($info) { $pidVal = $info.pid }
  if ($script:JsonOut) {
    $o = [ordered]@{
      installed = $installed
      running = $running
      mode = $Mode
      host = $BindHost
      port = $Port
      url = (Get-WebUrl)
      pid = $pidVal
    }
    # 直写 stdout：避免调用方赋值捕获管道输出导致 JSON 丢失
    [Console]::Out.WriteLine(($o | ConvertTo-Json -Compress))
    return $installed
  }
  Write-Host "DeepSeek Harness 状态"
  Write-Host ("  安装状态 : " + $(if ($installed) { "已安装" } else { "未安装" }))
  Write-Host "  安装模式 : $Mode"
  Write-Host "  访问地址 : $(Get-WebUrl)"
  Write-Host "  日志文件 : $LogFile"
  if ($running) {
    Write-Host "  运行状态 : 运行中 (PID $pidVal)" -ForegroundColor Green
  } else {
    Write-Host "  运行状态 : 未运行" -ForegroundColor Yellow
    if (Test-Port $Port) { Write-Warn "注意: 端口 $Port 被其他程序占用（非本工具管理）" }
  }
  return $installed
}

function Show-Logs([object[]]$argsList = $null) {
  if ($null -eq $argsList) { $argsList = @($RestArgs) }
  $follow = $false; $lines = 50
  for ($i = 0; $i -lt $argsList.Count; $i++) {
    switch ([string]$argsList[$i]) {
      "-f" { $follow = $true }
      "--follow" { $follow = $true }
      "-n" { if ($argsList[$i + 1]) { $lines = [int]$argsList[$i + 1]; $i++ } }
      "--lines" { if ($argsList[$i + 1]) { $lines = [int]$argsList[$i + 1]; $i++ } }
    }
  }
  if (-not (Test-Path $LogFile)) { Exit-Die "日志文件不存在（尚未启动过）: $LogFile" }
  if ($follow) { Get-Content $LogFile -Tail $lines -Wait }
  else { Get-Content $LogFile -Tail $lines }
}

function Open-Web {
  Load-Config
  $url = Get-WebUrl
  if ((Test-Running) -and (Test-Path -LiteralPath $LogFile)) {
    $pattern = '^dsh web: (http://127\.0\.0\.1:' + $Port + '/\?token=[A-Za-z0-9_-]+)$'
    $match = Get-Content -LiteralPath $LogFile | Select-String -Pattern $pattern | Select-Object -Last 1
    if ($match) { $url = $match.Matches[0].Groups[1].Value }
  }
  Start-Process $url
}

# ---------------------------------------------------------------- 安装
function Test-RepoMarker([string]$dir) {
  $pkg = Join-Path $dir "package.json"
  if (-not (Test-Path $pkg)) { return $false }
  $content = Get-Content $pkg -Raw
  return ($content -match '"name"\s*:\s*"@deepseek-ai/dsh-root"')
}

function Install-Npx {
  Write-Step "npx 快捷安装（预取官方发布包）"
  $out = ""
  $oldReg = $env:NPM_CONFIG_REGISTRY
  if ($script:Registry) { $env:NPM_CONFIG_REGISTRY = $script:Registry }
  try {
    Push-Location $HomeDir
    try {
      $out = (& (Get-ExeName "npx") --yes $NpxPkg --version 2>&1 | Out-String)
    } finally { Pop-Location }
  } finally {
    if ($oldReg) { $env:NPM_CONFIG_REGISTRY = $oldReg }
    else { Remove-Item Env:NPM_CONFIG_REGISTRY -ErrorAction SilentlyContinue }
  }
  if ($LASTEXITCODE -ne 0) {
    $out2 = (& (Get-ExeName "npx") --yes $NpxPkg --help 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) {
      Write-Err $out2
      Exit-Die "npx 安装失败，请检查网络（国内可加 --registry https://registry.npmmirror.com 重试）"
    }
    Write-Info "dsh CLI 可用"
  } else {
    $verLine = (($out -split "\r?\n") | Where-Object { $_ -and ($_ -notmatch "^npm notice") } | Select-Object -Last 1)
    Write-Info "dsh 版本: $verLine"
  }
  Write-Ok "npx 模式安装完成（每次启动自动使用最新发布版）"
}

function Install-Source {
  Write-Step "源码安装"
  $script:InstallDir = ConvertTo-AbsolutePath $script:InstallDir
  $repoUrl = $script:CloneUrl
  if (-not $repoUrl) { $repoUrl = $GithubRepo }
  $gitDir = Join-Path $InstallDir ".git"
  $clonedByInstaller = $false
  if ((Test-Path $gitDir) -and (Test-RepoMarker $InstallDir)) {
    Write-Info "检测到现有仓库 $InstallDir，执行 git pull 更新"
    & git -C $InstallDir pull --ff-only
    if ($LASTEXITCODE -ne 0) { Write-Warn "git pull 失败，继续使用现有代码" }
  } elseif ((Test-Path $InstallDir) -and (Get-ChildItem $InstallDir -Force | Select-Object -First 1)) {
    Exit-Die "目录 $InstallDir 已存在且不是 DeepSeek Harness 仓库，请换用 --dir 指定其他目录"
  } else {
    Write-Info "克隆 $repoUrl → $InstallDir"
    & git clone --depth 1 $repoUrl $InstallDir
    if ($LASTEXITCODE -ne 0) { Exit-Die "克隆失败（可加 --clone-url 指定镜像地址）" }
    $clonedByInstaller = $true
  }
  if ($clonedByInstaller) {
    New-Item -ItemType File -Path (Join-Path $InstallDir $script:SourceMarkerName) -Force | Out-Null
  }
  Write-Info "安装依赖 pnpm install（首次约需几分钟）..."
  $oldReg = $env:NPM_CONFIG_REGISTRY
  if ($script:Registry) { $env:NPM_CONFIG_REGISTRY = $script:Registry }
  try {
    Push-Location $InstallDir
    try {
      & (Get-ExeName "pnpm") install
      if ($LASTEXITCODE -ne 0) { Exit-Die "pnpm install 失败" }
      Write-Info "构建 pnpm run build ..."
      & (Get-ExeName "pnpm") run build
      if ($LASTEXITCODE -ne 0) { Exit-Die "pnpm run build 失败" }
    } finally { Pop-Location }
  } finally {
    if ($oldReg) { $env:NPM_CONFIG_REGISTRY = $oldReg }
    else { Remove-Item Env:NPM_CONFIG_REGISTRY -ErrorAction SilentlyContinue }
  }
  Write-Ok "源码安装完成: $InstallDir"
}

function Show-InstallHelp {
  @"
用法: install.ps1 install [选项]

  -m, --mode npx|source   安装方式: npx 快捷（默认）/ source 源码
  -d, --dir <路径>        源码模式的安装目录（默认 ~/deepseek-harness）
  -p, --port <端口>       Web UI 端口（默认 3080）
  -H, --host <地址>       绑定地址（默认 127.0.0.1）
  --registry <URL>        npm 镜像（国内网络可加 https://registry.npmmirror.com）
  --clone-url <URL>       git 克隆地址（默认官方 GitHub 仓库，可用镜像替代）
  --api-key <密钥>        写入 DEEPSEEK_API_KEY 到 ~/.dsh/.env
  --node-version <主版本> 自动安装的 Node 主版本（默认 24）
  --no-start              安装后不启动
  注：Skill 默认不会注册；需要时显式执行 install.ps1 skill（实验性，未经完整测试）
  -y, --yes               非交互模式
  -q, --quiet             只输出错误
"@
}

function Invoke-Install([object[]]$argsList = $null) {
  if ($null -eq $argsList) { $argsList = @($RestArgs) }
  # ---- 解析参数 ----
  $argMode = ""; $argDir = ""; $argPort = ""; $argHost = ""; $argRegistry = ""
  $argKey = ""; $argNode = ""; $argClone = ""
  for ($i = 0; $i -lt $argsList.Count; $i++) {
    $a = [string]$argsList[$i]
    $val = ""
    if ($i + 1 -lt $argsList.Count) { $val = [string]$argsList[$i + 1] }
    switch -Regex ($a) {
      "^(-m|--mode)$" { $argMode = $val; $i++ }
      "^--mode=" { $argMode = $a.Substring(7) }
      "^(-d|--dir)$" { $argDir = $val; $i++ }
      "^--dir=" { $argDir = $a.Substring(6) }
      "^(-p|--port)$" { $argPort = $val; $i++ }
      "^--port=" { $argPort = $a.Substring(7) }
      "^(-H|--host)$" { $argHost = $val; $i++ }
      "^--host=" { $argHost = $a.Substring(7) }
      "^--registry$" { $argRegistry = $val; $i++ }
      "^--registry=" { $argRegistry = $a.Substring(11) }
      "^--api-key$" { $argKey = $val; $i++ }
      "^--api-key=" { $argKey = $a.Substring(10) }
      "^--node-version$" { $argNode = $val; $i++ }
      "^--node-version=" { $argNode = $a.Substring(15) }
      "^--clone-url$" { $argClone = $val; $i++ }
      "^--clone-url=" { $argClone = $a.Substring(12) }
      "^(-y|--yes)$" { $script:Yes = $true }
      "^--no-start$" { $script:NoStart = $true }
      "^--no-skill$" { Write-Warn "Skill 默认不会注册，--no-skill 已无需要" }
      "^(-q|--quiet)$" { $script:Quiet = $true }
      "^(-h|--help)$" { Show-InstallHelp; exit 0 }
      default { Exit-Die "未知选项: $a（查看帮助: install.ps1 install --help）" }
    }
  }
  Load-Config
  if ($argMode) { $script:Mode = $argMode }
  if ($argDir) { $script:InstallDir = $argDir }
  if ($argPort) { $script:Port = [int]$argPort }
  if ($argHost) { $script:BindHost = $argHost }
  if ($argRegistry) { $script:Registry = $argRegistry }
  if ($argKey) { $script:ApiKey = $argKey }
  if ($argNode) { $script:NodeMajor = $argNode }
  if ($argClone) { $script:CloneUrl = $argClone }

  Write-Host ""
  Write-Host "  DeepSeek Harness 多平台安装器 v$AppVersion (windows/$(Get-Arch))" -ForegroundColor Blue

  if (-not $script:Mode) {
    if ($script:Yes -or -not [Environment]::UserInteractive) {
      $script:Mode = "npx"
    } else {
      Write-Host ""
      Write-Host "请选择安装方式:"
      Write-Host "  [1] npx 快捷安装（推荐）— 运行 npm 官方发布包，启动快、自动获取更新"
      Write-Host "  [2] 源码安装 — git clone 官方仓库并本地构建，适合读改源码"
      $choice = Read-Host "请输入 1 或 2 [1]"
      if (-not $choice) { $choice = "1" }
      if ($choice -eq "1") { $script:Mode = "npx" }
      elseif ($choice -eq "2") { $script:Mode = "source" }
      else { Exit-Die "无效选择: $choice" }
    }
  }
  if (($Mode -ne "npx") -and ($Mode -ne "source")) { Exit-Die "无效模式 $Mode（可选 npx | source）" }

  Test-ValidConfig
  Write-Info "安装模式: $Mode"
  Ensure-Node
  if ($Mode -eq "source") {
    Ensure-Git | Out-Null
    if (-not (Ensure-Pnpm)) { Exit-Die "pnpm 不可用（源码模式需要）" }
  }
  # npx 模式不强制安装 pnpm（仅插件管理需要，届时按需安装）

  if ($Mode -eq "npx") { Install-Npx } else { Install-Source }

  if ($script:ApiKey) {
    New-Item -ItemType Directory -Path $DshHome -Force | Out-Null
    $envFile = Join-Path $DshHome ".env"
    $lines = New-Object System.Collections.Generic.List[string]
    if (Test-Path $envFile) {
      $found = $false
      foreach ($ln in (Get-Content $envFile)) {
        if ($ln -match "^DEEPSEEK_API_KEY=") { $lines.Add("DEEPSEEK_API_KEY=$ApiKey"); $found = $true }
        else { $lines.Add($ln) }
      }
      if (-not $found) { $lines.Add("DEEPSEEK_API_KEY=$ApiKey") }
    } else {
      $lines.Add("DEEPSEEK_API_KEY=$ApiKey")
    }
    Set-Content -Path $envFile -Value $lines -Encoding ASCII
    Write-Ok "API Key 已写入 $envFile（也可稍后在 Web UI 设置页配置）"
  }

  if (Test-SafeCleanupPath $DshHome) {
    New-Item -ItemType Directory -Path $DshHome -Force | Out-Null
    New-Item -ItemType File -Path (Join-Path $DshHome ".dsh-installer-home") -Force | Out-Null
  }
  Write-Launcher
  Save-Config

  Write-Host ""
  Write-Ok "安装完成！"
  Write-Info "可选功能：如需注册 dsh-installer Skill，请显式执行 install.ps1 skill（实验性，未经完整测试）"
  Write-Host "  启动 Web UI : $(Get-WebUrl)"
  Write-Host "  下次启动    : dsh-web  或  install.ps1 start"
  Write-Host "  插件管理    : install.ps1 plugin add <包名|github:用户/仓库|./路径>"
  Write-Host "  卸载        : install.ps1 uninstall"

  if (-not $script:NoStart) {
    if (Confirm-Action "立即启动 Web UI？" $true) { Start-Web }
  }
}

function Write-Launcher {
  New-Item -ItemType Directory -Path $BinDir -Force | Out-Null
  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add("@echo off")
  $lines.Add("rem Generated by $AppName $AppVersion")
  $lines.Add("chcp 65001 >nul")
  $lines.Add("setlocal DisableDelayedExpansion")
  $lines.Add('set "DSH_HOME=' + $DshHome.Replace('%', '%%') + '"')
  $lines.Add('set "PATH=' + (Join-Path $CfgDir 'pnpm').Replace('%', '%%') + ';%PATH%"')
  if ($Mode -eq "source") {
    $lines.Add('cd /d "' + $InstallDir.Replace('%', '%%') + '"')
    $lines.Add("call pnpm.cmd dsh web --host $BindHost --port $Port")
  } else {
    $lines.Add('cd /d "%USERPROFILE%"')
    if ($Registry) { $lines.Add('set "NPM_CONFIG_REGISTRY=' + $Registry + '"') }
    $lines.Add("call npx.cmd --yes $NpxPkg web --host $BindHost --port $Port")
  }
  Write-CmdScript $Launcher $lines
  $cliLines = @("@echo off", "rem Generated by $AppName $AppVersion", "chcp 65001 >nul", "setlocal DisableDelayedExpansion", 'powershell -NoProfile -ExecutionPolicy Bypass -File "' + $PsScriptPath.Replace("%", "%%") + '" %*')
  Write-CmdScript $CliLink $cliLines
  # 把 BinDir 写入用户 PATH（当前进程同步生效）
  Add-ToUserPath $BinDir
  Write-Info ("已注册命令目录: " + $BinDir + "（新开终端后 dsh-web / dsh-installer 可直接使用）")
}

# ---------------------------------------------------------------- 插件管理
function Invoke-Plugin([object[]]$cliArgs = $null) {
  if ($null -eq $cliArgs) { $cliArgs = @($RestArgs) }
  Load-Config
  if (-not $script:Mode) { $script:Mode = "npx" }
  $profile = $WebProfile
  $action = ""
  $argsList = New-Object System.Collections.Generic.List[string]
  for ($i = 0; $i -lt $cliArgs.Count; $i++) {
    $a = [string]$cliArgs[$i]
    if ($a -eq "--json") { $script:JsonOut = $true; continue }
    if ($a -eq "--profile") { if ($cliArgs[$i + 1]) { $profile = [string]$cliArgs[$i + 1]; $i++ }; continue }
    if ($a -like "--profile=*") { $profile = $a.Substring(10); continue }
    if (($a -eq "-y") -or ($a -eq "--yes")) { $script:Yes = $true; continue }
    if (($a -eq "-q") -or ($a -eq "--quiet")) { $script:Quiet = $true; continue }
    if (-not $action) { $action = $a }
    else { $argsList.Add($a) }
  }
  if (-not $action) { $action = "list" }
  switch -Regex ($action) {
    "^(add|install|i)$" { return (Run-PluginCmd $profile "add" $argsList) }
    "^(remove|rm|uninstall|del)$" { return (Run-PluginCmd $profile "remove" $argsList) }
    "^(update|upgrade|up)$" { return (Run-PluginCmd $profile "update" $argsList) }
    "^(list|ls)$" {
      if ($script:JsonOut) { Get-PluginListJson $profile }
      else { Get-PluginListText $profile }
    }
    "^(search|s)$" { return (Search-Plugin $argsList) }
    default { Write-Err "用法: install.ps1 plugin <add|remove|update|list|search> [参数]"; return 1 }
  }
}

function Run-PluginCmd([string]$profile, [string]$pnpmAction, $argsList) {
  if (-not (Get-Command pnpm -ErrorAction SilentlyContinue)) {
    Write-Warn "插件管理需要 pnpm，尝试安装 ..."
    if (-not (Ensure-Pnpm)) { Write-Err "pnpm 不可用"; return 1 }
  }
  $oldReg = $env:NPM_CONFIG_REGISTRY
  if ($script:Registry) { $env:NPM_CONFIG_REGISTRY = $script:Registry }
  $rc = 0
  try {
    if ($Mode -eq "source") {
      Push-Location $InstallDir
      try {
        $all = @("dsh", "plugin", "--profile", $profile, $pnpmAction) + @($argsList)
        & (Get-ExeName "pnpm") @all | Out-Host
        $rc = $LASTEXITCODE
      } finally { Pop-Location }
    } else {
      Push-Location $HomeDir
      try {
        $all = @("--yes", $NpxPkg, "plugin", "--profile", $profile, $pnpmAction) + @($argsList)
        & (Get-ExeName "npx") @all | Out-Host
        $rc = $LASTEXITCODE
      } finally { Pop-Location }
    }
  } finally {
    if ($oldReg) { $env:NPM_CONFIG_REGISTRY = $oldReg }
    else { Remove-Item Env:NPM_CONFIG_REGISTRY -ErrorAction SilentlyContinue }
  }
  if ($rc -ne 0) {
    Write-Warn "pnpm 拒绝了本次操作（可能是依赖的构建脚本需审批——安全闸门，不做全局放松）"
    Write-Warn "  交互终端中可直接按 pnpm 提示批准；或手动执行:"
    Write-Warn ("  dsh plugin --profile " + $profile + " approve-builds")
  }
  return $rc
}

function Get-PluginData([string]$profile) {
  $dir = Join-Path $DshHome ("profiles/" + $profile)
  $pkgFile = Join-Path $dir "package.json"
  $plugins = @(); $bundles = @()
  if (Test-Path $pkgFile) {
    $p = Get-Content $pkgFile -Raw | ConvertFrom-Json
    if ($p.dependencies) {
      foreach ($prop in $p.dependencies.PSObject.Properties) {
        $plugins += [ordered]@{ name = $prop.Name; version = [string]$prop.Value }
      }
    }
    if ($p.dsh.profile.bundles) { $bundles = @($p.dsh.profile.bundles) }
  }
  return @{ plugins = $plugins; bundles = $bundles }
}

function Get-PluginListJson([string]$profile) {
  $d = Get-PluginData $profile
  [ordered]@{ profile = $profile; plugins = $d.plugins; bundles = $d.bundles } | ConvertTo-Json -Depth 4
}

function Get-PluginListText([string]$profile) {
  $d = Get-PluginData $profile
  Write-Host "Profile: $profile"
  Write-Host "  插件:"
  if ($d.plugins.Count -eq 0) { Write-Host "    (无)" }
  foreach ($x in $d.plugins) { Write-Host ("    - " + $x.name + "@" + $x.version) }
  Write-Host "  激活的组合包(bundles):"
  if ($d.bundles.Count -eq 0) { Write-Host "    (无)" }
  foreach ($b in $d.bundles) { Write-Host ("    - " + $b) }
}

function Search-Plugin($argsList) {
  $kw = "dsh-plugin"
  if ($argsList.Count -gt 0) { $kw = [string]$argsList[0] }
  $oldReg = $env:NPM_CONFIG_REGISTRY
  if ($script:Registry) { $env:NPM_CONFIG_REGISTRY = $script:Registry }
  try {
    $raw = (& npm search --json $kw 2>$null | Out-String)
  } finally {
    if ($oldReg) { $env:NPM_CONFIG_REGISTRY = $oldReg }
    else { Remove-Item Env:NPM_CONFIG_REGISTRY -ErrorAction SilentlyContinue }
  }
  if (-not $raw.Trim()) { Exit-Die "插件搜索失败（检查网络或 npm registry）" }
  try { $items = @($raw | ConvertFrom-Json) } catch { Write-Host $raw; return 0 }
  $top = @($items | Select-Object -First 30)
  if ($script:JsonOut) {
    $out = @()
    foreach ($p in $top) { $out += [ordered]@{ name = $p.name; version = $p.version; description = $p.description } }
    $out | ConvertTo-Json -Depth 4
    return
  }
  if ($top.Count -eq 0) { Write-Host "  未找到相关插件" }
  foreach ($p in $top) {
    Write-Host ("  " + $p.name + "@" + $p.version)
    Write-Host ("    " + $p.description)
  }
}

# ---------------------------------------------------------------- npx 缓存
function Get-NpxCacheDir {
  # 以 npm 实际配置的缓存目录为准（用户可能自定义过 cache 路径）
  try {
    $c = (& npm config get cache 2>$null | Select-Object -First 1)
    if ($c -and $c.Trim()) { return (Join-Path $c.Trim() "_npx") }
  } catch { }
  return (Join-Path $LocalAppData "npm-cache/_npx")
}

function Clear-NpxCache {
  $npxCache = Get-NpxCacheDir
  if (-not (Test-Path -LiteralPath $npxCache)) { return }
  Get-ChildItem -LiteralPath $npxCache -Directory -ErrorAction Stop | ForEach-Object {
    $manifest = Join-Path $_.FullName "node_modules/@deepseek-ai/dsh/package.json"
    if (Test-Path -LiteralPath $manifest) {
      try { $pkg = Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json } catch { return }
      if ($pkg.name -eq $NpxPkg) { Remove-CleanupItem $_.FullName $true }
    }
  }
}

# 纯只读扫描：其他方式安装的 dsh 全局包（npm/pnpm 全局、nvm/fnm/volta 各 Node 版本）
function Find-ExternalPkgs {
  $found = New-Object System.Collections.Generic.List[string]
  try {
    $root = (& npm root -g 2>$null | Select-Object -First 1)
    if ($root -and $root.Trim()) {
      $p = Join-Path $root.Trim() "@deepseek-ai/dsh"
      if (Test-Path $p) { $found.Add($p) }
    }
  } catch { }
  try {
    $proot = (& pnpm root -g 2>$null | Select-Object -First 1)
    if ($proot -and $proot.Trim()) {
      $p = Join-Path $proot.Trim() "@deepseek-ai/dsh"
      if (Test-Path $p) { $found.Add($p) }
    }
  } catch { }
  # 版本管理器 / 常见全局目录
  $bases = New-Object System.Collections.Generic.List[string]
  if ($env:NVM_HOME) { $bases.Add($env:NVM_HOME) }
  if ($env:APPDATA) { $bases.Add((Join-Path $env:APPDATA "npm/node_modules")) }
  if ($env:ProgramFiles) { $bases.Add((Join-Path $env:ProgramFiles "nodejs/node_modules")) }
  $bases.Add((Join-Path $HomeDir ".nvm/versions/node"))
  $bases.Add((Join-Path $HomeDir ".volta/tools/image/node"))
  if ($env:LOCALAPPDATA) { $bases.Add((Join-Path $env:LOCALAPPDATA "fnm/node-versions")) }
  foreach ($base in $bases) {
    if (Test-Path $base) {
      $direct = Join-Path $base "@deepseek-ai/dsh"
      if (Test-Path -LiteralPath $direct) { $found.Add($direct) }
      Get-ChildItem $base -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        foreach ($rel in @("lib/node_modules/@deepseek-ai/dsh", "installation/lib/node_modules/@deepseek-ai/dsh", "node_modules/@deepseek-ai/dsh")) {
          $p = Join-Path $_.FullName $rel
          if (Test-Path $p) { $found.Add($p) }
        }
      }
    }
  }
  return @($found)
}

# 只删除能证明归属的 dsh shim（文件内容包含 @deepseek-ai/dsh 才算归属）
function Remove-OwnedShims {
  $bases = New-Object System.Collections.Generic.List[string]
  if ($env:NVM_HOME) { $bases.Add($env:NVM_HOME) }
  if ($env:APPDATA) { $bases.Add((Join-Path $env:APPDATA "npm")) }
  $bases.Add((Join-Path $HomeDir ".nvm/versions/node"))
  $bases.Add((Join-Path $HomeDir ".volta/tools/image/node"))
  if ($env:LOCALAPPDATA) { $bases.Add((Join-Path $env:LOCALAPPDATA "fnm/node-versions")) }
  foreach ($base in $bases) {
    if (-not (Test-Path $base)) { continue }
    Get-ChildItem $base -Directory -ErrorAction SilentlyContinue | ForEach-Object {
      foreach ($shim in @("dsh", "dsh.cmd", "dsh.ps1", "dsh-pwsh")) {
        foreach ($rel in @("bin/", "installation/bin/")) {
          $target = Join-Path $_.FullName ($rel + $shim)
          if (-not (Test-Path $target)) { continue }
          try {
            $content = Get-Content $target -Raw -ErrorAction SilentlyContinue
            if ($content -and ($content -match "@deepseek-ai/dsh")) {
              Remove-Item $target -Force -ErrorAction SilentlyContinue
            }
          } catch { }
        }
      }
    }
  }
}

# 扫描并清理外部安装（独立危险操作：先展示清单，默认取消）
function Test-SafeExternalSourceRepo([string]$path) {
  if (-not (Test-SafeCleanupPath $path)) {
    Write-Warn ("拒绝删除不安全路径: " + $path)
    return $false
  }
  if (-not (Test-RepoMarker $path)) {
    Write-Warn ("非 DSH 源码仓库，跳过: " + $path)
    return $false
  }
  $origin = ""
  try { $origin = [string]((& git -C $path remote get-url origin 2>$null | Select-Object -First 1)).Trim() } catch { }
  $official = @(
    "https://github.com/deepseek-ai/deepseek-harness.git",
    "https://github.com/deepseek-ai/deepseek-harness",
    "git@github.com:deepseek-ai/deepseek-harness.git",
    "git@github.com:deepseek-ai/deepseek-harness",
    "ssh://git@github.com/deepseek-ai/deepseek-harness.git"
  )
  if ($official -notcontains $origin) {
    Write-Warn ("仓库 origin 非官方地址，保留: " + $path)
    return $false
  }
  $dirty = & git -C $path status --porcelain 2>$null
  if ($LASTEXITCODE -ne 0) { Write-Warn "无法验证仓库状态，保留: $path"; return $false }
  if ($dirty) {
    Write-Warn ("仓库有未提交改动，保留: " + $path)
    return $false
  }
  $localCommits = ""
  try { $localCommits = [string]((& git -C $path rev-list --count HEAD --not --remotes 2>$null | Select-Object -First 1)).Trim() } catch { }
  if ($localCommits -notmatch "^\d+$") {
    Write-Warn ("无法验证是否含仅本地提交，保留: " + $path)
    return $false
  }
  if ($localCommits -ne "0") {
    Write-Warn ("仓库含仅本地提交，保留: " + $path)
    return $false
  }
  return $true
}

function Remove-ExternalInstalls([string]$extraDir = "") {
  $found = New-Object System.Collections.Generic.List[string]
  foreach ($p in @(Find-ExternalPkgs)) { if (-not $found.Contains("global:" + $p)) { $found.Add("global:" + $p) } }
  foreach ($r in @(Find-SourceRepos)) { if (-not $found.Contains("repo:" + $r)) { $found.Add("repo:" + $r) } }
  if ($extraDir -and (Test-RepoMarker $extraDir)) { $found.Add("repo:" + $extraDir) }
  if ($found.Count -eq 0) {
    Write-Info "未发现其他方式安装的 DeepSeek Harness"
    return 0
  }
  Write-Host ""
  Write-Warn "以下为本工具之外的安装（先展示清单，默认不删除）:"
  foreach ($item in $found) { Write-Host ("    " + $item) }
  Write-Host ""
  if ($script:DryRun) { return 0 }
  Assert-NoDshProcesses
  if (-not (Confirm-ExternalRemoval "确认清理以上全部外部安装？")) {
    Write-Info "已取消（核对清单后再执行）"
    return 1
  }
  # 原生卸载（确认之后才执行）
  try { & npm uninstall -g $NpxPkg *> $null } catch { }
  try { & pnpm uninstall -g $NpxPkg *> $null } catch { }
  try { & yarn global remove $NpxPkg *> $null } catch { }
  foreach ($item in $found) {
    $type = $item.Split(":")[0]
    $path = $item.Substring($type.Length + 1)
    if ($type -eq "global") {
      if (Test-Path $path) {
        $item = Get-Item -LiteralPath $path -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { Remove-CleanupItem $path }
        else {
          try { $pkg = Get-Content -LiteralPath (Join-Path $path 'package.json') -Raw | ConvertFrom-Json } catch { $pkg = $null }
          if ($pkg -and $pkg.name -eq $NpxPkg) { Remove-CleanupItem $path $true }
          else { Write-Warn "无法确认包归属，保留: $path"; $script:CleanupFailed = $true }
        }
      }
    } else {
      if (Test-SafeExternalSourceRepo $path) {
        Remove-CleanupItem $path $true
      } else { $script:CleanupFailed = $true }
    }
  }
  Remove-OwnedShims
  $dshCmd = Get-Command dsh -ErrorAction SilentlyContinue
  if ($dshCmd) { Write-Warn ("PATH 中仍存在 dsh 命令: " + $dshCmd.Source + "（如仍存在请手动处理）") }
  if ($script:CleanupFailed) { return 1 }
  Write-Ok "外部安装清理流程结束"
  return 0
}

# 扫描常见位置的源码仓库（deepseek-harness）
function Find-SourceRepos {
  $found = New-Object System.Collections.Generic.List[string]
  $names = @("Dev", "dev", "Development", "development", "projects", "code", "git", "repos", "source", "src", "workspace", "Desktop", "Documents", "Downloads", "AppData/Local")
  $bases = New-Object System.Collections.Generic.List[string]
  $bases.Add($HomeDir)
  foreach ($n in $names) { $bases.Add((Join-Path $HomeDir $n)) }
  if ((Test-Path (Join-Path $InstallDir ".git")) -and (Test-RepoMarker $InstallDir)) { $found.Add($InstallDir) }
  foreach ($base in $bases) {
    $c = Join-Path $base "deepseek-harness"
    if ((Test-Path (Join-Path $c ".git")) -and (Test-RepoMarker $c)) { $found.Add($c) }
  }
  return @($found)
}

function Invoke-RemoveExternal {
  $extraDir = ""
  $script:DryRun = $false; $script:CleanupFailed = $false
  for ($i = 0; $i -lt $RestArgs.Count; $i++) {
    switch ([string]$RestArgs[$i]) {
      "--dry-run" { $script:DryRun = $true }
      { $_ -eq "--dir" -or $_ -eq "-d" } {
        if ($i + 1 -ge $RestArgs.Count) { Exit-Die "--dir 缺少路径" }
        $i++; $extraDir = [string]$RestArgs[$i]
      }
      { $_ -like "--dir=*" } { $extraDir = $_.Substring(6) }
      "-y" { $script:Yes = $true }
      "--yes" { $script:Yes = $true }
      default { Exit-Die "未知选项: $($RestArgs[$i])" }
    }
  }
  Load-Config
  if ((Remove-ExternalInstalls $extraDir) -ne 0) { exit 1 }
}

# ---------------------------------------------------------------- 更新
function Invoke-Update {
  Load-Config
  if (-not $script:Mode) { $script:Mode = "npx" }
  $wasRunning = Test-Running
  if ($Mode -eq "npx") {
    Write-Info "npx 模式每次启动都会拉取最新发布版；现在清理本地缓存"
    Clear-NpxCache
    Write-Ok "npx 缓存已清理，下次启动即用最新版"
  } else {
    Write-Info "更新源码 ..."
    & git -C $InstallDir pull --ff-only
    if ($LASTEXITCODE -ne 0) { Exit-Die "git pull 失败" }
    $oldReg = $env:NPM_CONFIG_REGISTRY
    if ($script:Registry) { $env:NPM_CONFIG_REGISTRY = $script:Registry }
    try {
      Push-Location $InstallDir
      try {
        & (Get-ExeName "pnpm") install; if ($LASTEXITCODE -ne 0) { Exit-Die "pnpm install 失败" }
        & (Get-ExeName "pnpm") run build; if ($LASTEXITCODE -ne 0) { Exit-Die "pnpm run build 失败" }
      } finally { Pop-Location }
    } finally {
      if ($oldReg) { $env:NPM_CONFIG_REGISTRY = $oldReg }
      else { Remove-Item Env:NPM_CONFIG_REGISTRY -ErrorAction SilentlyContinue }
    }
    Write-Ok "源码更新完成"
  }
  if ($wasRunning) {
    Write-Info "重启 Web UI ..."
    $stopResult = Stop-Web
    if ($stopResult -eq 1) { Exit-Die "更新后未重启：原 Web UI 停止失败，为避免重复启动已中止" }
    Start-Web
  }
}

# ---------------------------------------------------------------- 信息
function Show-Info {
  Load-Config
  if (-not $script:Mode) { $script:Mode = "npx" }
  $nv = "未安装"; $pv = "未安装"; $gv = "未安装"
  try { $nv = "v" + (Get-NodeVersion) } catch { }
  try { $pv = "v" + (& pnpm --version 2>$null | Select-Object -First 1) } catch { }
  try { $gv = (& git --version 2>$null | Select-Object -First 1).Replace("git version ", "") } catch { }
  $running = Test-Running
  $pidVal = $null
  $pidInfo = Get-PidInfo
  if ($pidInfo) { $pidVal = $pidInfo.pid }
  if ($script:JsonOut) {
    $o = [ordered]@{
      app = $AppName; version = $AppVersion
      os = "windows"; arch = (Get-Arch)
      mode = $Mode; installDir = $InstallDir; dshHome = $DshHome
      node = $nv; nodeOk = (Test-NodeOk)
      pnpm = $pv; git = $gv
      host = $BindHost; port = $Port; url = (Get-WebUrl)
      running = $running; pid = $pidVal; log = $LogFile
    }
    $o | ConvertTo-Json -Compress
    return
  }
  Write-Host ""
  Write-Host "  DeepSeek Harness 环境信息" -ForegroundColor Blue
  Write-Host "  安装器     : $AppName v$AppVersion"
  Write-Host "  系统       : windows / $(Get-Arch)"
  Write-Host "  Node.js    : $nv"
  Write-Host "  pnpm       : $pv"
  Write-Host "  git        : $gv"
  Write-Host "  安装模式   : $Mode"
  Write-Host "  安装目录   : $InstallDir"
  Write-Host "  数据目录   : $DshHome"
  Write-Host "  访问地址   : $(Get-WebUrl)"
  Write-Host "  日志文件   : $LogFile"
  if ($running) { Write-Host "  运行状态   : 运行中 (PID $pidVal)" -ForegroundColor Green }
  else { Write-Host "  运行状态   : 未运行" -ForegroundColor Yellow }
}

# ---------------------------------------------------------------- dsh 技能
function Install-Skill {
  New-Item -ItemType Directory -Path $SkillDir -Force | Out-Null
  $content = @'
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
'@
  Set-Content -Path (Join-Path $SkillDir "SKILL.md") -Value $content -Encoding UTF8
  New-Item -ItemType File -Path $SkillMarker -Force | Out-Null
  Write-Ok "已注册可选实验性 dsh Skill: $SkillDir/SKILL.md"
}

function Invoke-Skill {
  Load-Config
  Write-Warn "此 Skill 为可选实验性功能，未经完整测试；不会自动注入或默认启用"
  Install-Skill
}

# ---------------------------------------------------------------- 卸载
function Remove-CleanupItem([string]$path, [bool]$tree = $false) {
  if (-not (Test-Path -LiteralPath $path) -and -not (Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue)) { return }
  if ($tree -and -not (Test-SafeCleanupPath $path)) {
    Write-Warn "保留不安全路径: $path"
    $script:CleanupFailed = $true
    return
  }
  Write-Info "删除: $path"
  if ($script:DryRun) { return }
  try {
    if ($tree) { Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop }
    else { Remove-Item -LiteralPath $path -Force -ErrorAction Stop }
  } catch {
    Write-Err "删除失败: $path ($($_.Exception.Message))"
    $script:CleanupFailed = $true
  }
}

function Assert-NoDshProcesses {
  if (-not $script:IsWin) { return }
  try { $processes = @(Get-CimInstance Win32_Process -ErrorAction Stop) }
  catch { Exit-Die "无法验证 DSH 进程，保留安装和数据" }
  if (@($processes | Where-Object { $_.Name -match "^(node|npm|pnpm|npx)(\.exe)?$" -and $_.CommandLine -match "apps[\\/]cli[\\/](src|lib)[\\/]bin\.(ts|js)|@deepseek-ai/dsh|[ /]dsh web|deepseek-harness[\\/]packages[\\/]" }).Count) {
    Exit-Die "仍有其他 DSH 实例，先停止所有实例再清理"
  }
}

function Remove-DshTemp {
  # Windows 使用 CIM 检查命令行和 ACL 所有者；不猜测共享临时目录的归属。
  if (-not $script:IsWin) { Write-Warn "PowerShell 临时清理仅支持 Windows；macOS/Linux 请用 install.sh"; $script:CleanupFailed = $true; return }
  try { $processes = @(Get-CimInstance Win32_Process -ErrorAction Stop) }
  catch { Write-Err "无法验证 DSH 进程，保留临时目录"; $script:CleanupFailed = $true; return }
  if (@($processes | Where-Object { $_.Name -match "^(node|npm|pnpm|npx)(\.exe)?$" -and $_.CommandLine -match "apps[\\/]cli[\\/](src|lib)[\\/]bin\.(ts|js)|@deepseek-ai/dsh|[ /]dsh web" }).Count) {
    Write-Err "仍有 DSH 进程，停止所有实例后再清理临时目录"
    $script:CleanupFailed = $true
    return
  }
  $owner = [Security.Principal.WindowsIdentity]::GetCurrent().Name
  $root = [IO.Path]::GetTempPath()
  foreach ($entry in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction Stop)) {
    if ($entry.Name -notmatch "^(dsh-(subprocess-launch|shell|subprocess|spill|ptc-runtime-python|native-command|acl-skill|stagehand-chrome)-.+|dsh-drops)$") { continue }
    if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
    try { $acl = Get-Acl -LiteralPath $entry.FullName -ErrorAction Stop } catch { continue }
    if ($acl.Owner -ieq $owner) { Remove-CleanupItem $entry.FullName $true }
  }
}

function Invoke-Uninstall([object[]]$argsList = $null) {
  if ($null -eq $argsList) { $argsList = @($RestArgs) }
  $purge = $false; $purgeTemp = $false; $extraDir = ""; $removeExternal = $false
  $script:DryRun = $false; $script:CleanupFailed = $false
  for ($i = 0; $i -lt $argsList.Count; $i++) {
    switch ([string]$argsList[$i]) {
      "--purge" { $purge = $true }
      "--purge-temp" { $purgeTemp = $true }
      "--dry-run" { $script:DryRun = $true }
      "--remove-external" { $removeExternal = $true }
      { $_ -eq "-d" -or $_ -eq "--dir" } {
        if ($i + 1 -ge $argsList.Count) { Exit-Die "--dir 缺少路径" }
        $i++; $extraDir = [string]$argsList[$i]
      }
      { $_ -like "--dir=*" } { $extraDir = $_.Substring(6) }
      "-y" { $script:Yes = $true }
      "--yes" { $script:Yes = $true }
      "-q" { $script:Quiet = $true }
      "--quiet" { $script:Quiet = $true }
      "--help" { Show-Usage; return }
      default { Exit-Die "未知选项: $($argsList[$i])" }
    }
  }
  if ($purgeTemp -and -not $purge) { Exit-Die "--purge-temp 需与 --purge 同用" }
  Load-Config
  if (-not $script:Mode) { $script:Mode = "npx" }
  $script:InstallDir = ConvertTo-AbsolutePath $script:InstallDir
  if ($purge) { Assert-PurgeHome }
  if (-not (Test-SafeCleanupPath $CfgDir)) { Exit-Die "不安全的安装器配置目录: $CfgDir" }
  if ($script:DryRun) { Write-Info "预览模式：不会停止进程、删除文件或修改 PATH" }
  else {
    if ((-not [Environment]::UserInteractive -or [Console]::IsInputRedirected) -and -not $script:Yes) { Exit-Die "卸载需确认：非交互调用请加 -y" }
    if (-not (Confirm-Action "确定卸载本工具安装的 DeepSeek Harness？" $false)) { Write-Info "已取消"; return }
    $stopResult = Stop-Web
    if ($stopResult -eq 1) { Exit-Die "服务未安全停止，保留安装和数据" }
    Assert-NoDshProcesses
  }
  $sourceMarker = Join-Path $InstallDir $script:SourceMarkerName
  if ((Test-RepoMarker $InstallDir) -and (Test-Path -LiteralPath $sourceMarker)) {
    $dirty = & git -C $InstallDir status --porcelain 2>$null
    $dirtyFailed = $LASTEXITCODE -ne 0
    $commits = & git -C $InstallDir rev-list --count HEAD --not --remotes 2>$null
    if ($dirtyFailed -or $dirty -or $LASTEXITCODE -ne 0 -or ([string]$commits).Trim() -ne "0") {
      if (-not $script:DryRun -and (Confirm-ExternalRemoval "源码含本地改动/提交或无法验证，仍删除 $InstallDir？")) { Remove-CleanupItem $InstallDir $true }
      else { Write-Warn "保留源码（本地改动/提交或无法验证）: $InstallDir"; $script:CleanupFailed = $true }
    } else { Remove-CleanupItem $InstallDir $true }
  } elseif ($Mode -eq "source" -and (Test-Path -LiteralPath $InstallDir)) { Write-Warn "保留外部源码: $InstallDir；可用 --remove-external 单独确认清理" }
  Clear-NpxCache
  foreach ($path in @($Launcher, $CliLink)) {
    if ((Test-Path -LiteralPath $path) -and (Select-String -LiteralPath $path -SimpleMatch "Generated by $AppName" -Quiet)) { Remove-CleanupItem $path }
  }
  if (Test-Path -LiteralPath $SkillMarker) { Remove-CleanupItem $SkillDir $true }
  $ownedNode = Test-Path -LiteralPath (Join-Path $NodeDir ".installed-by-dsh-installer")
  $ownedRuntime = @($NodeDir, (Join-Path $CfgDir "pnpm"))
  foreach ($path in $ownedRuntime) {
    if (Test-Path -LiteralPath (Join-Path $path ".installed-by-dsh-installer")) { Remove-CleanupItem $path $true }
  }
  if ($purge) {
    if ($script:DryRun -or (Confirm-Action "删除 $DshHome 的会话、凭据、插件、附件及运行时缓存？" $false)) { Remove-CleanupItem $DshHome $true }
    else { Write-Warn "保留数据目录: $DshHome" }
  } else { Write-Info "保留数据目录: $DshHome（--purge 可清理）" }
  if ($purgeTemp) { Remove-DshTemp }
  if ($removeExternal) { if ((Remove-ExternalInstalls $extraDir) -ne 0) { $script:CleanupFailed = $true } }
  if (-not $script:CleanupFailed) {
    foreach ($path in @($RunScript, $PidFile, $LogFile, $ErrLogFile, $ConfigFile)) { Remove-CleanupItem $path }
  }
  # 仅移除本安装器的两个路径，不动系统或第三方 Node/pnpm。
  if ($script:IsWin) {
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $removePaths = @($BinDir)
    if ($ownedNode) { $removePaths += $NodeDir }
    $kept = @($userPath -split ";" | Where-Object { $_ -and ($removePaths -inotcontains $_.TrimEnd("\")) }) -join ";"
    if ($kept -ne $userPath -and $userPath) {
      Write-Info "移除安装器的用户 PATH 条目"
      if (-not $script:DryRun -and -not $script:CleanupFailed) { [Environment]::SetEnvironmentVariable("Path", $kept, "User") }
    }
  }
  if (-not $script:DryRun) {
    foreach ($path in @($BinDir, $CfgDir)) {
      if ((Test-Path -LiteralPath $path) -and -not @(Get-ChildItem -LiteralPath $path -Force).Count) { Remove-Item -LiteralPath $path -Force }
    }
  }
  if ($script:CleanupFailed) { Exit-Die "清理未完成，已保留配置；检查以上保留/失败项后重试" }
  if ($script:DryRun) { Write-Ok "预览结束" } else { Write-Ok "卸载完成" }
}

# ---------------------------------------------------------------- 交互菜单
function Show-MenuBanner {
  Load-Config
  if (-not $script:Mode) { $script:Mode = "npx" }
  $running = Test-Running
  Write-Host ""
  Write-Host ("  DeepSeek Harness 安装器 v" + $AppVersion + " —— 主菜单") -ForegroundColor Blue
  Write-Host ("  安装模式: " + $Mode + " | 访问地址: " + (Get-WebUrl) + " | 状态: ") -NoNewline
  if ($running) { Write-Host "运行中" -ForegroundColor Green }
  else { Write-Host "未运行" -ForegroundColor Yellow }
  Write-Host ""
}

function Menu-Install {
  Write-Host ""
  Write-Host "  安装方式:"
  Write-Host "    [1] npx 快捷安装（推荐）—— npm 官方发布包，启动快、自动更新"
  Write-Host "    [2] 源码安装 —— git clone 官方仓库并本地构建"
  $c = Read-Host "请选择 [1]"
  if (-not $c) { $c = "1" }
  $modeSel = ""
  if ($c -eq "1") { $modeSel = "npx" }
  elseif ($c -eq "2") { $modeSel = "source" }
  else { Write-Warn "无效选择"; return }
  $args = @("--mode", $modeSel)
  $portStr = Read-Host ("Web UI 端口 [" + $Port + "]")
  if ($portStr) { $args += @("--port", $portStr) }
  if ($modeSel -eq "source") {
    $dirStr = Read-Host ("安装目录 [" + $InstallDir + "]")
    if ($dirStr) { $args += @("--dir", $dirStr) }
  }
  Write-Host ""
  Invoke-Install $args
}

function Menu-Plugin {
  while ($true) {
    Write-Host ""
    Write-Host "  插件管理:"
    Write-Host "    [1] 安装插件"
    Write-Host "    [2] 移除插件"
    Write-Host "    [3] 更新全部插件"
    Write-Host "    [4] 插件列表"
    Write-Host "    [5] 搜索插件"
    Write-Host "    [0] 返回主菜单"
    $c = Read-Host "请选择 [0]"
    if (-not $c) { $c = "0" }
    switch ($c) {
      "0" { return }
      "1" {
        $p = Read-Host "插件来源（npm 包名 | github:用户/仓库 | 本地路径 | .tgz）"
        if ($p) { Invoke-Plugin @("add", $p) } else { Write-Warn "未输入插件来源" }
      }
      "2" {
        $p = Read-Host "要移除的插件包名"
        if ($p) { Invoke-Plugin @("remove", $p) } else { Write-Warn "未输入包名" }
      }
      "3" { Invoke-Plugin @("update") }
      "4" { Invoke-Plugin @("list") }
      "5" {
        $p = Read-Host "搜索关键词（回车=全部 dsh-plugin）"
        if (-not $p) { $p = "dsh-plugin" }
        Invoke-Plugin @("search", $p)
      }
      default { Write-Warn ("无效选择: " + $c) }
    }
  }
}

function Menu-Uninstall {
  Write-Host ""
  Write-Host "  卸载选项:"
  Write-Host "    [1] 卸载本工具安装的 DSH（默认，安全；保留 ~/.dsh 数据）"
  Write-Host "    [2] 卸载并删除 ~/.dsh 数据（二次确认）"
  Write-Host "    [3] 扫描并清理外部安装（危险：默认取消、逐项展示、脏仓库拒绝）"
  Write-Host "    [0] 返回主菜单"
  $c = Read-Host "请选择 [0]"
  if (-not $c) { $c = "0" }
  switch ($c) {
    "0" { return }
    "1" { Invoke-Uninstall @() }
    "2" { Invoke-Uninstall @("--purge") }
    "3" { $null = Remove-ExternalInstalls "" }
    default { Write-Warn ("无效选择: " + $c) }
  }
}

function Show-Menu {
  while ($true) {
    Show-MenuBanner
    Write-Host "  请选择操作:"
    Write-Host "    [1]  安装 DeepSeek Harness"
    Write-Host "    [2]  启动 Web UI"
    Write-Host "    [3]  停止 Web UI"
    Write-Host "    [4]  重启 Web UI"
    Write-Host "    [5]  查看运行状态"
    Write-Host "    [6]  查看日志"
    Write-Host "    [7]  在浏览器打开 Web UI"
    Write-Host "    [8]  插件管理"
    Write-Host "    [9]  更新 DSH"
    Write-Host "    [10] 环境信息"
    Write-Host "    [11] 注册可选实验性 dsh Skill（未经完整测试）"
    Write-Host "    [12] 卸载"
    Write-Host "    [0]  退出"
    $c = Read-Host "请输入数字 [0]"
    if (-not $c) { $c = "0" }
    switch ($c) {
      "0" { Write-Host ""; Write-Info "再见！"; return }
      "1" { Menu-Install }
      "2" { Start-Web }
      "3" { $null = Stop-Web }
      "4" { Restart-Web }
      "5" { $null = Get-Status }
      "6" { Show-Logs @() }
      "7" { Open-Web }
      "8" { Menu-Plugin }
      "9" { Invoke-Update }
      "10" { Show-Info }
      "11" { Invoke-Skill }
      "12" { Menu-Uninstall }
      default { Write-Warn ("无效选择: " + $c) }
    }
  }
}

# ---------------------------------------------------------------- 帮助
function Show-Usage {
  @"
DeepSeek Harness 多平台安装器 (Windows)

用法: install.ps1 [命令] [选项]

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
  skill        注册可选实验性 dsh Skill（未经完整测试；默认不注册）
  uninstall    卸载（--purge 删除 DSH_HOME；--dry-run 预览；--purge-temp 清临时残留）
  version      显示版本号

通用选项:
  -y, --yes    非交互模式（供 dsh/CI 调用）
  -q, --quiet  只输出错误
  --json       机器可读输出（status/info/plugin list/search）
  -h, --help   帮助

退出码: 0=成功  1=错误  2=服务未运行/未安装

示例:
  install.ps1 install                          # 交互式安装（默认 npx 模式）
  install.ps1 install -y --mode source         # 非交互源码安装
  install.ps1 install -y --port 8080 --registry https://registry.npmmirror.com
  install.ps1 plugin add github:somebody/awesome-dsh-plugin -y
  install.ps1 status --json
"@
}

# ---------------------------------------------------------------- 入口
if ($MyInvocation.InvocationName -eq ".") { return }
# PowerShell 会把 `install.ps1 --help` 放进 RestArgs，而不是绑定到 Command。
# 先标准化顶层别名，避免无意进入交互菜单或开始默认安装。
$hasExplicitCommand = $PSBoundParameters.ContainsKey("Command")
if (-not $hasExplicitCommand -and $RestArgs.Count -gt 0) {
  $first = [string]$RestArgs[0]
  if (@("-h", "--help", "help", "-v", "-V", "--version", "version") -contains $first) {
    $Command = $first
    $hasExplicitCommand = $true
    if ($RestArgs.Count -gt 1) { $RestArgs = @($RestArgs[1..($RestArgs.Count - 1)]) }
    else { $RestArgs = @() }
  }
}
if (-not $hasExplicitCommand -and $RestArgs.Count -eq 0) {
  # 无参数启动：仅真正可读 stdin 的交互终端进菜单；CI/重定向输入保持默认安装行为。
  if ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected) { Show-Menu; exit 0 }
}
switch ($Command.ToLower()) {
  "menu" { Show-Menu }
  "install" { Invoke-Install }
  "start" {
    Set-CommandFlags $RestArgs $true
    Start-Web
  }
  "stop" {
    Set-CommandFlags $RestArgs $true
    $r = Stop-Web
    if ($r -ne 0) { exit $r }
  }
  "restart" {
    Set-CommandFlags $RestArgs $false
    $r = Restart-Web
    if ($r -is [int] -and $r -ne 0) { exit $r }
  }
  "status" {
    Set-CommandFlags $RestArgs $true
    $inst = Get-Status
    if (-not $inst) { exit 2 }
  }
  "logs" { Show-Logs }
  "update" { Set-CommandFlags $RestArgs $false; Invoke-Update }
  "plugin" {
    $r = Invoke-Plugin
    if ($r -is [int] -and $r -ne 0) { exit $r }
    # list/search 的 JSON 走管道输出，赋值捕获后必须显式冲刷，否则输出会丢失
    if ($r -isnot [int]) { $r }
  }
  "info" {
    Set-CommandFlags $RestArgs $true
    Show-Info
  }
  "open" { Open-Web }
  "skill" { Invoke-Skill }
  "uninstall" { Invoke-Uninstall }
  "remove-external" { Invoke-RemoveExternal }
  "version" { Write-Host $AppVersion }
  "-v" { Write-Host $AppVersion }
  "-V" { Write-Host $AppVersion }
  "--version" { Write-Host $AppVersion }
  "-h" { Show-Usage }
  "--help" { Show-Usage }
  "help" { Show-Usage }
  default { Show-Usage; exit 1 }
}
