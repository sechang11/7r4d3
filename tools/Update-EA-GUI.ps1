<#
  RiskManager - EA updater, windowed.

  A thin shell around Update-EA.ps1. It runs that script with -NonInteractive,
  streams its output into a log pane, and reads the ##RESULT## line it prints
  so the window can state plainly what happened. The console version worked
  fine; what it never did was tell you it had.

  Usage:  double-click Update-EA-GUI.bat
#>

param([ValidateSet('mq5', 'mq4')] [string] $Platform = 'mq5')

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# The launcher runs this with the console hidden, so anything that throws
# before ShowDialog would otherwise produce absolutely nothing on screen -
# indistinguishable from "I double-clicked it and nothing happened".
trap {
  [System.Windows.Forms.MessageBox]::Show(
    "The updater window could not start.`n`n$($_.Exception.Message)`n`n$($_.ScriptStackTrace)",
    'RiskManager updater', 'OK', 'Error') | Out-Null
  exit 1
}

$here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$worker = Join-Path $here 'Update-EA.ps1'
if (-not (Test-Path $worker)) {
  [System.Windows.Forms.MessageBox]::Show(
    "Update-EA.ps1 is missing from`n$here", 'RiskManager updater',
    'OK', 'Error') | Out-Null
  exit 1
}

# Palette lifted from the EA so the updater reads as part of the same system.
$BG     = [Drawing.Color]::FromArgb(0x0e, 0x0e, 0x16)
$PANEL  = [Drawing.Color]::FromArgb(0x18, 0x1a, 0x26)
$PLC    = [Drawing.Color]::FromArgb(0x1e, 0x20, 0x2d)
$BORDER = [Drawing.Color]::FromArgb(0x37, 0x3a, 0x4b)
$GOLD   = [Drawing.Color]::FromArgb(0xb9, 0x9b, 0x37)
$DIM    = [Drawing.Color]::FromArgb(0x8c, 0x91, 0xaa)
$GREEN  = [Drawing.Color]::FromArgb(0x00, 0x96, 0x50)
$RED    = [Drawing.Color]::FromArgb(0xc3, 0x23, 0x23)
$BLUE   = [Drawing.Color]::FromArgb(0x19, 0x76, 0xd2)
$WARN   = [Drawing.Color]::FromArgb(0xb4, 0x78, 0x00)

$fontUI  = New-Object Drawing.Font('Segoe UI', 9)
$fontBig = New-Object Drawing.Font('Segoe UI', 12, [Drawing.FontStyle]::Bold)
$fontMono= New-Object Drawing.Font('Consolas', 9)

# ── window ──────────────────────────────────────────────────────────
$form = New-Object Windows.Forms.Form
$form.Text            = 'RiskManager - EA updater'
$form.Size            = New-Object Drawing.Size(760, 740)
$form.MinimumSize     = New-Object Drawing.Size(680, 560)
$form.StartPosition   = 'CenterScreen'
$form.BackColor       = $BG
$form.ForeColor       = [Drawing.Color]::White
$form.Font            = $fontUI

function New-Label($text, $x, $y, $w, $h, $colour, $font) {
  $l = New-Object Windows.Forms.Label
  $l.Text = $text; $l.ForeColor = $colour; $l.BackColor = [Drawing.Color]::Transparent
  $l.Location = New-Object Drawing.Point($x, $y)
  $l.Size = New-Object Drawing.Size($w, $h)
  if ($font) { $l.Font = $font }
  $form.Controls.Add($l); return $l
}

# -- verdict banner: the single thing this whole window exists for ---
$banner = New-Object Windows.Forms.Label
$banner.Location  = New-Object Drawing.Point(14, 14)
$banner.Size      = New-Object Drawing.Size(716, 52)
$banner.TextAlign = 'MiddleLeft'
$banner.Font      = $fontBig
$banner.BackColor = $PLC
$banner.ForeColor = $DIM
$banner.Padding   = New-Object Windows.Forms.Padding(14, 0, 0, 0)
$banner.Anchor    = 'Top,Left,Right'
$banner.Text      = '  Checking...'
$form.Controls.Add($banner)

