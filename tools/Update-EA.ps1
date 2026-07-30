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
  [switch] $Force
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
if (-not (Test-Path $configPath)) {
  # Best-effort auto-detection so first run is close to zero-config.
  $editor = Get-ChildItem 'C:\Program Files','C:\Program Files (x86)' -Filter 'MetaEditor*.exe' `
              -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
  $dataDirs = Get-ChildItem "$env:APPDATA\MetaQuotes\Terminal" -Directory -ErrorAction SilentlyContinue |
              Where-Object { Test-Path (Join-Path $_.FullName 'MQL5\Experts') } |
              Select-Object -ExpandProperty FullName

  # NOTE: `if` is a statement, not an expression, so it must be wrapped in
  # $( ) to be used as a hashtable value - otherwise this fails to parse.
  @{
    bridgeUrl      = 'https://7r4d3-production.up.railway.app'
    token          = ''
    metaEditorPath = $(if ($editor) { $editor } else { 'C:\Program Files\MetaTrader 5\MetaEditor64.exe' })
    terminalDataDir= $(if ($dataDirs) { @($dataDirs)[0] } else { "$env:APPDATA\MetaQuotes\Terminal\<your-hash>" })
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
  $meta = (Invoke-RestMethod "$($cfg.bridgeUrl)/api/source" -Headers $headers -TimeoutSec 20).sources.$Platform
} catch {
  Die "could not reach the bridge - $($_.Exception.Message)`n  (a 401 means the token is wrong)"
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

Say ''
Say "  $result" 'Green'
Say "  Installed v$($meta.version) into $expertsDir" 'Green'
Say ''
Say '  MT5 reloads a recompiled EA automatically. If the chart still shows the' 'Gray'
Say '  old build, remove the EA and drag it back on.' 'Gray'
Say ''
Read-Host 'Press Enter to close'
