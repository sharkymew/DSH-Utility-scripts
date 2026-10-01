$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../install.ps1')
$script:OriginalPath = $env:Path
$script:OriginalScriptPath = $PsScriptPath
function Exit-Die([string]$message) { throw $message }
function Stop-Web { return 2 }
function Confirm-ExternalRemoval([string]$message) { return $false }
function Get-NpxCacheDir { return (Join-Path $script:Fixture 'npm-cache/_npx') }
function Assert-True([bool]$condition, [string]$message) { if (-not $condition) { throw $message } }
function Assert-Aborts([scriptblock]$action) {
  $failed = $false
  try { & $action } catch { $failed = $true }
  Assert-True $failed 'Expected cleanup to fail'
}
function Reset-Fixture {
  $env:Path = $script:OriginalPath
  $script:PsScriptPath = $script:OriginalScriptPath
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
  $script:Registry = ''; $script:BindHost = '127.0.0.1'; $script:Port = 3080
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
function Assert-LocalRefProtected([string]$kind, [string]$mode) {
  New-SourceRepo
  & git -C $InstallDir remote add origin 'https://github.com/deepseek-ai/deepseek-harness.git'
  $originalBranch = [string](& git -C $InstallDir symbolic-ref --short HEAD)
  if ($kind -eq 'branch') { & git -C $InstallDir checkout --quiet -b local-work }
  'unpublished work' | Set-Content (Join-Path $InstallDir 'work.txt')
  & git -C $InstallDir add .
  if ($kind -eq 'branch') {
    & git -C $InstallDir -c user.name=Test -c user.email=test@example.invalid commit --quiet -m local
    & git -C $InstallDir checkout --quiet $originalBranch
    $retainedRef = 'refs/heads/local-work'
  } else {
    & git -C $InstallDir -c user.name=Test -c user.email=test@example.invalid stash push --quiet -m local
    $retainedRef = 'refs/stash'
  }
  Assert-True (-not (& git -C $InstallDir status --porcelain)) 'Fixture is not clean'
  $script:Mode = $mode
  Save-Config
  Assert-True (-not (Test-SafeExternalSourceRepo $InstallDir)) "External cleanup accepted local $kind"
  Assert-Aborts { Invoke-Uninstall @('-y') }
  Assert-True (Test-Path -LiteralPath $InstallDir) "Deleted local $kind in $mode mode"
  Assert-True (Test-Path -LiteralPath $ConfigFile) 'Deleted retry config'
  & git -C $InstallDir show-ref --verify --quiet $retainedRef
  Assert-True ($LASTEXITCODE -eq 0) "Lost $retainedRef"
}
function New-LegacyLaunchers {
  # Deliberately reproduce v1.2, independently of the production writers.
  $lines = @('@echo off')
  if ($Mode -eq 'source') {
    $lines += 'cd /d "' + $InstallDir + '"'
    $lines += "call pnpm.cmd dsh web --host $BindHost --port $Port"
  } else {
    $lines += 'cd /d "%USERPROFILE%"'
    if ($Registry) { $lines += 'set "NPM_CONFIG_REGISTRY=' + $Registry + '"' }
    $lines += "call npx.cmd --yes @deepseek-ai/dsh web --host $BindHost --port $Port"
  }
  Set-Content -LiteralPath $Launcher -Value $lines -Encoding Ascii
  # Preserve the actual v1.2 expression: comma binds before +, yielding 4 lines.
  Set-Content -LiteralPath $CliLink -Value @('@echo off', 'powershell -NoProfile -ExecutionPolicy Bypass -File "' + $PsScriptPath + '" %*') -Encoding Ascii
  $expectedCli = @('@echo off', 'powershell -NoProfile -ExecutionPolicy Bypass -File "', $PsScriptPath, '" %*')
  $actualCli = @(Get-Content -LiteralPath $CliLink -Encoding Ascii)
  Assert-True ($actualCli.Count -eq 4 -and ($actualCli -join "`n") -ceq ($expectedCli -join "`n")) 'Legacy fixture did not reproduce the four-line CLI wrapper'
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
    $cliLines = @(Get-Content -LiteralPath $CliLink -Encoding UTF8)
    $expectedCommand = 'powershell -NoProfile -ExecutionPolicy Bypass -File "' + $PsScriptPath.Replace('%', '%%') + '" %*'
    Assert-True ($cliLines.Count -eq 5 -and $cliLines[4] -ceq $expectedCommand) 'Generated CLI command was split across lines'
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
  'non-HEAD local branch retained in source mode' = { Assert-LocalRefProtected 'branch' 'source' }
  'non-HEAD local branch retained after switching to npx' = { Assert-LocalRefProtected 'branch' 'npx' }
  'stash retained in source mode' = { Assert-LocalRefProtected 'stash' 'source' }
  'stash retained after switching to npx' = { Assert-LocalRefProtected 'stash' 'npx' }
  'legacy npx launchers with saved settings are removed' = {
    $script:Registry = 'https://registry.example.invalid'
    $script:Port = 4567
    Save-Config
    New-LegacyLaunchers
    Invoke-Uninstall @('-y')
    Assert-True (-not (Test-Path -LiteralPath $Launcher)) 'Retained legacy web launcher'
    Assert-True (-not (Test-Path -LiteralPath $CliLink)) 'Retained legacy CLI launcher'
  }
  'legacy source launchers are removed' = {
    New-SourceRepo
    New-LegacyLaunchers
    Invoke-Uninstall @('-y')
    Assert-True (-not (Test-Path -LiteralPath $Launcher)) 'Retained legacy source launcher'
    Assert-True (-not (Test-Path -LiteralPath $CliLink)) 'Retained legacy CLI launcher'
  }
  'corrected two-line legacy CLI launcher is removed' = {
    New-LegacyLaunchers
    $corrected = @('@echo off', ('powershell -NoProfile -ExecutionPolicy Bypass -File "' + $PsScriptPath + '" %*'))
    Set-Content -LiteralPath $CliLink -Value $corrected -Encoding Ascii
    Assert-True (@(Get-Content -LiteralPath $CliLink).Count -eq 2) 'Fixture must have two complete lines'
    Invoke-Uninstall @('-y')
    Assert-True (-not (Test-Path -LiteralPath $CliLink)) 'Retained corrected legacy CLI wrapper'
  }
  'modified legacy launchers and another script are preserved' = {
    New-LegacyLaunchers
    Add-Content -LiteralPath $Launcher -Value 'echo user customization' -Encoding Ascii
    $otherScript = Join-Path $Fixture 'other.ps1'
    'Write-Host user' | Set-Content -LiteralPath $otherScript
    Set-Content -LiteralPath $CliLink -Value @('@echo off', 'powershell -NoProfile -ExecutionPolicy Bypass -File "' + $otherScript + '" %*') -Encoding Ascii
    Invoke-Uninstall @('-y')
    Assert-True (Test-Path -LiteralPath $Launcher) 'Deleted modified launcher'
    Assert-True (Test-Path -LiteralPath $CliLink) 'Deleted unrelated CLI wrapper'
  }
  'legacy launchers without saved config are preserved' = {
    New-LegacyLaunchers
    Remove-Item -LiteralPath $ConfigFile
    Invoke-Uninstall @('-y')
    Assert-True (Test-Path -LiteralPath $Launcher) 'Guessed legacy web ownership without config'
    Assert-True (Test-Path -LiteralPath $CliLink) 'Guessed legacy CLI ownership without config'
  }
  'legacy settings mismatch and marker lookalikes are preserved' = {
    New-LegacyLaunchers
    $script:Port = 4567
    Save-Config
    Set-Content -LiteralPath $CliLink -Value @('@echo off', 'echo Generated by dsh-installer 1.3.0') -Encoding Ascii
    Invoke-Uninstall @('-y')
    Assert-True (Test-Path -LiteralPath $Launcher) 'Deleted launcher with unmatched saved settings'
    Assert-True (Test-Path -LiteralPath $CliLink) 'Deleted ownership marker lookalike'
  }
  'empty unowned launchers are preserved without aborting cleanup' = {
    New-Item -ItemType File -Path $Launcher -Force | Out-Null
    New-Item -ItemType File -Path $CliLink -Force | Out-Null
    Invoke-Uninstall @('-y')
    Assert-True (Test-Path -LiteralPath $Launcher) 'Deleted empty user launcher'
    Assert-True (Test-Path -LiteralPath $CliLink) 'Deleted empty user CLI wrapper'
    Assert-True (-not (Test-Path -LiteralPath $ConfigFile)) 'Cleanup failed for an empty user file'
  }
  'owned runtimes precede system PATH without accumulating entries' = {
    $pnpmDir = Join-Path $CfgDir 'pnpm'
    foreach ($dir in @($NodeDir, $pnpmDir)) {
      New-Item -ItemType Directory -Path $dir -Force | Out-Null
      New-Item -ItemType File -Path (Join-Path $dir '.installed-by-dsh-installer') -Force | Out-Null
    }
    $systemNode = Join-Path $Fixture 'old-system-node'
    $separator = [string][IO.Path]::PathSeparator
    $env:Path = $systemNode + $separator + $OriginalPath
    Load-Config
    Use-PrivateRuntimes
    $parts = @($env:Path -split [regex]::Escape($separator))
    Assert-True ($parts[0] -eq $NodeDir -and $parts[1] -eq $pnpmDir -and $parts[2] -eq $systemNode) 'Private Node did not take precedence'
    Assert-True (@($parts | Where-Object { $_ -eq $NodeDir }).Count -eq 1) 'Duplicated Node PATH entry'
    Remove-Item -LiteralPath (Join-Path $NodeDir '.installed-by-dsh-installer')
    $env:Path = $systemNode + $separator + $OriginalPath
    Load-Config
    Assert-True (-not (@($env:Path -split [regex]::Escape($separator)) -contains $NodeDir)) 'Preferred an unowned Node directory'
  }
  'CIM process guard recognizes Windows package paths before cleanup' = {
    $script:IsWin = $true
    function Get-CimInstance {
      [CmdletBinding()] param([string]$ClassName)
      return $script:FixtureProcesses
    }
    # If the temp guard regresses, prevent this test from enumerating real TEMP.
    function Get-ChildItem { throw 'Unexpected filesystem enumeration' }
    foreach ($commandLine in @(
      '"C:\Program Files\nodejs\node.exe" "C:\npm\node_modules\@deepseek-ai\dsh\lib\bin.js" web',
      '"C:\node.exe" "C:\npm/node_modules/@deepseek-ai/dsh/lib/bin.js" web',
      'node C:\source\apps\cli\src\bin.ts web',
      'node C:\source\deepseek-harness\packages\web\lib\index.js',
      'node C:\npm\npm-cli.js exec --yes @deepseek-ai/dsh web',
      'node C:\npm\npm-cli.js exec --yes @deepseek-ai/dsh@0.2.0-rc.2 web',
      'node C:\npm\npm-cli.js exec --yes @deepseek-ai/dsh@latest web'
    )) {
      $script:FixtureProcesses = @([pscustomobject]@{ Name = 'node.exe'; CommandLine = $commandLine })
      Assert-Aborts { Assert-NoDshProcesses }
      $script:CleanupFailed = $false
      Remove-DshTemp
      Assert-True $CleanupFailed "Temp cleanup missed $commandLine"
    }
    $script:FixtureProcesses = @([pscustomobject]@{ Name = 'node.exe'; CommandLine = 'node C:\npm\node_modules\@deepseek-ai\dsh-unrelated\index.js' })
    Assert-NoDshProcesses
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
    New-Item -ItemType File -Path (Join-Path $fakePnpm '.installed-by-dsh-installer') -Force | Out-Null
    Write-CmdScript (Join-Path $fakePnpm 'pnpm.cmd') @('@echo off', 'echo "%DSH_HOME%"')
    $previousEncoding = [Console]::OutputEncoding
    try {
      [Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
      $result = (& cmd.exe /d /c $RunScript) -join "`n"
    } finally { [Console]::OutputEncoding = $previousEncoding }
    Assert-True ($LASTEXITCODE -eq 0) 'CMD launcher failed'
    Assert-True ($result.Contains($DshHome)) "CMD changed DSH_HOME: $result"
  }
  $cases['Windows launchers prefer owned Node over an older system PATH entry'] = {
    $script:IsWin = $true
    $script:Mode = 'source'
    $script:InstallDir = $HomeDir
    $privatePnpm = Join-Path $CfgDir 'pnpm'
    $systemNode = Join-Path $Fixture 'old-system-node'
    foreach ($dir in @($privatePnpm, $NodeDir, $systemNode)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    foreach ($dir in @($privatePnpm, $NodeDir)) { New-Item -ItemType File -Path (Join-Path $dir '.installed-by-dsh-installer') -Force | Out-Null }
    Write-CmdScript (Join-Path $privatePnpm 'pnpm.cmd') @('@echo off', 'call node.cmd')
    Write-CmdScript (Join-Path $NodeDir 'node.cmd') @('@echo off', 'echo private-node')
    Write-CmdScript (Join-Path $systemNode 'node.cmd') @('@echo off', 'echo old-system-node')
    $env:Path = $systemNode + ';' + $OriginalPath
    Use-PrivateRuntimes
    # Simulate Machine+User PATH reconstruction without touching user settings.
    function Add-ToUserPath { $env:Path = $systemNode + ';' + $OriginalPath }
    Write-RunScript
    Write-Launcher
    foreach ($path in @($RunScript, $Launcher)) {
      $result = (& cmd.exe /d /c $path) -join "`n"
      Assert-True ($LASTEXITCODE -eq 0 -and $result.Contains('private-node') -and -not $result.Contains('old-system-node')) "Wrong Node precedence: $result"
    }
    Remove-Item -LiteralPath (Join-Path $NodeDir '.installed-by-dsh-installer')
    foreach ($path in @($RunScript, $Launcher)) {
      $result = (& cmd.exe /d /c $path) -join "`n"
      Assert-True ($LASTEXITCODE -eq 0 -and $result.Contains('old-system-node') -and -not $result.Contains('private-node')) "Preferred unowned Node: $result"
    }
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
  $cases['Windows CLI wrapper forwards one complete command to fake PowerShell'] = {
    $fakeShell = Join-Path $Fixture 'fake-shell'
    New-Item -ItemType Directory -Path $fakeShell -Force | Out-Null
    $script:PsScriptPath = Join-Path $Fixture 'installer with spaces.ps1'
    'throw "This fixture must never be executed"' | Set-Content -LiteralPath $PsScriptPath
    Write-CmdScript (Join-Path $fakeShell 'powershell.cmd') @('@echo off', 'echo FAKE_POWERSHELL', 'echo script="%~5"', 'echo command="%~6"', 'echo option="%~7"', 'exit /b 0')
    # Exclude real PowerShell from PATH; only the harmless fake can be called.
    $env:Path = $fakeShell + ';' + (Join-Path $env:SystemRoot 'System32')
    function Add-ToUserPath { }
    Write-Launcher
    $result = (& cmd.exe /d /c $CliLink status --json) -join "`n"
    Assert-True ($LASTEXITCODE -eq 0 -and $result.Contains('FAKE_POWERSHELL')) 'CLI wrapper did not invoke the fake PowerShell'
    Assert-True ($result.Contains('script="' + $PsScriptPath + '"')) "Script path was split or lost: $result"
    Assert-True ($result.Contains('command="status"') -and $result.Contains('option="--json"')) "Arguments were not forwarded: $result"
  }
}
$failures = 0
foreach ($case in $cases.GetEnumerator()) {
  Reset-Fixture
  try { & $case.Value; Write-Host "PASS $($case.Key)" }
  catch { $failures++; Write-Host "FAIL $($case.Key): $_" }
  finally { $env:Path = $script:OriginalPath; Remove-Item -LiteralPath $Fixture -Recurse -Force }
}
if ($failures) { throw "$failures cleanup regressions failed" }
Write-Host "$($cases.Count) cleanup regressions passed"