# -- facts panel -----------------------------------------------------
$facts = New-Object Windows.Forms.Panel
$facts.Location  = New-Object Drawing.Point(14, 76)
$facts.Size      = New-Object Drawing.Size(716, 206)
$facts.BackColor = $PANEL
$facts.Anchor    = 'Top,Left,Right'
$form.Controls.Add($facts)

$rowY = 10
function New-Row($key) {
  $script:rowY = $script:rowY + 0
  $k = New-Object Windows.Forms.Label
  $k.Text = $key; $k.ForeColor = $DIM; $k.AutoSize = $false
  $k.Location = New-Object Drawing.Point(14, $script:rowY)
  $k.Size = New-Object Drawing.Size(130, 20)
  $v = New-Object Windows.Forms.Label
  $v.Text = '-'; $v.ForeColor = [Drawing.Color]::White; $v.AutoEllipsis = $true
  $v.Location = New-Object Drawing.Point(150, $script:rowY)
  $v.Size = New-Object Drawing.Size(552, 20)
  $v.Anchor = 'Top,Left,Right'
  $facts.Controls.AddRange(@($k, $v))
  $script:rowY += 24
  return $v
}
$vInstalled = New-Row 'Installed'
$vAvailable = New-Row 'Available'
$vTerminal  = New-Row 'Folder'
$vBridge    = New-Row 'Bridge'
$vLive      = New-Row 'Live now'

# -- terminal chooser ------------------------------------------------
# Always visible, not just when detection is ambiguous: with several MT5
# copies you need to see which one you are about to overwrite, every time.
$lblTerm = New-Object Windows.Forms.Label
$lblTerm.Text = 'Terminal'; $lblTerm.ForeColor = $DIM
$lblTerm.Location = New-Object Drawing.Point(14, 136)
$lblTerm.Size = New-Object Drawing.Size(130, 22)
$facts.Controls.Add($lblTerm)

$cbTerminal = New-Object Windows.Forms.ComboBox
$cbTerminal.DropDownStyle = 'DropDownList'
$cbTerminal.Location  = New-Object Drawing.Point(150, 132)
$cbTerminal.Size      = New-Object Drawing.Size(452, 24)
$cbTerminal.Anchor    = 'Top,Left,Right'
$cbTerminal.BackColor = $PLC; $cbTerminal.ForeColor = [Drawing.Color]::White
$cbTerminal.FlatStyle = 'Flat'
$facts.Controls.Add($cbTerminal)

$btnRename = New-Object Windows.Forms.Button
$btnRename.Text = 'Rename'; $btnRename.Width = 88; $btnRename.Height = 26
$btnRename.Location = New-Object Drawing.Point(610, 131)
$btnRename.Anchor = 'Top,Right'
$btnRename.FlatStyle = 'Flat'
$btnRename.BackColor = $PLC; $btnRename.ForeColor = [Drawing.Color]::White
$btnRename.FlatAppearance.BorderColor = $BORDER
$facts.Controls.Add($btnRename)

# -- EA filename ------------------------------------------------------
# MetaTrader identifies an expert by its filename, and its server-side journal
# can record it. A different name per machine stops that being a handle that
# links accounts. Blank means RiskManager.
$lblEa = New-Object Windows.Forms.Label
$lblEa.Text = 'EA name'; $lblEa.ForeColor = $DIM
$lblEa.Location = New-Object Drawing.Point(14, 170)
$lblEa.Size = New-Object Drawing.Size(130, 22)
$facts.Controls.Add($lblEa)

$txtEa = New-Object Windows.Forms.TextBox
$txtEa.Location  = New-Object Drawing.Point(150, 166)
$txtEa.Size      = New-Object Drawing.Size(200, 24)
$txtEa.BackColor = $PLC; $txtEa.ForeColor = [Drawing.Color]::White
$txtEa.BorderStyle = 'FixedSingle'
$facts.Controls.Add($txtEa)

