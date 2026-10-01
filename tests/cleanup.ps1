$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../install.ps1')
function Exit-Die([string]$message) { throw $message }
function Stop-Web { return 2 }
function Get-NpxCacheDir { return (Join-Path $script:Fixture 'npm-cache/_npx') }
function Assert-True([bool]$condition, [string]$message) { if (-not $condition) { throw $message } }
function Assert-Aborts([scriptblock]$action) {
  $failed = $false
  try { & $action } catch { $failed = $true }
  Assert-True $failed 'Expected cleanup to fail'
}
function Reset-Fixture {
  $script:Fixture = Join-Path ([IO.Path]::GetTempPath()) ('utility-cleanup-' + [guid]::NewGuid())
  New-Item -ItemType Directory -Path $Fixture -Force | Out-Null
  $script:Fixture = (Get-Item -LiteralPath $Fixture).FullName
  $script:HomeDir = Join-Path $Fixture 'user'
  $script:CfgDir = Join-Path $Fixture 'dsh-installer'
  $script:BinDir = Join-Path $CfgDir 'bin'
  $script:NodeDir = Join-Path $CfgDir 'node'
  $script:ConfigFile = Join-Path $CfgDir 'config.json'
  $script:PidFile = Join-Path $CfgDir 'web.pid'
  $script:LogFile = Join-Path $CfgDir 'web.log'
  $script:ErrLogFile = Join-Path $CfgDir 'web.err.log'
  $script:RunScript = Join-Path $CfgDir 'run-web.cmd'
  $script:Launcher = Join-Path $BinDir 'dsh-web.cmd'
  $script:CliLink = Join-Path $BinDir 'dsh-installer.cmd'
  $script:DshHome = Join-Path $Fixture '数据 % ! & home'
  $script:InstallDir = Join-Path $Fixture 'source'
  $script:DshHomeOverride = ''
  $script:Mode = 'npx'; $script:Yes = $true; $script:Quiet = $true
  $script:DryRun = $false; $script:CleanupFailed = $false
  $script:IsWin = $false # PATH/CIM integration belongs to the Windows-only case below.
  foreach ($path in @($HomeDir, $CfgDir, $BinDir, $DshHome)) { New-Item -ItemType Directory -Path $path -Force | Out-Null }
  New-Item -ItemType File -Path (Join-Path $DshHome '.dsh-installer-home') -Force | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $DshHome 'cache/attachments') -Force | Out-Null
  Save-Config
}
function New-CacheEntry([string]$entry, [string]$name = '@deepseek-ai/dsh') {
  $root = Join-Path (Get-NpxCacheDir) $entry
  $pkg = Join-Path $root 'node_modules/@deepseek-ai/dsh'
  New-Item -ItemType Directory -Path $pkg -Force | Out-Null
  @{ name = $name } | ConvertTo-Json | Set-Content (Join-Path $pkg 'package.json')
  return $root
}
function New-SourceRepo {
  New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
  & git -C $InstallDir init --quiet
  '{"name":"@deepseek-ai/dsh-root"}' | Set-Content (Join-Path $InstallDir 'package.json')
  & git -C $InstallDir add .
  & git -C $InstallDir -c user.name=Test -c user.email=test@example.invalid commit --quiet -m initial
  & git -C $InstallDir update-ref refs/remotes/origin/main HEAD
  New-Item -ItemType File -Path (Join-Path $InstallDir '.git/dsh-installer-owned') -Force | Out-Null
  $script:Mode = 'source'
  Save-Config
}
$cases = [ordered]@{
  'dry run preserves files and does not stop the service' = {
    $entry = New-CacheEntry 'owned'
    $before = @(Get-ChildItem $Fixture -Recurse -Force | Select-Object -ExpandProperty FullName)
    Invoke-Uninstall @('--purge', '--dry-run')
    $after = @(Get-ChildItem $Fixture -Recurse -Force | Select-Object -ExpandProperty FullName)
    Assert-True (@(Compare-Object $before $after).Count -eq 0) 'Dry run mutated files'
  }
  'purge deletes custom home and private runtimes' = {
    $entry = New-CacheEntry 'owned'
    $other = New-CacheEntry 'unrelated' 'other-package'
    foreach ($dir in @($NodeDir, (Join-Path $CfgDir 'pnpm'))) {
      New-Item -ItemType Directory -Path $dir -Force | Out-Null
      New-Item -ItemType File -Path (Join-Path $dir '.installed-by-dsh-installer') -Force | Out-Null
    }
    Write-RunScript
    # Avoid user PATH changes while generating command files for this isolated test.
    function Add-ToUserPath { }
    Write-Launcher
    Invoke-Uninstall @('--purge', '-y')
    foreach ($path in @($DshHome, $entry, $NodeDir, $Launcher, $CliLink, $ConfigFile)) { Assert-True (-not (Test-Path -LiteralPath $path)) "Retained $path" }
    Assert-True (Test-Path $other) 'Deleted unrelated npm cache'
  }
  'default uninstall preserves data and unknown Node' = {
    New-Item -ItemType Directory -Path $NodeDir -Force | Out-Null
    'user program' | Set-Content $Launcher
    'keep' | Set-Content (Join-Path $CfgDir 'notes.txt')
    Invoke-Uninstall @('-y')
    foreach ($path in @($DshHome, $NodeDir, $Launcher, (Join-Path $CfgDir 'notes.txt'))) { Assert-True (Test-Path -LiteralPath $path) "Deleted $path" }
  }
  'saved home is exported in Unicode command files' = {
    $expected = $DshHome
    $script:DshHome = Join-Path $Fixture 'wrong-home'
    Load-Config
    Assert-True ($DshHome -eq $expected) 'Lost saved custom home'
    Write-RunScript
    $text = Get-Content -LiteralPath $RunScript -Raw -Encoding UTF8
    Assert-True ($text.Contains($expected.Replace('%', '%%'))) 'Home missing from launcher'
    Assert-True ($text.Contains('DisableDelayedExpansion')) 'Unsafe CMD delayed expansion'
  }
  'owned clean source and npx cache removed together' = {
    New-SourceRepo
    $entry = New-CacheEntry 'owned'
    Invoke-Uninstall @('-y')
    Assert-True (-not (Test-Path $InstallDir)) 'Retained owned source'
    Assert-True (-not (Test-Path $entry)) 'Retained npx cache in source mode'
  }
  'dirty source retained even with yes' = {
    New-SourceRepo
    'work' | Set-Content (Join-Path $InstallDir 'work.txt')
    Assert-Aborts { Invoke-Uninstall @('-y') }
    Assert-True (Test-Path (Join-Path $InstallDir 'work.txt')) 'Deleted local work'
    Assert-True (Test-Path $ConfigFile) 'Deleted retry config'
  }
  'unpublished commits retained even with yes' = {
    New-SourceRepo
    'work' | Set-Content (Join-Path $InstallDir 'work.txt')
    & git -C $InstallDir add .
    & git -C $InstallDir -c user.name=Test -c user.email=test@example.invalid commit --quiet -m local
    Assert-Aborts { Invoke-Uninstall @('-y') }
    Assert-True (Test-Path $InstallDir) 'Deleted unpublished source'
  }
  'stop failure aborts before any deletion' = {
    function Stop-Web { return 1 }
    Assert-Aborts { Invoke-Uninstall @('--purge', '-y') }
    Assert-True (Test-Path $DshHome) 'Deleted data while stop failed'
    Assert-True (Test-Path $ConfigFile) 'Deleted config while stop failed'
  }
  'unsafe data root rejected before cleanup' = {
    $script:DshHome = $HomeDir; $script:DshHomeOverride = $HomeDir
    Assert-Aborts { Invoke-Uninstall @('--purge', '-y') }
    Assert-True (Test-Path $ConfigFile) 'Deleted config before path validation'
  }
  'temp cleanup requires purge' = {
    Assert-Aborts { Invoke-Uninstall @('--purge-temp', '-y') }
    Assert-True (Test-Path $ConfigFile) 'Changed config with invalid flags'
  }
  'tilde and blank home match official resolution' = {
    $script:DshHome = '  '; Set-DshHome
    Assert-True ($DshHome -eq (Join-Path $HomeDir '.dsh')) 'Wrong blank-home default'
    $script:DshHome = '~/custom'; Set-DshHome
    Assert-True ($DshHome -eq (Join-Path $HomeDir 'custom')) 'Wrong tilde expansion'
  }
}
if ($env:OS -eq 'Windows_NT') {
  $cases['Windows CMD launcher retains Unicode percent and exclamation paths'] = {
    $script:IsWin = $true
    $script:Mode = 'source'
    $script:InstallDir = $HomeDir
    $script:Quiet = $true
    Write-RunScript
    $fakePnpm = Join-Path $CfgDir 'pnpm'
    New-Item -ItemType Directory -Path $fakePnpm -Force | Out-Null
    Write-CmdScript (Join-Path $fakePnpm 'pnpm.cmd') @('@echo off', 'echo "%DSH_HOME%"')
    $previousEncoding = [Console]::OutputEncoding
    try {
      [Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
      $result = (& cmd.exe /d /c $RunScript) -join "`n"
    } finally { [Console]::OutputEncoding = $previousEncoding }
    Assert-True ($LASTEXITCODE -eq 0) 'CMD launcher failed'
    Assert-True ($result.Contains($DshHome)) "CMD changed DSH_HOME: $result"
  }
  $cases['Windows junction data root is rejected'] = {
    $target = Join-Path $Fixture 'target'
    New-Item -ItemType Directory -Path $target -Force | Out-Null
    $link = Join-Path $Fixture 'junction'
    New-Item -ItemType Junction -Path $link -Target $target | Out-Null
    $script:DshHome = $link; $script:DshHomeOverride = $link
    Assert-Aborts { Invoke-Uninstall @('--purge', '-y') }
    Assert-True (Test-Path $target) 'Deleted junction target'
    Remove-Item -LiteralPath $link -Force
  }
}
$failures = 0
foreach ($case in $cases.GetEnumerator()) {
  Reset-Fixture
  try { & $case.Value; Write-Host "PASS $($case.Key)" }
  catch { $failures++; Write-Host "FAIL $($case.Key): $_" }
  finally { Remove-Item -LiteralPath $Fixture -Recurse -Force }
}
if ($failures) { throw "$failures cleanup regressions failed" }
Write-Host "$($cases.Count) cleanup regressions passed"
