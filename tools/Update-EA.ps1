<#
  RiskManager - one-click EA updater.

  Pulls the current source from the web bridge, installs it into the
  terminal's Experts folder, compiles it, and reports the result.
  Backs up the previous version first and rolls back on a failed compile,
  so a bad build can never be left installed.

  Usage:  double-click Update-EA.bat, or:
            powershell -ExecutionPolicy Bypass -File Update-EA.ps1
          Options:
            -Platform mq4     update the MT4 build instead
            -Force            reinstall even if already up to date
#>

param(
  [ValidateSet('mq5', 'mq4')] [string] $Platform = 'mq5',
  [switch] $Force,
  [switch] $NoSelfUpdate   # set internally after a self-update, to stop recursion
)

$ErrorActionPreference = 'Stop'
$here       = Split-Path -Parent $MyInvocation.MyCommand.Path
$configPath = Join-Path $here 'updater.config.json'
$markerPath = Join-Path $here ".installed.$Platform.json"

function Say($msg, $colour = 'Gray') { Write-Host $msg -ForegroundColor $colour }
function Die($msg) { Say ''; Say "  FAILED: $msg" 'Red'; Say ''; Read-Host 'Press Enter to close'; exit 1 }

Say ''
Say '  RiskManager EA updater' 'Cyan'
Say '  ----------------------' 'Cyan'

# -- config ---------------------------------------------------------
function Find-MetaEditor {
  Get-ChildItem 'C:\Program Files','C:\Program Files (x86)' -Filter 'MetaEditor*.exe' `
    -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
}
function Find-DataDirs {
  Get-ChildItem "$env:APPDATA\MetaQuotes\Terminal" -Directory -ErrorAction SilentlyContinue |
    Where-Object { Test-Path (Join-Path $_.FullName 'MQL5\Experts') } |
    Select-Object -ExpandProperty FullName
}

# MetaTrader names each installation's data folder after a hash of its install
# path, so the folder name alone is meaningless to a human. origin.txt inside
# it holds the actual install path - that is what makes the list readable.
# (It is UTF-16, so it must be read with -Encoding Unicode.)
function Get-TerminalLabel($dir) {
  $origin = Join-Path $dir 'origin.txt'
  $install = if (Test-Path $origin) {
    ((Get-Content $origin -Encoding Unicode -ErrorAction SilentlyContinue) -join '').Trim()
  } else { '' }
  $has = Test-Path (Join-Path $dir 'MQL5\Experts\RiskManager.ex5')
  [pscustomobject]@{
    Dir       = $dir
    Install   = $(if ($install) { $install } else { '(install path unknown)' })
    HasEa     = $has
    Short     = (Split-Path $dir -Leaf).Substring(0, 8)
  }
}

# Ask which terminal to target when more than one is present, rather than
# guessing or making the user hand-edit a hash into JSON.
function Select-TerminalDir($dirs) {
  $items = @($dirs | ForEach-Object { Get-TerminalLabel $_ })
  Say ''
  Say '  Multiple MetaTrader installations found:' 'Yellow'
  for ($i = 0; $i -lt $items.Count; $i++) {
    $m = $items[$i]
    Say ("    [{0}] {1}" -f ($i + 1), $m.Install) 'White'
    Say ("        {0}...  {1}" -f $m.Short, $(if ($m.HasEa) { 'RiskManager already installed' } else { 'no RiskManager yet' })) 'DarkGray'
  }
  Say ''
  while ($true) {
    $pick = Read-Host "  Which one? [1-$($items.Count)]"
    if ($pick -match '^\d+$' -and [int]$pick -ge 1 -and [int]$pick -le $items.Count) {
      return $items[[int]$pick - 1].Dir
    }
    Say '  Enter a number from the list.' 'Yellow'
  }
}

if (-not (Test-Path $configPath)) {
  $editor   = Find-MetaEditor
  $dataDirs = Find-DataDirs

  # NOTE: `if` is a statement, not an expression, so it must be wrapped in
  # $( ) to be used as a hashtable value - otherwise this fails to parse.
  @{
    bridgeUrl      = 'https://7r4d3-production.up.railway.app'
    token          = ''
    metaEditorPath = $(if ($editor) { $editor } else { '' })
    terminalDataDir= $(if ($dataDirs) { @($dataDirs)[0] } else { '' })
  } | ConvertTo-Json | Set-Content $configPath -Encoding UTF8

  Say ''
  Say "  Created $configPath" 'Yellow'
  Say '  Fill in "token" (your RM_TOKEN) and check the detected paths, then run again.' 'Yellow'
  if ($dataDirs.Count -gt 1) {
    Say ''
    Say '  Multiple terminals found - pick the right terminalDataDir:' 'Yellow'
    $dataDirs | ForEach-Object { Say "    $_" }
  }
  Say ''
  Read-Host 'Press Enter to close'; exit 0
}

$cfg = Get-Content $configPath -Raw | ConvertFrom-Json

# A config downloaded from the dashboard arrives with the token filled in but
# the machine-specific paths blank. Detect them here and write them back, so
# the bootstrap really is "download, run".
$patched = $false
# Terminal first, then MetaEditor - so the compiler can be taken from the SAME
# installation as the target terminal. A MetaEditor from a different install
# may not resolve <Trade\Trade.mqh> against the right Include folder.
if (-not $cfg.terminalDataDir) {
  $dirs = @(Find-DataDirs)
  if ($dirs.Count -eq 0) {
    Die ("no MetaTrader data folder found under $env:APPDATA\MetaQuotes\Terminal.`n" +
         "  If the terminal runs in portable mode its data sits next to the .exe -`n" +
         "  set terminalDataDir in updater.config.json to that folder.")
  }
  elseif ($dirs.Count -eq 1) {
    $cfg.terminalDataDir = $dirs[0]
    $patched = $true
    Say "  Detected terminal: $((Get-TerminalLabel $dirs[0]).Install)"
  }
  else {
    $cfg.terminalDataDir = Select-TerminalDir $dirs
    $patched = $true
    Say "  Using: $((Get-TerminalLabel $cfg.terminalDataDir).Install)" 'Green'
    Say '  (change terminalDataDir in updater.config.json to switch later)' 'DarkGray'
  }
}