$btnEa = New-Object Windows.Forms.Button
$btnEa.Text = 'Apply'; $btnEa.Width = 70; $btnEa.Height = 26
$btnEa.Location = New-Object Drawing.Point(358, 165)
$btnEa.FlatStyle = 'Flat'
$btnEa.BackColor = $PLC; $btnEa.ForeColor = [Drawing.Color]::White
$btnEa.FlatAppearance.BorderColor = $BORDER
$facts.Controls.Add($btnEa)

$lblEaNote = New-Object Windows.Forms.Label
$lblEaNote.Text = 'blank = RiskManager'
$lblEaNote.ForeColor = $DIM
$lblEaNote.Location = New-Object Drawing.Point(436, 170)
$lblEaNote.Size = New-Object Drawing.Size(266, 22)
$lblEaNote.Anchor = 'Top,Left,Right'
$tipEa = New-Object Windows.Forms.ToolTip
$tipEa.SetToolTip($txtEa, "Installs and compiles the EA under this filename.`nMetaTrader's server-side journal can record the expert's name, so a`ndifferent one per machine removes that as a shared handle.")
$facts.Controls.Add($lblEaNote)

# -- controls --------------------------------------------------------
$ctl = New-Object Windows.Forms.Panel
$ctl.Location  = New-Object Drawing.Point(14, 294)
$ctl.Size      = New-Object Drawing.Size(716, 40)
$ctl.BackColor = [Drawing.Color]::Transparent
$ctl.Anchor    = 'Top,Left,Right'
$form.Controls.Add($ctl)

function Style-Button($b, $bg) {
  $b.FlatStyle = 'Flat'; $b.BackColor = $bg; $b.ForeColor = [Drawing.Color]::White
  $b.FlatAppearance.BorderColor = $BORDER
  $b.Font = New-Object Drawing.Font('Segoe UI', 9, [Drawing.FontStyle]::Bold)
  $b.Height = 32
}

$btnUpdate = New-Object Windows.Forms.Button
$btnUpdate.Text = 'UPDATE NOW'; $btnUpdate.Width = 150
$btnUpdate.Location = New-Object Drawing.Point(0, 2)
Style-Button $btnUpdate $BLUE
$ctl.Controls.Add($btnUpdate)

$btnCheck = New-Object Windows.Forms.Button
$btnCheck.Text = 'Check again'; $btnCheck.Width = 110
$btnCheck.Location = New-Object Drawing.Point(158, 2)
Style-Button $btnCheck $PLC
$ctl.Controls.Add($btnCheck)

$cbPlatform = New-Object Windows.Forms.ComboBox
$cbPlatform.DropDownStyle = 'DropDownList'
$cbPlatform.Items.AddRange(@('MT5 (.mq5)', 'MT4 (.mq4)')) | Out-Null
$cbPlatform.SelectedIndex = $(if ($Platform -eq 'mq4') { 1 } else { 0 })
$cbPlatform.Width = 110
$cbPlatform.Location = New-Object Drawing.Point(276, 6)
$cbPlatform.BackColor = $PLC; $cbPlatform.ForeColor = [Drawing.Color]::White
$cbPlatform.FlatStyle = 'Flat'
$ctl.Controls.Add($cbPlatform)

$cbForce = New-Object Windows.Forms.CheckBox
$cbForce.Text = 'Force reinstall'; $cbForce.Width = 104
$cbForce.Location = New-Object Drawing.Point(396, 8)
$cbForce.ForeColor = $DIM
$ctl.Controls.Add($cbForce)

$btnDiag = New-Object Windows.Forms.Button
$btnDiag.Text = 'Diagnose'; $btnDiag.Width = 96
$btnDiag.Location = New-Object Drawing.Point(508, 2)
$btnDiag.Anchor = 'Top,Right'
Style-Button $btnDiag $PLC
$ctl.Controls.Add($btnDiag)

$btnFolder = New-Object Windows.Forms.Button
$btnFolder.Text = 'Open folder'; $btnFolder.Width = 100
$btnFolder.Location = New-Object Drawing.Point(616, 2)
$btnFolder.Anchor = 'Top,Right'
Style-Button $btnFolder $PLC
$ctl.Controls.Add($btnFolder)

