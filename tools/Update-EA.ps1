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

  Update-EA-GUI.ps1 drives this script with -NonInteractive, which suppresses
  every prompt and appends a single machine-readable ##RESULT## line so the
  window can report exactly what happened. -CheckOnly stops before any change.
#>

param(
  [ValidateSet('mq5', 'mq4')] [string] $Platform = 'mq5',
  [switch] $Force,
  [switch] $NoSelfUpdate,      # set internally after a self-update, to stop recursion
  [switch] $NonInteractive,    # never prompt; emit ##RESULT## json instead
  [switch] $CheckOnly,         # report versions and live state, change nothing
  [switch] $Yes,               # pre-answer the open-position confirmation
  [string] $TerminalDir = '',  # override the configured terminal data folder
  [switch] $ListTerminals,     # enumerate installations and exit
  [string] $SetNickname = ''   # name the -TerminalDir installation and exit
)

$ErrorActionPreference = 'Stop'

# Railway (and most hosts now) refuse TLS 1.0/1.1. PowerShell 5.1 takes the OS
# default, so pin 1.2 explicitly or the first HTTPS call on a fresh machine
# fails in a way that looks like a hang.
try {
  [Net.ServicePointManager]::SecurityProtocol =
    [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }
$here       = Split-Path -Parent $MyInvocation.MyCommand.Path
$configPath = Join-Path $here 'updater.config.json'
# $markerPath and $eaName are resolved after the config is read - the marker is
# per terminal, because one marker for every installation reports "up to date"
# for a terminal that was never touched.
$markerPath = $null
$eaName     = 'RiskManager'

function Say($msg, $colour = 'Gray') { Write-Host $msg -ForegroundColor $colour }

# Every exit routes through here, so the GUI always learns the outcome — the
# whole point of the rewrite was that a silent console left you guessing.
function Finish($code, $obj) {
  if ($NonInteractive) {
    Write-Host ('##RESULT##' + ($obj | ConvertTo-Json -Compress -Depth 6))
  } else {
    Read-Host 'Press Enter to close'
  }
  exit $code
}
function Die($msg) {
  Say ''; Say "  FAILED: $msg" 'Red'; Say ''
  Finish 1 @{ ok = $false; status = 'failed'; message = $msg }
}

Say ''
Say '  RiskManager EA updater' 'Cyan'
Say '  ----------------------' 'Cyan'

# -- config ---------------------------------------------------------
function Find-MetaEditor {
  Get-ChildItem 'C:\Program Files','C:\Program Files (x86)' -Filter 'MetaEditor*.exe' `
    -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
}
function Find-DataDirs {
  # Accept MQL4-only installs too: an MT4 terminal has no MQL5 folder, and
  # excluding it made the MT4 build unreachable from the picker.
  Get-ChildItem "$env:APPDATA\MetaQuotes\Terminal" -Directory -ErrorAction SilentlyContinue |
    Where-Object {
      (Test-Path (Join-Path $_.FullName 'MQL5\Experts')) -or
      (Test-Path (Join-Path $_.FullName 'MQL4\Experts'))
    } |
    Select-Object -ExpandProperty FullName
}

# Nicknames are stored against the data-folder path, which is stable for the
# life of an installation - so a name given once stays attached to that
# terminal. Without them the picker shows only hashes and install paths, which
# is unreadable once you run several MT5 copies.
function Get-Nicknames {
  if (-not (Test-Path $configPath)) { return @{} }
  $c = Get-Content $configPath -Raw | ConvertFrom-Json
  $map = @{}
  if ($c.PSObject.Properties.Name -contains 'terminals' -and $c.terminals) {
    foreach ($prop in $c.terminals.PSObject.Properties) { $map[$prop.Name] = $prop.Value }
  }
  return $map
}

function Set-Nickname($dir, $name) {
  $c = Get-Content $configPath -Raw | ConvertFrom-Json
  if ($c.PSObject.Properties.Name -notcontains 'terminals' -or -not $c.terminals) {
    $c | Add-Member -NotePropertyName terminals -NotePropertyValue (New-Object psobject) -Force
  }
  if ($c.terminals.PSObject.Properties.Name -contains $dir) { $c.terminals.$dir = $name }
  else { $c.terminals | Add-Member -NotePropertyName $dir -NotePropertyValue $name -Force }
  $c | ConvertTo-Json -Depth 6 | Set-Content $configPath -Encoding UTF8
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
  $has = (Test-Path (Join-Path $dir 'MQL5\Experts\RiskManager.ex5')) -or
         (Test-Path (Join-Path $dir 'MQL4\Experts\RiskManager.ex4'))
  $nick = (Get-Nicknames)[$dir]
  [pscustomobject]@{
    Dir       = $dir
    Install   = $(if ($install) { $install } else { '(install path unknown)' })
    Nickname  = $(if ($nick) { $nick } else { '' })
    HasEa     = $has
    HasMq5    = (Test-Path (Join-Path $dir 'MQL5\Experts'))
    HasMq4    = (Test-Path (Join-Path $dir 'MQL4\Experts'))
    Short     = (Split-Path $dir -Leaf).Substring(0, 8)
  }
}

# Both of these run before the config checks, so the GUI can populate its
# terminal list on a machine that has never been configured.
if ($ListTerminals) {
  $items = @(Find-DataDirs | ForEach-Object { Get-TerminalLabel $_ })
  Finish 0 @{
    ok = $true; status = 'terminals'
    terminals = @($items | ForEach-Object {
      @{ dir = $_.Dir; install = $_.Install; nickname = $_.Nickname
         hasEa = $_.HasEa; hasMq5 = $_.HasMq5; hasMq4 = $_.HasMq4 }
    })
  }
}

if ($SetNickname) {
  if (-not $TerminalDir) { Die '-SetNickname needs -TerminalDir' }
  if (-not (Test-Path $configPath)) { Die "no config yet - run a check first ($configPath)" }
  Set-Nickname $TerminalDir $SetNickname
  Say "  Named $TerminalDir -> $SetNickname" 'Green'
  Finish 0 @{ ok = $true; status = 'named'; dir = $TerminalDir; nickname = $SetNickname }
}

# Ask which terminal to target when more than one is present, rather than
# guessing or making the user hand-edit a hash into JSON.
function Select-TerminalDir($dirs) {
  $items = @($dirs | ForEach-Object { Get-TerminalLabel $_ })
  # The GUI presents its own picker, so never block on a console prompt there.
  if ($NonInteractive) {
    Finish 2 @{
      ok = $false; status = 'needterminal'
      message = 'more than one MetaTrader installation — choose one'
      terminals = @($items | ForEach-Object {
        @{ dir = $_.Dir; install = $_.Install; nickname = $_.Nickname
           hasEa = $_.HasEa; hasMq5 = $_.HasMq5; hasMq4 = $_.HasMq4 }
      })
    }
  }
  Say ''
  Say '  Multiple MetaTrader installations found:' 'Yellow'
  for ($i = 0; $i -lt $items.Count; $i++) {
    $m = $items[$i]
    $name = $(if ($m.Nickname) { "$($m.Nickname)  -  $($m.Install)" } else { $m.Install })
    Say ("    [{0}] {1}" -f ($i + 1), $name) 'White'
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
    bridgeUrl      = 'https://7r4d3.up.railway.app'
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
  Finish 0 @{ ok = $false; status = 'needconfig'; message = "fill in the token in $configPath"; configPath = $configPath }
}

# Hand-edited configs are the norm here, and a stray single backslash in a
# Windows path is the easy mistake. Report it as such instead of letting a raw
# ConvertFrom-Json exception through.
try {
  $cfg = Get-Content $configPath -Raw | ConvertFrom-Json
} catch {
  Die ("$configPath is not valid JSON.`n" +
       "  $($_.Exception.Message)`n" +
       '  Paths need doubled backslashes: "C:\\Program Files\\..."')
}