if (-not $cfg.metaEditorPath) {
  # Prefer the MetaEditor that ships with the chosen terminal.
  $install = (Get-TerminalLabel $cfg.terminalDataDir).Install
  $sibling = @('MetaEditor64.exe', 'metaeditor.exe') |
             ForEach-Object { Join-Path $install $_ } |
             Where-Object { Test-Path $_ } | Select-Object -First 1
  $found = if ($sibling) { $sibling } else { Find-MetaEditor }
  if (-not $found) { Die 'MetaEditor not found - set metaEditorPath in updater.config.json' }
  $cfg.metaEditorPath = $found
  $patched = $true
  Say "  Using MetaEditor: $found"
}
if ($patched) { $cfg | ConvertTo-Json | Set-Content $configPath -Encoding UTF8 }
if (-not $cfg.token)                        { Die "token is empty in $configPath" }
if (-not (Test-Path $cfg.metaEditorPath))   { Die "MetaEditor not found at $($cfg.metaEditorPath)" }
if (-not (Test-Path $cfg.terminalDataDir))  { Die "Terminal data folder not found at $($cfg.terminalDataDir)" }

$mqlDir     = Join-Path $cfg.terminalDataDir ($(if ($Platform -eq 'mq5') { 'MQL5' } else { 'MQL4' }))
$expertsDir = Join-Path $mqlDir 'Experts'
if (-not (Test-Path $expertsDir)) { Die "Experts folder not found at $expertsDir" }

$headers  = @{ Authorization = "Bearer $($cfg.token)" }
$srcFile  = Join-Path $expertsDir "RiskManager.$Platform"
$exFile   = Join-Path $expertsDir ("RiskManager." + $(if ($Platform -eq 'mq5') { 'ex5' } else { 'ex4' }))