# -- log -------------------------------------------------------------
New-Label 'LOG' 14 344 60 16 $DIM $null | Out-Null
$log = New-Object Windows.Forms.RichTextBox
$log.Location   = New-Object Drawing.Point(14, 364)
$log.Size       = New-Object Drawing.Size(716, 288)
$log.BackColor  = $PLC
$log.ForeColor  = $DIM
$log.Font       = $fontMono
$log.ReadOnly   = $true
$log.BorderStyle= 'None'
$log.Anchor     = 'Top,Left,Right,Bottom'
$form.Controls.Add($log)

$status = New-Label '' 14 660 716 20 $DIM $null
$status.Anchor = 'Bottom,Left,Right'

# ── plumbing ────────────────────────────────────────────────────────
$script:expertsDir = ''
$script:terminalDir = ''
$script:busy = $false

function Write-Log($text, $colour) {
  if ($null -eq $colour) { $colour = $DIM }
  $log.SelectionStart  = $log.TextLength
  $log.SelectionLength = 0
  $log.SelectionColor  = $colour
  $log.AppendText("$text`r`n")
  $log.SelectionColor  = $log.ForeColor
  $log.ScrollToCaret()
}

function Set-Banner($text, $bg, $fg) {
  $banner.Text      = "  $text"
  $banner.BackColor = $bg
  $banner.ForeColor = $fg
  $banner.Refresh()
}

function Set-Busy($on, $msg) {
  $script:busy = $on
  $btnUpdate.Enabled = -not $on
  $btnCheck.Enabled  = -not $on
  $cbPlatform.Enabled= -not $on
  $status.Text = $msg
  [Windows.Forms.Application]::DoEvents()
}

function Get-Platform { if ($cbPlatform.SelectedIndex -eq 1) { 'mq4' } else { 'mq5' } }

# Runs the worker and pumps its stdout into the log as it arrives, so a slow
# compile looks like progress rather than a frozen window.
function Invoke-Worker([string[]] $extraArgs) {
  # NB: not $args - that is an automatic variable and assigning to it here
  # would shadow the real one for the whole function.
  $argv = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $worker,
            '-Platform', (Get-Platform), '-NonInteractive') + $extraArgs

  $psi = New-Object Diagnostics.ProcessStartInfo
  $psi.FileName               = 'powershell.exe'
  $psi.Arguments              = ($argv | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
  $psi.UseShellExecute        = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError  = $true
  $psi.CreateNoWindow         = $true

  $proc = New-Object Diagnostics.Process
  $proc.StartInfo = $psi
  $proc.Start() | Out-Null

  # Drain stderr on its own task. Reading both pipes synchronously deadlocks
  # the moment one of them fills while we are blocked on the other.
  $errTask = $proc.StandardError.ReadToEndAsync()

  # Watchdog. Without it a wedged worker leaves the banner on "Checking..."
  # forever with no way to tell whether it is busy or dead.
  $deadline = [Diagnostics.Stopwatch]::StartNew()
  $limitSec = 180

  $result = $null
  while ($true) {
    # ReadLineAsync + pumping messages, so the window stays responsive through
    # the compile - which produces no output for several seconds.
    $t = $proc.StandardOutput.ReadLineAsync()
    while (-not $t.Wait(50)) {
      [Windows.Forms.Application]::DoEvents()
      if ($deadline.Elapsed.TotalSeconds -gt $limitSec) {
        try { $proc.Kill() } catch { }
        Write-Log "  Gave up after ${limitSec}s - the bridge did not answer." $RED
        Write-Log '  Check the bridgeUrl and token in updater.config.json, and that' $DIM
        Write-Log '  this machine can reach the bridge over HTTPS.' $DIM
        return [pscustomobject]@{
          Code = -1
          Result = [pscustomobject]@{
            ok = $false; status = 'timeout'
            message = "no response from the bridge after ${limitSec}s"
          }
        }
      }
    }
    $line = $t.Result
    if ($null -eq $line) { break }
    if ($line.StartsWith('##RESULT##')) {
      $result = $line.Substring(10) | ConvertFrom-Json
      continue
    }
    $c = $DIM
    if ($line -match 'FAILED|\berror\b')                          { $c = $RED }
    elseif ($line -match 'Installed v|0 error|Already up to date') { $c = $GREEN }
    elseif ($line -match 'NOTE:|out of date')                      { $c = $WARN }
    Write-Log $line.TrimEnd() $c
  }
  $proc.WaitForExit()
  $errText = $errTask.Result
  if ($errText) { Write-Log $errText.TrimEnd() $RED }
  return [pscustomobject]@{ Code = $proc.ExitCode; Result = $result }
}