# An explicit -TerminalDir (the GUI's picker) wins over whatever is configured,
# without rewriting the config behind the user's back.
if ($TerminalDir) {
  if (-not (Test-Path $TerminalDir)) { Die "terminal data folder not found: $TerminalDir" }
  $cfg.terminalDataDir = $TerminalDir
}

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
if (-not (Test-Path $expertsDir)) {
  $other = $(if ($Platform -eq 'mq5') { 'MQL4' } else { 'MQL5' })
  $hasOther = Test-Path (Join-Path $cfg.terminalDataDir "$other\Experts")
  $hint = $(if ($hasOther) {
    "This terminal is a $other installation - switch the platform selector."
  } else {
    "Neither MQL4 nor MQL5 was found here; is terminalDataDir pointing at a MetaTrader data folder?"
  })
  Die "no $(if ($Platform -eq 'mq5') { 'MQL5' } else { 'MQL4' })\Experts folder in`n  $($cfg.terminalDataDir)`n  $hint"
}

$headers  = @{ Authorization = "Bearer $($cfg.token)" }

# The EA may be installed under any name. MT's server-side journal can record
# the expert's filename, so a distinctive one is a handle across accounts;
# set "eaName" in the config to install it as something else. Nothing in the
# EA source depends on its own filename.
if ($cfg.PSObject.Properties.Name -contains 'eaName' -and $cfg.eaName) {
  $eaName = ($cfg.eaName -replace '[^A-Za-z0-9_\- ]', '').Trim()
  if (-not $eaName) { Die 'eaName in the config has no usable characters' }
}
$srcFile  = Join-Path $expertsDir "$eaName.$Platform"
$exFile   = Join-Path $expertsDir ("$eaName." + $(if ($Platform -eq 'mq5') { 'ex5' } else { 'ex4' }))