# -- what's available -----------------------------------------------
Say "  Bridge : $($cfg.bridgeUrl)"
Say "  Target : $expertsDir"
Say ''
try {
  $all  = (Invoke-RestMethod "$($cfg.bridgeUrl)/api/source" -Headers $headers -TimeoutSec 20).sources
  $meta = $all.$Platform
} catch {
  Die "could not reach the bridge - $($_.Exception.Message)`n  (a 401 means the token is wrong)"
}

# -- self-update ----------------------------------------------------
# The script replaces itself when the bridge publishes a newer one, then
# re-runs. That is what lets Update-EA.bat remain the only file anyone ever
# has to download by hand - improvements to the updater arrive on their own.
if (-not $NoSelfUpdate -and $all.ps1 -and $all.ps1.available) {
  $me     = $MyInvocation.MyCommand.Path
  $mySha  = (Get-FileHash $me -Algorithm SHA256).Hash.Substring(0, 12).ToLower()
  if ($mySha -ne $all.ps1.sha256) {
    Say ''
    Say "  Updater itself is out of date ($mySha -> $($all.ps1.sha256)) - updating." 'Yellow'
    $tmpPs = Join-Path $env:TEMP 'Update-EA.new.ps1'
    Invoke-WebRequest "$($cfg.bridgeUrl)/api/source/ps1" -Headers $headers -OutFile $tmpPs -TimeoutSec 60
    # Sanity-check before overwriting ourselves: a truncated or error-body
    # download must not be able to brick the updater.
    $err = $null
    [System.Management.Automation.Language.Parser]::ParseFile($tmpPs, [ref]$null, [ref]$err) > $null
    if ($err.Count -or (Get-Item $tmpPs).Length -lt 2000) {
      Say '  Downloaded updater failed its syntax check - keeping the current one.' 'Red'
      Remove-Item $tmpPs -Force -ErrorAction SilentlyContinue
    } else {
      Copy-Item $me (Join-Path $env:TEMP 'Update-EA.previous.ps1') -Force
      Copy-Item $tmpPs $me -Force
      Remove-Item $tmpPs -Force
      Say '  Updated. Re-running the new version...' 'Green'
      & powershell -NoProfile -ExecutionPolicy Bypass -File $me -Platform $Platform -NoSelfUpdate @(if ($Force) { '-Force' })
      exit $LASTEXITCODE
    }
  }
}
if (-not $meta.available) { Die "$Platform is not available on this deployment" }

Say "  Available : v$($meta.version)  $([math]::Round($meta.bytes/1KB)) KB  $($meta.sha256)"

$installed = if (Test-Path $markerPath) { Get-Content $markerPath -Raw | ConvertFrom-Json } else { $null }
if ($installed) { Say "  Installed : v$($installed.version)  $($installed.sha256)" }

if ($installed -and $installed.sha256 -eq $meta.sha256 -and -not $Force) {
  Say ''
  Say '  Already up to date.' 'Green'
  Say ''
  Read-Host 'Press Enter to close'; exit 0
}

# -- pre-flight warning ---------------------------------------------
# Compiling reloads the EA. On-chart state now survives that (OnDeinit
# persists it), but an open position is still worth knowing about.
try {
  $st = (Invoke-RestMethod "$($cfg.bridgeUrl)/api/state" -Headers $headers -TimeoutSec 10).state
  if ($st) {
    $open = [int]$st.exposure.openCount
    $mtx  = [int]$st.matrices.active
    if ($open -gt 0 -or $mtx -gt 0 -or $st.armed.active) {
      Say ''
      Say "  NOTE: EA currently has $open open position(s), $mtx active matrix/matrices$(if ($st.armed.active) { ', an armed setup' })." 'Yellow'
      Say '  Compiling reloads the EA. Lines and matrices are restored automatically,' 'Yellow'
      Say '  but nothing protective runs during the brief reload.' 'Yellow'
      if ((Read-Host '  Continue? (y/N)') -ne 'y') { Say '  Cancelled.'; exit 0 }
    }
  }
} catch { Say '  (could not read live state - continuing)' 'DarkGray' }