# -- terminal picker, shown only when there is a genuine ambiguity ---
function Select-Terminal($terminals) {
  $dlg = New-Object Windows.Forms.Form
  $dlg.Text = 'Which MetaTrader?'
  $dlg.Size = New-Object Drawing.Size(640, 300)
  $dlg.StartPosition = 'CenterParent'
  $dlg.BackColor = $BG; $dlg.ForeColor = [Drawing.Color]::White; $dlg.Font = $fontUI

  $lbl = New-Object Windows.Forms.Label
  $lbl.Text = 'More than one installation was found. Pick the terminal to update:'
  $lbl.Location = New-Object Drawing.Point(14, 12)
  $lbl.Size = New-Object Drawing.Size(590, 20); $lbl.ForeColor = $DIM
  $dlg.Controls.Add($lbl)

  $lst = New-Object Windows.Forms.ListBox
  $lst.Location = New-Object Drawing.Point(14, 40)
  $lst.Size = New-Object Drawing.Size(596, 160)
  $lst.BackColor = $PLC; $lst.ForeColor = [Drawing.Color]::White; $lst.BorderStyle = 'None'
  foreach ($t in $terminals) {
    $tag = if ($t.hasEa) { 'RiskManager installed' } else { 'no RiskManager yet' }
    $lst.Items.Add("$($t.install)   [$tag]") | Out-Null
  }
  $lst.SelectedIndex = 0
  $dlg.Controls.Add($lst)

  $ok = New-Object Windows.Forms.Button
  $ok.Text = 'Use this one'; $ok.Width = 130
  $ok.Location = New-Object Drawing.Point(480, 212)
  Style-Button $ok $BLUE
  $ok.DialogResult = 'OK'
  $dlg.Controls.Add($ok); $dlg.AcceptButton = $ok

  if ($dlg.ShowDialog($form) -eq 'OK' -and $lst.SelectedIndex -ge 0) {
    return $terminals[$lst.SelectedIndex].dir
  }
  return $null
}

# -- terminal list ---------------------------------------------------
$script:terminals = @()
$script:suppressTermEvent = $false

function Format-Terminal($t) {
  $tag = @()
  if ($t.hasMq5) { $tag += 'MT5' }
  if ($t.hasMq4) { $tag += 'MT4' }
  if ($t.hasEa)  { $tag += 'RM installed' }
  $name = $(if ($t.nickname) { $t.nickname } else { Split-Path $t.install -Leaf })
  "$name  -  $($t.install)  [$($tag -join ', ')]"
}

function Load-Terminals {
  $r = Invoke-Worker @('-ListTerminals', '-NoSelfUpdate')
  if (-not $r.Result -or -not $r.Result.terminals) { return }
  $script:terminals = @($r.Result.terminals)

  $script:suppressTermEvent = $true
  $cbTerminal.Items.Clear()
  foreach ($t in $script:terminals) { $cbTerminal.Items.Add((Format-Terminal $t)) | Out-Null }
  if ($cbTerminal.Items.Count -gt 0) {
    $cbTerminal.SelectedIndex = (Find-TerminalIndex $script:terminalDir)
    # Deliberately NOT setting $script:terminalDir here. Leaving it empty lets
    # the worker resolve the configured terminal; overwriting it with a guess
    # would silently override updater.config.json on every start.
  }
  $script:suppressTermEvent = $false
  $btnRename.Enabled = $cbTerminal.Items.Count -gt 0
}

