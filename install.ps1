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
#    skill        把本安装器注册为 dsh 技能（dsh 可直接调用本工具装插件）
#    uninstall    卸载（--purge 同时删除 ~/.dsh 数据目录）
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
$script:AppVersion = "1.2.0"
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
if ($env:DSH_HOME) { $script:DshHome = $env:DSH_HOME }
else { $script:DshHome = Join-Path $HomeDir ".dsh" }
$script:SkillDir = Join-Path $DshHome "skills/dsh-installer"
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
$script:NoSkill = $false
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
  }
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
  if (-not (Install-NodeViaWinget)) {
    Write-Warn "winget 不可用或安装失败，改用官方 zip 安装"
    Install-NodeViaZip
  }
  if (-not (Test-NodeOk)) { Exit-Die "Node.js 安装后仍不可用" }
}

# ---------------------------------------------------------------- pnpm / git
function Ensure-Pnpm {
  if (Get-Command pnpm -ErrorAction SilentlyContinue) {
    Write-Info "pnpm v$(& pnpm --version 2>$null | Select-Object -First 1) 已就绪"
    return $true
  }
  Write-Info "安装 pnpm@$PnpmVersion ..."
  & npm install -g "pnpm@$PnpmVersion" *> $null
  if (Get-Command pnpm -ErrorAction SilentlyContinue) { Write-Ok "pnpm 安装完成"; return $true }
  # 回退：装到用户目录（无需管理员）
  $prefix = Join-Path $LocalAppData "npm"
  New-Item -ItemType Directory -Path $prefix -Force | Out-Null
  & npm config set prefix $prefix *> $null
  & npm install -g "pnpm@$PnpmVersion" *> $null
  Add-ToUserPath $prefix
  $env:Path = $prefix + ";" + $env:Path
  if (Get-Command pnpm -ErrorAction SilentlyContinue) { Write-Ok "pnpm 安装完成"; return $true }
  Write-Warn "pnpm 安装失败：插件管理功能将不可用"
  Write-Warn "可手动执行: npm install -g pnpm@$PnpmVersion"
  return $false
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

# 读取 PID 文件信息（兼容旧版纯数字格式）
function Get-PidInfo {
  if (-not (Test-Path $PidFile)) { return $null }
  $raw = Get-Content $PidFile -Raw -ErrorAction SilentlyContinue
  if (-not $raw) { return $null }
  $info = $null
  try { $info = $raw | ConvertFrom-Json } catch { }
  if ($info -and $info.pid) { return $info }
  $num = 0
  if ([int]::TryParse($raw.Trim(), [ref]$num)) { return [ordered]@{ pid = $num } }
  return $null
}

# 身份校验后的本工具进程；无法确认时返回 $null（原因见 $script:IdentityStatus）
function Get-OwnProcess {
  $script:IdentityStatus = "not-running"
  $info = Get-PidInfo
  if (-not $info) { return $null }
  $proc = Get-Process -Id ([int]$info.pid) -ErrorAction SilentlyContinue
  if (-not $proc) { return $null }
  try {
    if ($info.start -and ($proc.StartTime.ToString("o") -ne $info.start)) {
      $script:IdentityStatus = "mismatch"
      return $null
    }
  } catch { }
  if ($script:IsWin -and $info.script) {
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

# 宽松判断：PID 文件进程存活（仅用于 status 展示 / start 成功判断，无击杀风险）
function Test-Running {
  $info = Get-PidInfo
  if (-not $info) { return $false }
  return [bool](Get-Process -Id ([int]$info.pid) -ErrorAction SilentlyContinue)
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
    if (-not (Confirm-Action "警告：绑定 0.0.0.0 会把 Web UI 暴露到局域网（当前无 TLS/认证）。仍要继续？" $false)) {
      Exit-Die "已取消（改用默认 127.0.0.1 即可）"
    }
  }
}

function Write-RunScript {
  New-Item -ItemType Directory -Path $CfgDir -Force | Out-Null
  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add("@echo off")
  if ($Mode -eq "source") {
    $lines.Add('cd /d "' + $InstallDir + '"')
  } else {
    $lines.Add('cd /d "%USERPROFILE%"')
  }
  if ($Registry) { $lines.Add('set "NPM_CONFIG_REGISTRY=' + $Registry + '"') }
  if ($Mode -eq "source") {
    $lines.Add("call pnpm.cmd dsh web --host $BindHost --port $Port")
  } else {
    $lines.Add("call npx.cmd --yes $NpxPkg web --host $BindHost --port $Port")
  }
  Set-Content -Path $RunScript -Value $lines -Encoding Ascii
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

function Restart-Web { $null = Stop-Web; Start-Web }

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
  Start-Process (Get-WebUrl)
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
  $repoUrl = $script:CloneUrl
  if (-not $repoUrl) { $repoUrl = $GithubRepo }
  $gitDir = Join-Path $InstallDir ".git"
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
  --no-skill              不注册 dsh 技能
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
      "^--no-skill$" { $script:NoSkill = $true }
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

  Write-Launcher
  Install-Skill
  Save-Config

  Write-Host ""
  Write-Ok "安装完成！"
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
  if ($Mode -eq "source") {
    $lines.Add('cd /d "' + $InstallDir + '"')
    $lines.Add("call pnpm.cmd dsh web --host $BindHost --port $Port")
  } else {
    $lines.Add('cd /d "%USERPROFILE%"')
    if ($Registry) { $lines.Add('set "NPM_CONFIG_REGISTRY=' + $Registry + '"') }
    $lines.Add("call npx.cmd --yes $NpxPkg web --host $BindHost --port $Port")
  }
  Set-Content -Path $Launcher -Value $lines -Encoding Ascii
  $cliLines = @("@echo off", 'powershell -NoProfile -ExecutionPolicy Bypass -File "' + $PsScriptPath + '" %*')
  Set-Content -Path $CliLink -Value $cliLines -Encoding Ascii
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
    if (($a -eq "-q") -or ($a -eq "--quiet")) { $script:Quiet = $true; continue }
    if (-not $action) { $action = $a }
    else { $argsList.Add($a) }
  }
  if (-not $action) { $action = "list" }
  switch -Regex ($action) {
    "^(add|install|i)$" { Run-PluginCmd $profile "add" $argsList }
    "^(remove|rm|uninstall|del)$" { Run-PluginCmd $profile "remove" $argsList }
    "^(update|upgrade|up)$" { Run-PluginCmd $profile "update" $argsList }
    "^(list|ls)$" {
      if ($script:JsonOut) { Get-PluginListJson $profile }
      else { Get-PluginListText $profile }
    }
    "^(search|s)$" { Search-Plugin $argsList }
    default { Write-Err "用法: install.ps1 plugin <add|remove|update|list|search> [参数]"; exit 1 }
  }
}

function Run-PluginCmd([string]$profile, [string]$pnpmAction, $argsList) {
  if (-not (Get-Command pnpm -ErrorAction SilentlyContinue)) {
    Write-Warn "插件管理需要 pnpm，尝试安装 ..."
    if (-not (Ensure-Pnpm)) { Exit-Die "pnpm 不可用" }
  }
  $oldReg = $env:NPM_CONFIG_REGISTRY
  if ($script:Registry) { $env:NPM_CONFIG_REGISTRY = $script:Registry }
  $rc = 0
  try {
    if ($Mode -eq "source") {
      Push-Location $InstallDir
      try {
        $all = @("dsh", "plugin", "--profile", $profile, $pnpmAction) + @($argsList)
        & (Get-ExeName "pnpm") @all
        $rc = $LASTEXITCODE
      } finally { Pop-Location }
    } else {
      Push-Location $HomeDir
      try {
        $all = @("--yes", $NpxPkg, "plugin", "--profile", $profile, $pnpmAction) + @($argsList)
        & (Get-ExeName "npx") @all
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
  exit $rc
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
  try { $items = @($raw | ConvertFrom-Json) } catch { Write-Host $raw; exit 0 }
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
  if (Test-Path $npxCache) {
    Remove-Item $npxCache -Recurse -Force -ErrorAction SilentlyContinue
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
  if ($env:NVM_HOME) { $bases.Add((Join-Path $env:NVM_HOME "node_modules")) }
  if ($env:APPDATA) { $bases.Add((Join-Path $env:APPDATA "npm/node_modules")) }
  if ($env:ProgramFiles) { $bases.Add((Join-Path $env:ProgramFiles "nodejs/node_modules")) }
  $bases.Add((Join-Path $HomeDir ".nvm/versions/node"))
  $bases.Add((Join-Path $HomeDir ".volta/tools/image/node"))
  if ($env:LOCALAPPDATA) { $bases.Add((Join-Path $env:LOCALAPPDATA "fnm/node-versions")) }
  foreach ($base in $bases) {
    if (Test-Path $base) {
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
  if ($env:NVM_HOME) { $bases.Add((Join-Path $env:NVM_HOME "node_modules")) }
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
function Remove-ExternalInstalls([string]$extraDir = "") {
  $found = New-Object System.Collections.Generic.List[string]
  foreach ($p in @(Find-ExternalPkgs)) { if (-not $found.Contains($p)) { $found.Add("global:" + $p) } }
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
  if (-not (Confirm-Action "确认清理以上全部外部安装？" $false)) {
    Write-Info "已取消（核对清单后再执行）"
    return 0
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
        Remove-Item $path -Recurse -Force -ErrorAction SilentlyContinue
        Write-Ok ("已删除全局安装: " + $path)
      }
    } else {
      if (($path -eq $HomeDir) -or ([System.IO.Path]::GetPathRoot($path) -eq $path)) {
        Write-Warn ("拒绝删除不安全路径: " + $path)
        continue
      }
      $dirty = ""
      try { $dirty = & git -C $path status --porcelain 2>$null } catch { }
      if ($dirty) {
        Write-Warn ("仓库有未提交改动，跳过: " + $path)
      } else {
        Remove-Item $path -Recurse -Force
        Write-Ok ("已删除源码仓库: " + $path)
      }
    }
  }
  Remove-OwnedShims
  $dshCmd = Get-Command dsh -ErrorAction SilentlyContinue
  if ($dshCmd) { Write-Warn ("PATH 中仍存在 dsh 命令: " + $dshCmd.Source + "（如仍存在请手动处理）") }
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
  foreach ($base in $bases) {
    $c = Join-Path $base "deepseek-harness"
    if ((Test-Path (Join-Path $c ".git")) -and (Test-RepoMarker $c)) { $found.Add($c) }
  }
  return @($found)
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
    Stop-Web *> $null
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
  $pidVal = Get-Content $PidFile -ErrorAction SilentlyContinue
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
  if ($script:NoSkill) { return }
  New-Item -ItemType Directory -Path $SkillDir -Force | Out-Null
  $content = @'
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
'@
  Set-Content -Path (Join-Path $SkillDir "SKILL.md") -Value $content -Encoding UTF8
  Write-Ok "已注册 dsh 技能: $SkillDir/SKILL.md（dsh 可直接调用本安装器）"
}

function Invoke-Skill {
  Load-Config
  Install-Skill
}

# ---------------------------------------------------------------- 卸载
function Invoke-Uninstall([object[]]$argsList = $null) {
  if ($null -eq $argsList) { $argsList = @($RestArgs) }
  $purge = $false
  $extraDir = ""
  $removeExternal = $false
  for ($i = 0; $i -lt $argsList.Count; $i++) {
    switch ([string]$argsList[$i]) {
      "--purge" { $purge = $true }
      "--remove-external" { $removeExternal = $true }
      "-d" { if ($argsList[$i + 1]) { $extraDir = [string]$argsList[$i + 1]; $i++ } }
      "--dir" { if ($argsList[$i + 1]) { $extraDir = [string]$argsList[$i + 1]; $i++ } }
      { $_ -like "--dir=*" } { $extraDir = $_.Substring(6) }
      "-y" { $script:Yes = $true }
      "--yes" { $script:Yes = $true }
      "-q" { $script:Quiet = $true }
      "--quiet" { $script:Quiet = $true }
      default { Exit-Die "未知选项: $argsList[$i]" }
    }
  }
  Load-Config
  if (-not $script:Mode) { $script:Mode = "npx" }
  if ((-not [Environment]::UserInteractive) -and (-not $script:Yes)) {
    Exit-Die "卸载需确认：非交互调用请加 -y"
  }
  if (-not (Confirm-Action "确定卸载本工具安装的 DeepSeek Harness？" $false)) {
    Write-Info "已取消"
    exit 0
  }
  Write-Info "停止服务 ..."
  $stopResult = Stop-Web
  if ($stopResult -eq 1) {
    Write-Warn "服务停止未完全生效，继续卸载（若端口仍被占用请手动结束进程）"
  }

  # ---- 只清理本工具确认拥有的资源（默认不扫、不猜、不扩大范围）----
  if ($Mode -eq "source") {
    if ((Test-Path $InstallDir) -and (Test-RepoMarker $InstallDir)) {
      $dirty = ""
      try { $dirty = & git -C $InstallDir status --porcelain 2>$null } catch { }
      if ($dirty -and -not (Confirm-Action "源码目录存在未提交改动，仍要删除？" $false)) {
        Write-Warn ("已跳过源码目录: " + $InstallDir)
      } else {
        Write-Info "删除源码目录: $InstallDir"
        Remove-Item $InstallDir -Recurse -Force
      }
    } else {
      Write-Info "源码目录不存在或非本安装器管理，跳过"
    }
  } else {
    Write-Info "清理 npx 缓存中的 dsh ..."
    Clear-NpxCache
  }

  Remove-Item $Launcher -Force -ErrorAction SilentlyContinue
  Remove-Item $CliLink -Force -ErrorAction SilentlyContinue
  Remove-Item $SkillDir -Recurse -Force -ErrorAction SilentlyContinue
  if (Test-Path (Join-Path $NodeDir ".installed-by-dsh-installer")) {
    Remove-Item $NodeDir -Recurse -Force
  }
  Remove-Item $CfgDir -Recurse -Force -ErrorAction SilentlyContinue

  # 清理安装器写入的用户 PATH 条目
  try {
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if ($userPath) {
      $kept = @(($userPath -split ";") | Where-Object { $_ -and -not ($_ -like ($CfgDir + "*")) }) -join ";"
      if ($kept -ne $userPath) {
        [Environment]::SetEnvironmentVariable("Path", $kept, "User")
        Write-Info "已清理用户 PATH 中的安装器条目"
      }
    }
  } catch { }

  if ($purge) {
    $leaf = Split-Path $DshHome -Leaf
    if ($leaf -ne ".dsh") {
      Exit-Die "拒绝删除不安全路径: $DshHome（--purge 仅允许删除 ~/.dsh 形态的数据目录）"
    }
    if (Confirm-Action "同时删除全部数据目录 $DshHome（会话、配置、插件全部丢失）？" $false) {
      Remove-Item $DshHome -Recurse -Force -ErrorAction SilentlyContinue
      Write-Ok "已删除数据目录"
    } else {
      Write-Info "保留数据目录: $DshHome"
    }
  }

  Write-Ok "卸载完成"
  if (-not $purge) { Write-Info "提示: 数据目录 $DshHome 已保留，如需彻底删除请用 --purge" }
  if ($Mode -eq "npx") {
    Write-Info "说明: npx 模式无驻留安装，npx @deepseek-ai/dsh web 本身随时可再次运行（已清理本地缓存/启动器/技能）"
  }
  # 外部安装清理是独立的危险操作，默认不执行
  if ($removeExternal) {
    $null = Remove-ExternalInstalls $extraDir
  } elseif ($extraDir) {
    Write-Warn "提示: --dir 仅在 --remove-external 时生效"
  }
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
    Write-Host "    [11] 注册 dsh 技能"
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
  skill        把本安装器注册为 dsh 技能（dsh 可直接调用本工具）
  uninstall    卸载（--purge 同时删除 ~/.dsh 数据目录）
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
if (-not $PSBoundParameters.ContainsKey("Command")) {
  # 无参数启动：交互环境进菜单；非交互（dsh/CI）保持默认安装行为
  if ([Environment]::UserInteractive) { Show-Menu; exit 0 }
}
switch ($Command.ToLower()) {
  "menu" { Show-Menu }
  "install" { Invoke-Install }
  "start" {
    for ($i = 0; $i -lt $RestArgs.Count; $i++) {
      if ([string]$RestArgs[$i] -eq "--json") { $script:JsonOut = $true }
      if (([string]$RestArgs[$i] -eq "-q") -or ([string]$RestArgs[$i] -eq "--quiet")) { $script:Quiet = $true }
    }
    Start-Web
  }
  "stop" {
    for ($i = 0; $i -lt $RestArgs.Count; $i++) {
      if ([string]$RestArgs[$i] -eq "--json") { $script:JsonOut = $true }
      if (([string]$RestArgs[$i] -eq "-q") -or ([string]$RestArgs[$i] -eq "--quiet")) { $script:Quiet = $true }
    }
    $r = Stop-Web
    if ($r -ne 0) { exit $r }
  }
  "restart" { Restart-Web }
  "status" {
    for ($i = 0; $i -lt $RestArgs.Count; $i++) {
      if ([string]$RestArgs[$i] -eq "--json") { $script:JsonOut = $true }
      if (([string]$RestArgs[$i] -eq "-q") -or ([string]$RestArgs[$i] -eq "--quiet")) { $script:Quiet = $true }
    }
    $inst = Get-Status
    if (-not $inst) { exit 2 }
  }
  "logs" { Show-Logs }
  "update" { Invoke-Update }
  "plugin" { Invoke-Plugin }
  "info" {
    for ($i = 0; $i -lt $RestArgs.Count; $i++) {
      if ([string]$RestArgs[$i] -eq "--json") { $script:JsonOut = $true }
      if (([string]$RestArgs[$i] -eq "-q") -or ([string]$RestArgs[$i] -eq "--quiet")) { $script:Quiet = $true }
    }
    Show-Info
  }
  "open" { Open-Web }
  "skill" { Invoke-Skill }
  "uninstall" { Invoke-Uninstall }
  "remove-external" { $null = Remove-ExternalInstalls "" }
  "version" { Write-Host $AppVersion }
  "-v" { Write-Host $AppVersion }
  "-V" { Write-Host $AppVersion }
  "--version" { Write-Host $AppVersion }
  "-h" { Show-Usage }
  "--help" { Show-Usage }
  "help" { Show-Usage }
  default { Show-Usage; exit 1 }
}