# -- backup ---------------------------------------------------------
$backupDir = Join-Path $here 'backup'
New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
foreach ($f in @($srcFile, $exFile)) {
  if (Test-Path $f) { Copy-Item $f (Join-Path $backupDir "$stamp-$(Split-Path $f -Leaf)") -Force }
}
Say ''
Say "  Backed up to $backupDir"

# -- download -------------------------------------------------------
Say '  Downloading...'
$tmp = Join-Path $env:TEMP "RiskManager.$Platform.new"
Invoke-WebRequest "$($cfg.bridgeUrl)/api/source/$Platform" -Headers $headers -OutFile $tmp -TimeoutSec 60
if ((Get-Item $tmp).Length -lt 10000) { Die 'downloaded file is implausibly small - aborting' }
Copy-Item $tmp $srcFile -Force
Remove-Item $tmp -Force

# -- compile --------------------------------------------------------
Say '  Compiling...'
$log = Join-Path $env:TEMP "RiskManager.$Platform.log"
if (Test-Path $log) { Remove-Item $log -Force }
# /include matters: without it MetaEditor may fail to resolve <Trade\Trade.mqh>
Start-Process -FilePath $cfg.metaEditorPath -Wait -NoNewWindow -ArgumentList @(
  "/compile:`"$srcFile`"", "/include:`"$mqlDir`"", "/log:`"$log`""
)

# MetaEditor writes the log as UTF-16LE; reading it as UTF-8 gives garbage.
$out = if (Test-Path $log) { Get-Content $log -Encoding Unicode } else { @() }
$result = ($out | Where-Object { $_ -match 'Result:|result ' } | Select-Object -Last 1)
$errs   = ($out | Where-Object { $_ -match ':\s*error\s' })

if ($errs -or -not $result -or $result -notmatch '0 error') {
  Say ''
  Say '  Compile FAILED - rolling back.' 'Red'
  $errs | Select-Object -First 10 | ForEach-Object { Say "    $_" 'Red' }
  $prev = Get-ChildItem $backupDir -Filter "*-RiskManager.$Platform" | Sort-Object Name | Select-Object -Last 1
  if ($prev) {
    Copy-Item $prev.FullName $srcFile -Force
    Start-Process -FilePath $cfg.metaEditorPath -Wait -NoNewWindow -ArgumentList @(
      "/compile:`"$srcFile`"", "/include:`"$mqlDir`"", "/log:`"$log`""
    )
    Say '  Previous version restored and recompiled.' 'Yellow'
  } else {
    Say '  No backup to restore from.' 'Red'
  }
  Say ''; Read-Host 'Press Enter to close'; exit 1
}

@{ version = $meta.version; sha256 = $meta.sha256; installed = (Get-Date -Format 'o') } |
  ConvertTo-Json | Set-Content $markerPath -Encoding UTF8

# -- chart template (optional) --------------------------------------
# Downloaded as raw bytes: .tpl is UTF-16LE and MetaTrader will reject it
# if anything re-encodes it on the way in.
if ($Platform -eq 'mq5') {
  try {
    $tplMeta = (Invoke-RestMethod "$($cfg.bridgeUrl)/api/source" -Headers $headers -TimeoutSec 20).sources.tpl
    if ($tplMeta.available) {
      $tplDir = Join-Path $mqlDir 'Profiles\Templates'
      if (Test-Path $tplDir) {
        $tplPath = Join-Path $tplDir 'default.tpl'
        if (Test-Path $tplPath) {
          Copy-Item $tplPath (Join-Path $backupDir "$stamp-default.tpl") -Force
        }
        Invoke-WebRequest "$($cfg.bridgeUrl)/api/source/tpl" -Headers $headers -OutFile $tplPath -TimeoutSec 60
        Say "  Installed default.tpl into $tplDir" 'Green'
      }
    }
  } catch { Say '  (template not installed - continuing)' 'DarkGray' }
}

Say ''
Say "  $result" 'Green'
Say "  Installed v$($meta.version) into $expertsDir" 'Green'
Say ''
Say '  MT5 reloads a recompiled EA automatically. If the chart still shows the' 'Gray'
Say '  old build, remove the EA and drag it back on.' 'Gray'
Say ''
Read-Host 'Press Enter to close'