# Preferred selection: the named directory if we have one, else a terminal that
# actually supports the chosen platform - defaulting to index 0 picks an
# MT4-only install while the platform selector says MT5.
function Find-TerminalIndex($dir) {
  for ($i = 0; $i -lt $script:terminals.Count; $i++) {
    if ($script:terminals[$i].dir -eq $dir) { return $i }
  }
  $wantMq5 = (Get-Platform) -eq 'mq5'
  foreach ($needEa in @($true, $false)) {
    for ($i = 0; $i -lt $script:terminals.Count; $i++) {
      $t = $script:terminals[$i]
      $fits = $(if ($wantMq5) { $t.hasMq5 } else { $t.hasMq4 })
      if ($fits -and ((-not $needEa) -or $t.hasEa)) { return $i }
    }
  }
  return 0
}

function Rename-Terminal {
  if ($cbTerminal.SelectedIndex -lt 0) { return }
  $t = $script:terminals[$cbTerminal.SelectedIndex]
  Add-Type -AssemblyName Microsoft.VisualBasic
  $name = [Microsoft.VisualBasic.Interaction]::InputBox(
    "Name for this installation:`n`n$($t.install)", 'Name this terminal',
    $(if ($t.nickname) { $t.nickname } else { '' }))
  if ([string]::IsNullOrWhiteSpace($name)) { return }

  $r = Invoke-Worker @('-SetNickname', $name.Trim(), '-TerminalDir', $t.dir, '-NoSelfUpdate')
  if ($r.Result -and $r.Result.ok) {
    Write-Log "  Named this terminal '$($name.Trim())'" $GREEN
    Load-Terminals
  } else {
    $why = $(if ($r.Result) { $r.Result.message } else { "exit code $($r.Code)" })
    Write-Log "  Could not save the name - $why" $RED
  }
}

function Clear-Facts {
  $vInstalled.Text = '-'; $vAvailable.Text = '-'
  $vTerminal.Text  = '-'; $vBridge.Text = '-'
  $vLive.Text = '-'; $vLive.ForeColor = $DIM
}

# ── actions ─────────────────────────────────────────────────────────
function Do-Check {
  if ($script:busy) { return }
  Set-Busy $true 'Checking the bridge...'
  Set-Banner 'Checking...' $PLC $DIM
  $log.Clear()

  $extra = @('-CheckOnly')
  if ($script:terminalDir) { $extra += @('-TerminalDir', $script:terminalDir) }
  $r = Invoke-Worker $extra

  if ($r.Result -and $r.Result.status -eq 'needterminal') {
    Set-Busy $false ''
    $pick = Select-Terminal $r.Result.terminals
    # The parentheses matter: a bare [Type]::Member in argument position is
    # parsed as a literal string, not evaluated.
    if (-not $pick) { Set-Banner 'No terminal chosen' $WARN ([Drawing.Color]::Black); return }
    $script:terminalDir = $pick
    Do-Check
    return
  }

  $res = $r.Result
  if (-not $res -or -not $res.ok) {
    # Leaving the previous run's numbers on screen would say "v6.01 -> v6.02"
    # next to a red failure banner, which reads as if something was installed.
    Clear-Facts
    $msg = $(if ($res) { $res.message } else { 'the updater exited without reporting' })
    $first = @($msg -split "`r?`n")[0]
    Set-Banner "Cannot check - $first" $RED ([Drawing.Color]::White)
    foreach ($l in @($msg -split "`r?`n")) { Write-Log "  $l" $RED }
    Set-Busy $false ''
    $btnUpdate.Enabled = $false
    return
  }

  $script:expertsDir  = $res.expertsDir
  $script:terminalDir = $res.terminalDir
  $vInstalled.Text = $(if ($res.installedVersion) { "v$($res.installedVersion)   $($res.installedSha)" } else { 'not installed by this updater' })
  $vAvailable.Text = "v$($res.availableVersion)   $($res.availableSha)   $([math]::Round($res.bytes/1KB)) KB"
  $vTerminal.Text  = $res.expertsDir
  if (-not $txtEa.Focused) { $txtEa.Text = $(if ($res.eaName -and $res.eaName -ne 'RiskManager') { $res.eaName } else { '' }) }
  $vBridge.Text    = $res.bridgeUrl
  # Keep the dropdown in step when the worker resolved a terminal we didn't pick
  # (single install, or one written into the config on a previous run).
  if ($script:terminals.Count -gt 0) {
    for ($i = 0; $i -lt $script:terminals.Count; $i++) {
      if ($script:terminals[$i].dir -eq $res.terminalDir -and $cbTerminal.SelectedIndex -ne $i) {
        $script:suppressTermEvent = $true
        $cbTerminal.SelectedIndex = $i
        $script:suppressTermEvent = $false
      }
    }
  }
  $vLive.Text      = $(if ($res.liveKnown) {
                        "$($res.openCount) open position(s), $($res.matrices) matrix/matrices, $($res.armedCount) armed"
                      } else { 'no EA reporting to the bridge' })
  $vLive.ForeColor = $(if ($res.liveKnown -and ($res.openCount -gt 0)) { $GOLD } else { $DIM })

  if ($res.status -eq 'uptodate') {
    Set-Banner "Up to date - v$($res.availableVersion) is installed" $GREEN ([Drawing.Color]::White)
    $btnUpdate.Text = 'REINSTALL'
  } else {
    Set-Banner "Update available - v$($res.installedVersion) -> v$($res.availableVersion)" $BLUE ([Drawing.Color]::White)
    $btnUpdate.Text = 'UPDATE NOW'
  }
  Set-Busy $false "Checked $(Get-Date -Format 'HH:mm:ss')"
}