# One marker per (platform, terminal, name). A single shared marker claimed
# "up to date" for terminals the updater had never written to.
$termTag    = (Split-Path $cfg.terminalDataDir -Leaf)
if ($termTag.Length -gt 8) { $termTag = $termTag.Substring(0, 8) }
$markerPath = Join-Path $here ".installed.$Platform.$termTag.$eaName.json"

# -- what's available -----------------------------------------------
Say "  Bridge : $($cfg.bridgeUrl)"
Say "  Target : $expertsDir"
if ($eaName -ne 'RiskManager') { Say "  Name   : $eaName.$Platform" }
Say ''
try {
  $all  = (Invoke-RestMethod "$($cfg.bridgeUrl)/api/source" -Headers $headers -TimeoutSec 20).sources
  $meta = $all.$Platform
} catch {
  # A 401 is not a connectivity problem - the bridge answered, it just refused
  # the token. Saying "could not reach" for that sends you looking at the
  # network when the fix is one field in the config.
  $code = $null
  try { $code = [int]$_.Exception.Response.StatusCode } catch { }
  if ($code -eq 401) {
    # Length and shape only - never the token itself. Comparing this against
    # the "token set (N chars)" the server logs at startup catches the common
    # causes without either side printing a secret.
    $t = [string]$cfg.token
    $shape = if ($t.Length -eq 0) { 'empty' }
             else {
               $pad = if ($t -ne $t.Trim()) { ', HAS LEADING/TRAILING WHITESPACE' } else { '' }
               "$($t.Length) chars, starts '$($t.Substring(0,[Math]::Min(3,$t.Length)))'$pad"
             }
    Die ("the bridge rejected your token.`n" +
         "  $($cfg.bridgeUrl) answered, so the connection is fine - the token is wrong.`n" +
         "  Sending: $shape`n" +
         "  Compare that with the 'token set (N chars)' line in the server's`n" +
         "  startup log. Same length but still refused = different value;`n" +
         "  different length = truncated, padded, or the wrong deployment.`n" +
         "`n" +
         "  Easiest fix: open the dashboard, enter your RM_TOKEN, and use its`n" +
         "  'updater.config.json' button - it writes the URL and token for you.`n" +
         "  Otherwise paste RM_TOKEN from your host's service variables into`n" +
         "  $configPath")
  }
  Die "could not reach the bridge - $($_.Exception.Message)"
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
    Invoke-WebRequest "$($cfg.bridgeUrl)/api/source/ps1" -Headers $headers -UseBasicParsing -OutFile $tmpPs -TimeoutSec 60
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
      # Forward every switch, or a GUI-driven run silently loses its
      # non-interactive contract the moment the updater updates itself.
      $fwd = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $me, '-Platform', $Platform, '-NoSelfUpdate')
      if ($Force)          { $fwd += '-Force' }
      if ($NonInteractive) { $fwd += '-NonInteractive' }
      if ($CheckOnly)      { $fwd += '-CheckOnly' }
      if ($Yes)            { $fwd += '-Yes' }
      if ($TerminalDir)    { $fwd += @('-TerminalDir', $TerminalDir) }
      & powershell @fwd
      exit $LASTEXITCODE
    }
  }
}
# -- companion files ------------------------------------------------
# Self-update only ever replaces THIS file, so a newly published tool - the
# windowed updater, say - could never reach anyone who bootstrapped from the
# .bat. Fetch any companion that is missing or stale, which is what makes
# "download the .bat and run it" actually deliver the whole thing.
function Sync-Companion($key, $fileName) {
  if (-not $all.$key -or -not $all.$key.available) { return }
  $dest = Join-Path $here $fileName
  $have = ''
  if (Test-Path $dest) { $have = (Get-FileHash $dest -Algorithm SHA256).Hash.Substring(0, 12).ToLower() }
  if ($have -eq $all.$key.sha256) { return }
  try {
    Invoke-WebRequest "$($cfg.bridgeUrl)/api/source/$key" -Headers $headers -UseBasicParsing -OutFile $dest -TimeoutSec 60
    Say "  $(if ($have) { 'Updated' } else { 'Installed' }) $fileName" 'Green'
  } catch {
    # A running GUI holds its own .ps1 open; that is not worth failing over.
    Say "  (could not write $fileName - $($_.Exception.Message))" 'DarkGray'
  }
}
if (-not $NoSelfUpdate) {
  Sync-Companion 'guips1' 'Update-EA-GUI.ps1'
  Sync-Companion 'guibat' 'Update-EA-GUI.bat'
  Sync-Companion 'bat'    'Update-EA.bat'
}