function Do-Update {
  if ($script:busy) { return }
  Set-Busy $true 'Updating...'
  Set-Banner 'Working...' $BLUE ([Drawing.Color]::White)
  $log.Clear()

  $extra = @()
  if ($cbForce.Checked)    { $extra += '-Force' }
  if ($script:terminalDir) { $extra += @('-TerminalDir', $script:terminalDir) }
  $r = Invoke-Worker $extra

  # The worker refuses to touch a terminal with live exposure without an
  # explicit yes. Ask here, then re-run with the answer.
  if ($r.Result -and $r.Result.status -eq 'confirm') {
    Set-Busy $false ''
    $ans = [Windows.Forms.MessageBox]::Show(
      "$($r.Result.message)`n`nCompiling reloads the EA. Lines and matrices are restored " +
      "automatically, but nothing protective runs during the brief reload.`n`nContinue?",
      'Live exposure', 'YesNo', 'Warning')
    if ($ans -ne 'Yes') { Set-Banner 'Cancelled' $WARN ([Drawing.Color]::Black); return }
    Set-Busy $true 'Updating...'
    $r = Invoke-Worker ($extra + '-Yes')
  }

  if ($r.Result -and $r.Result.status -eq 'needterminal') {
    Set-Busy $false ''
    $pick = Select-Terminal $r.Result.terminals
    if (-not $pick) { Set-Banner 'No terminal chosen' $WARN ([Drawing.Color]::Black); return }
    $script:terminalDir = $pick
    Do-Update
    return
  }

  $res = $r.Result
  Set-Busy $false ''
  if (-not $res) {
    Set-Banner "The updater exited without reporting (code $($r.Code))" $RED ([Drawing.Color]::White)
    return
  }

  switch ($res.status) {
    'updated' {
      $from = $(if ($res.previousVersion) { "v$($res.previousVersion) -> " } else { '' })
      Set-Banner "UPDATED - ${from}v$($res.version) compiled and installed" $GREEN ([Drawing.Color]::White)
      Write-Log '' $DIM
      Write-Log "  Binary written: $($res.binary)" $GREEN
      Write-Log "  Location:       $($res.expertsDir)" $GREEN
      Write-Log '' $DIM
      Write-Log '  MT reloads a recompiled EA on its own. If a chart still shows the old' $DIM
      Write-Log '  build, remove the EA and drag it back on.' $DIM
      Do-Check
    }
    'uptodate' {
      Set-Banner "Already up to date - v$($res.version)" $GREEN ([Drawing.Color]::White)
    }
    'compilefailed' {
      $tail = $(if ($res.rolledBack) { ' - previous version restored' } else { ' - NO BACKUP TO RESTORE' })
      Set-Banner "COMPILE FAILED$tail" $RED ([Drawing.Color]::White)
    }
    'cancelled' { Set-Banner 'Cancelled' $WARN ([Drawing.Color]::Black) }
    default {
      Set-Banner "Failed - $($res.message)" $RED ([Drawing.Color]::White)
    }
  }
}