if (-not $meta.available) { Die "$Platform is not available on this deployment" }

Say "  Available : v$($meta.version)  $([math]::Round($meta.bytes/1KB)) KB  $($meta.sha256)"

# Deliberately no fallback to the old shared marker. It cannot know WHICH
# terminal it described - it reported "v6.03 installed" for a terminal still
# running a two-month-old binary, because an .ex5 merely existed there. A
# terminal with no marker of its own is treated as never installed; the cost
# is one extra reinstall, and the alternative is a confident wrong answer.
$installed = $null
if (Test-Path $markerPath) { $installed = Get-Content $markerPath -Raw | ConvertFrom-Json }
if ($installed) { Say "  Installed : v$($installed.version)  $($installed.sha256)" }

$upToDate = ($installed -and $installed.sha256 -eq $meta.sha256)

# -- pre-flight warning ---------------------------------------------
# Compiling reloads the EA. On-chart state now survives that (OnDeinit
# persists it), but an open position is still worth knowing about.
# With many instances on one account, sum across every symbol posting.
$open = 0; $mtx = 0; $armedCount = 0; $liveKnown = $false
try {
  $snap = Invoke-RestMethod "$($cfg.bridgeUrl)/api/state" -Headers $headers -TimeoutSec 10
  $rows = @($snap.instances)
  if ($rows.Count -gt 0) {
    $liveKnown = $true
    foreach ($r in $rows) { if (-not $r.stale) { $open += [int]$r.openCount } }
    if ($snap.state) { $mtx = [int]$snap.state.matrices.active }
    $armedCount = @($rows | Where-Object { $_.armed }).Count
  } elseif ($snap.state) {
    $liveKnown = $true
    $open = [int]$snap.state.exposure.openCount
    $mtx  = [int]$snap.state.matrices.active
    if ($snap.state.armed.active) { $armedCount = 1 }
  }
} catch { Say '  (could not read live state - continuing)' 'DarkGray' }

if ($CheckOnly) {
  Finish 0 @{
    ok = $true; status = $(if ($upToDate) { 'uptodate' } else { 'outdated' })
    installedVersion = $(if ($installed) { $installed.version } else { $null })
    installedSha     = $(if ($installed) { $installed.sha256 } else { $null })
    availableVersion = $meta.version
    availableSha     = $meta.sha256
    bytes            = $meta.bytes
    expertsDir       = $expertsDir
    bridgeUrl        = $cfg.bridgeUrl
    metaEditor       = $cfg.metaEditorPath
    terminalDir      = $cfg.terminalDataDir
    terminalNickname = (Get-TerminalLabel $cfg.terminalDataDir).Nickname
    terminalInstall  = (Get-TerminalLabel $cfg.terminalDataDir).Install
    liveKnown        = $liveKnown
    openCount        = $open
    matrices         = $mtx
    armedCount       = $armedCount
  }
}

if ($upToDate -and -not $Force) {
  Say ''
  Say '  Already up to date.' 'Green'
  Say ''
  Finish 0 @{ ok = $true; status = 'uptodate'; version = $meta.version; expertsDir = $expertsDir }
}

if ($open -gt 0 -or $mtx -gt 0 -or $armedCount -gt 0) {
  Say ''
  Say "  NOTE: $open open position(s), $mtx active matrix/matrices, $armedCount armed setup(s)." 'Yellow'
  Say '  Compiling reloads the EA. Lines and matrices are restored automatically,' 'Yellow'
  Say '  but nothing protective runs during the brief reload.' 'Yellow'
  if (-not $Yes) {
    if ($NonInteractive) {
      Finish 3 @{
        ok = $false; status = 'confirm'; openCount = $open; matrices = $mtx; armedCount = $armedCount
        message = "$open open position(s), $mtx matrix/matrices and $armedCount armed setup(s) are live."
      }
    }
    if ((Read-Host '  Continue? (y/N)') -ne 'y') {
      Say '  Cancelled.'
      Finish 0 @{ ok = $false; status = 'cancelled' }
    }
  }
}

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
Invoke-WebRequest "$($cfg.bridgeUrl)/api/source/$Platform" -Headers $headers -UseBasicParsing -OutFile $tmp -TimeoutSec 60
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
  Say ''
  Finish 1 @{
    ok = $false; status = 'compilefailed'
    rolledBack = [bool]$prev
    errors = @($errs | Select-Object -First 10 | ForEach-Object { "$_" })
    message = 'compile failed'
  }
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
        Invoke-WebRequest "$($cfg.bridgeUrl)/api/source/tpl" -Headers $headers -UseBasicParsing -OutFile $tplPath -TimeoutSec 60
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
Finish 0 @{
  ok = $true; status = 'updated'
  version = $meta.version; sha256 = $meta.sha256
  previousVersion = $(if ($installed) { $installed.version } else { $null })
  expertsDir = $expertsDir
  compile = "$result"
  binary = $(if (Test-Path $exFile) { (Get-Item $exFile).LastWriteTime.ToString('o') } else { $null })
}