$btnCheck.Add_Click({ Do-Check })
$btnUpdate.Add_Click({ Do-Update })
$btnEa.Add_Click({
  if ($script:busy) { return }
  Set-Busy $true 'Setting the EA name...'
  $name = $txtEa.Text.Trim()
  if ($name -eq '') { $name = 'RiskManager' }
  $r = Invoke-Worker @('-SetEaName', $name, '-NoSelfUpdate')
  Set-Busy $false ''
  if ($r.Result -and $r.Result.ok) {
    Write-Log "  EA will install as $($r.Result.eaName).mq5" $GREEN
    Do-Check
  } else {
    Write-Log '  Could not set the EA name - see above.' $RED
  }
})
$txtEa.Add_KeyDown({ if ($_.KeyCode -eq 'Enter') { $btnEa.PerformClick() } })

$btnRename.Add_Click({ if (-not $script:busy) { Rename-Terminal } })
# One button, one block of text to send back. Copies itself to the clipboard
# so support is "click Diagnose, paste" rather than a list of steps to follow.
$btnDiag.Add_Click({
  if ($script:busy) { return }
  Set-Busy $true 'Collecting a support report...'
  Set-Banner 'Collecting a support report...' $BLUE ([Drawing.Color]::White)
  $log.Clear()
  $extra = @('-Diagnose')
  if ($script:terminalDir) { $extra += @('-TerminalDir', $script:terminalDir) }
  Invoke-Worker $extra | Out-Null
  Set-Busy $false ''
  try {
    [Windows.Forms.Clipboard]::SetText($log.Text)
    Set-Banner 'Report copied to the clipboard - paste it to whoever is helping' $GREEN ([Drawing.Color]::White)
  } catch {
    Set-Banner 'Report ready below - select it and copy' $GREEN ([Drawing.Color]::White)
  }
})
$btnFolder.Add_Click({
  $target = $(if ($script:expertsDir -and (Test-Path $script:expertsDir)) { $script:expertsDir } else { $here })
  Start-Process explorer.exe $target
})
$cbPlatform.Add_SelectedIndexChanged({
  if ($script:busy) { return }
  # An MT4 build cannot be installed into an MT5-only data folder. Follow the
  # platform to a terminal that has it rather than failing at the user.
  if ($script:terminals.Count -gt 0) {
    $cur  = $script:terminals | Where-Object { $_.dir -eq $script:terminalDir } | Select-Object -First 1
    $fits = $(if ((Get-Platform) -eq 'mq5') { $cur.hasMq5 } else { $cur.hasMq4 })
    if (-not $cur -or -not $fits) {
      $i = Find-TerminalIndex ''
      $script:terminalDir = $script:terminals[$i].dir
      $script:suppressTermEvent = $true
      $cbTerminal.SelectedIndex = $i
      $script:suppressTermEvent = $false
    }
  }
  Do-Check
})
$cbTerminal.Add_SelectedIndexChanged({
  if ($script:busy -or $script:suppressTermEvent) { return }
  if ($cbTerminal.SelectedIndex -lt 0) { return }
  $script:terminalDir = $script:terminals[$cbTerminal.SelectedIndex].dir
  Do-Check
})

$form.Add_Shown({
  # Come to the front. Launched from Explorer while a maximised MT5 has focus,
  # the window otherwise opens behind it and reads as "nothing happened".
  $form.TopMost = $true
  $form.Activate()
  $form.TopMost = $false
  Load-Terminals
  Do-Check
})
[void]$form.ShowDialog()
