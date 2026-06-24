<#
.SYNOPSIS
    Desktop GUI for the MediaTek MT7925 Wi-Fi-on-Windows-10 fix.

.DESCRIPTION
    A phase-aware wizard (WinForms) over engine\MT7925-Core.ps1. It detects the
    adapter, Secure Boot, and test-signing state, then offers the correct next
    action: guide you to disable Secure Boot in BIOS (with a Re-check button),
    enable test signing + reboot, build/sign/install the patched driver, then
    harden again (disable test signing) and re-enable Secure Boot.

    Long operations run on a background runspace, so the window stays responsive
    and the engine's log streams live into the console pane.

    Launch via Run-MT7925-GUI.bat (self-elevates). Requires Administrator.
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ErrorActionPreference = 'Stop'
$corePath = Join-Path $PSScriptRoot 'engine\MT7925-Core.ps1'
. $corePath
$driverSource = Join-Path $PSScriptRoot 'driver'
$certSubject  = 'CN=MTKDriverCert'
$logFile = Join-Path $PSScriptRoot ("MT7925-GUI-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))

# ---------------------------------------------------------------------------
# Form + controls
# ---------------------------------------------------------------------------
$form               = New-Object System.Windows.Forms.Form
$form.Text          = 'MediaTek MT7925 Wi-Fi Fix for Windows 10'
$form.Size          = New-Object System.Drawing.Size(760, 620)
$form.StartPosition = 'CenterScreen'
$form.MinimumSize   = New-Object System.Drawing.Size(680, 560)
$form.Font          = New-Object System.Drawing.Font('Segoe UI', 9)

# --- header ----------------------------------------------------------------
$header = New-Object System.Windows.Forms.Label
$header.Text     = 'MediaTek MT7925 Wi-Fi 7 - Windows 10 Fix'
$header.Font     = New-Object System.Drawing.Font('Segoe UI', 13, [System.Drawing.FontStyle]::Bold)
$header.Location = New-Object System.Drawing.Point(16, 12)
$header.AutoSize = $true
$form.Controls.Add($header)

# --- status group ----------------------------------------------------------
$grpStatus = New-Object System.Windows.Forms.GroupBox
$grpStatus.Text     = 'Current state'
$grpStatus.Location = New-Object System.Drawing.Point(16, 48)
$grpStatus.Size     = New-Object System.Drawing.Size(716, 96)
$grpStatus.Anchor   = 'Top,Left,Right'
$form.Controls.Add($grpStatus)

function New-StatusRow($label, $x, $y) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $label; $l.Location = New-Object System.Drawing.Point($x, $y)
    $l.AutoSize = $true; $l.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $grpStatus.Controls.Add($l)
    $v = New-Object System.Windows.Forms.Label
    $v.Text = '...'; $v.Location = New-Object System.Drawing.Point(($x + 110), $y)
    $v.AutoSize = $true
    $grpStatus.Controls.Add($v)
    $v
}
$valDevice      = New-StatusRow 'Adapter:'      16  24
$valSubsys      = New-StatusRow 'Subsystem:'    16  46
$valSecureBoot  = New-StatusRow 'Secure Boot:'  390 24
$valTestSign    = New-StatusRow 'Test signing:' 390 46

# --- instruction banner ----------------------------------------------------
$lblInstruct = New-Object System.Windows.Forms.Label
$lblInstruct.Location = New-Object System.Drawing.Point(16, 152)
$lblInstruct.Size     = New-Object System.Drawing.Size(716, 64)
$lblInstruct.Anchor   = 'Top,Left,Right'
$lblInstruct.Font     = New-Object System.Drawing.Font('Segoe UI', 9.5)
$lblInstruct.Text     = 'Checking system...'
$form.Controls.Add($lblInstruct)

# --- log console -----------------------------------------------------------
$log = New-Object System.Windows.Forms.RichTextBox
$log.Location   = New-Object System.Drawing.Point(16, 224)
$log.Size       = New-Object System.Drawing.Size(716, 290)
$log.Anchor     = 'Top,Bottom,Left,Right'
$log.ReadOnly   = $true
$log.BackColor  = [System.Drawing.Color]::FromArgb(20, 20, 24)
$log.ForeColor  = [System.Drawing.Color]::Gainsboro
$log.Font       = New-Object System.Drawing.Font('Consolas', 9)
$form.Controls.Add($log)

# --- buttons ---------------------------------------------------------------
$btnPrimary = New-Object System.Windows.Forms.Button
$btnPrimary.Location = New-Object System.Drawing.Point(16, 524)
$btnPrimary.Size     = New-Object System.Drawing.Size(230, 40)
$btnPrimary.Anchor   = 'Bottom,Left'
$btnPrimary.Font     = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$btnPrimary.Text     = 'Please wait...'
$form.Controls.Add($btnPrimary)

$btnRecheck = New-Object System.Windows.Forms.Button
$btnRecheck.Location = New-Object System.Drawing.Point(256, 524)
$btnRecheck.Size     = New-Object System.Drawing.Size(120, 40)
$btnRecheck.Anchor   = 'Bottom,Left'
$btnRecheck.Text     = 'Re-check'
$form.Controls.Add($btnRecheck)

$btnLog = New-Object System.Windows.Forms.Button
$btnLog.Location = New-Object System.Drawing.Point(516, 524)
$btnLog.Size     = New-Object System.Drawing.Size(100, 40)
$btnLog.Anchor   = 'Bottom,Right'
$btnLog.Text     = 'Open log'
$form.Controls.Add($btnLog)

$btnHelp = New-Object System.Windows.Forms.Button
$btnHelp.Location = New-Object System.Drawing.Point(624, 524)
$btnHelp.Size     = New-Object System.Drawing.Size(100, 40)
$btnHelp.Anchor   = 'Bottom,Right'
$btnHelp.Text     = 'Help'
$form.Controls.Add($btnHelp)

# ---------------------------------------------------------------------------
# Log helpers (UI thread)
# ---------------------------------------------------------------------------
function Append-Log([string]$msg, [string]$level) {
    $color = switch ($level) {
        'good'  { [System.Drawing.Color]::LightGreen }
        'warn'  { [System.Drawing.Color]::Orange }
        'error' { [System.Drawing.Color]::Tomato }
        'step'  { [System.Drawing.Color]::DeepSkyBlue }
        default { [System.Drawing.Color]::Gainsboro }
    }
    $log.SelectionStart  = $log.TextLength
    $log.SelectionColor  = $color
    $log.AppendText($msg + "`n")
    $log.SelectionColor  = $log.ForeColor
    $log.ScrollToCaret()
    Add-Content -Path $logFile -Value $msg -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# Background worker plumbing (runspace + synchronized queue + UI timer)
# ---------------------------------------------------------------------------
$script:queue = [System.Collections.Queue]::Synchronized([System.Collections.Queue]::new())
$script:ps    = $null
$script:rs    = $null
$script:async = $null
$script:busyAction = $null

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 150

$timer.Add_Tick({
    while ($script:queue.Count -gt 0) {
        $item = $script:queue.Dequeue()
        if ($item.Msg -eq '__DONE__') {
            $okResult = ($item.Lvl -eq 'True')
            $finished = $script:busyAction
            # tear down runspace
            try { if ($script:ps) { $script:ps.EndInvoke($script:async) } } catch {}
            try { if ($script:ps) { $script:ps.Dispose() } } catch {}
            try { if ($script:rs) { $script:rs.Dispose() } } catch {}
            $script:ps = $null; $script:rs = $null; $script:async = $null
            $script:busyAction = $null
            $timer.Stop()
            On-WorkerDone $finished $okResult
        } else {
            Append-Log $item.Msg $item.Lvl
        }
    }
})

function Start-Worker([string]$action) {
    $script:busyAction = $action
    Set-Busy $true
    $worker = {
        param($corePath, $action, $driverSource, $certSubject, $queue)
        . $corePath
        Set-MTLogSink { param($m, $l) $queue.Enqueue([pscustomobject]@{ Msg = $m; Lvl = $l }) }
        $ok = switch ($action) {
            'enable'  { Enable-MTTestSigning }
            'disable' { Disable-MTTestSigning }
            'install' { Invoke-MTInstall -DriverSource $driverSource -CertSubject $certSubject }
            default   { $false }
        }
        $queue.Enqueue([pscustomobject]@{ Msg = '__DONE__'; Lvl = ([string][bool]$ok) })
    }
    $script:rs = [runspacefactory]::CreateRunspace()
    $script:rs.ApartmentState = 'MTA'
    $script:rs.Open()
    $script:ps = [powershell]::Create()
    $script:ps.Runspace = $script:rs
    [void]$script:ps.AddScript($worker).
        AddArgument($corePath).AddArgument($action).
        AddArgument($driverSource).AddArgument($certSubject).AddArgument($script:queue)
    $script:async = $script:ps.BeginInvoke()
    $timer.Start()
}

# ---------------------------------------------------------------------------
# UI state machine
# ---------------------------------------------------------------------------
function Set-Busy([bool]$busy) {
    $btnPrimary.Enabled = -not $busy
    $btnRecheck.Enabled = -not $busy
    if ($busy) { $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor }
    else       { $form.Cursor = [System.Windows.Forms.Cursors]::Default }
}

function Set-StatusColors($state) {
    $valDevice.Text     = if ($state.Device) { "$($state.Device.FriendlyName) [$($state.Device.Status)]" } else { 'Not found' }
    $valSubsys.Text     = if ($state.Device -and $state.Device.Subsys) { "SUBSYS_$($state.Device.Subsys)" } else { '-' }
    $valSecureBoot.Text = if ($state.SecureBoot)  { 'ON' }  else { 'OFF' }
    $valTestSign.Text   = if ($state.TestSigning) { 'ON' }  else { 'OFF' }

    $green = [System.Drawing.Color]::Green
    $red   = [System.Drawing.Color]::Firebrick
    $amber = [System.Drawing.Color]::DarkOrange
    $valDevice.ForeColor     = if ($state.DeviceOK) { $green } elseif ($state.Device) { $red } else { $amber }
    $valSecureBoot.ForeColor = if ($state.SecureBoot)  { $green } else { $amber }
    $valTestSign.ForeColor   = if ($state.TestSigning) { $amber } else { $green }
}

function Confirm-Reboot([string]$why) {
    $r = [System.Windows.Forms.MessageBox]::Show(
        "$why`n`nReboot now?", 'Reboot required',
        'YesNo', 'Question')
    if ($r -eq 'Yes') { shutdown /r /t 3 /c 'MT7925 Wi-Fi fix: rebooting' }
}

function On-WorkerDone([string]$action, [bool]$ok) {
    switch ($action) {
        'enable'  { if ($ok) { Confirm-Reboot 'Test signing is enabled. A reboot is needed before installing the driver. After reboot, open this tool again and click the main button to install.' } }
        'disable' { if ($ok) { Confirm-Reboot 'Test signing is disabled. Reboot so the change takes effect; the driver keeps working on its embedded Microsoft signature. After reboot you can re-enable Secure Boot in BIOS.' } }
        'install' {
            if ($ok) {
                [System.Windows.Forms.MessageBox]::Show(
                    'Wi-Fi adapter installed and verified. Connect to a network from the taskbar.',
                    'Success', 'OK', 'Information') | Out-Null
            } else {
                [System.Windows.Forms.MessageBox]::Show(
                    'The install did not end in a working state. See the log pane and Event Viewer (System log).',
                    'Not complete', 'OK', 'Warning') | Out-Null
            }
        }
    }
    Refresh-State
}

function Refresh-State {
    $state = Get-MTState
    Set-StatusColors $state

    # default button look
    $btnPrimary.Enabled  = $true
    $btnPrimary.BackColor = [System.Drawing.SystemColors]::Control
    $script:primaryAction = $null

    switch ($state.Phase) {
        'NoDevice' {
            $lblInstruct.Text = 'No MediaTek MT7925 adapter was detected on this system. This tool only applies to the MT7925 (PCI VEN_14C3 & DEV_7925). Nothing to do.'
            $btnPrimary.Text = 'No adapter'; $btnPrimary.Enabled = $false
        }
        'NeedSecureBootOff' {
            $lblInstruct.Text = "STEP 1 - Disable Secure Boot. The patched driver is self-signed and cannot load while Secure Boot is ON. Reboot into BIOS/UEFI, set Secure Boot to Disabled, save & exit, then click Re-check."
            $btnPrimary.Text = 'How to open BIOS'; $script:primaryAction = 'biosoff'
        }
        'NeedTestSigning' {
            $lblInstruct.Text = "STEP 2 - Enable test signing. This lets the self-signed driver load. It needs one reboot; a harmless 'Test Mode' watermark will appear. Click below, then reboot when prompted."
            $btnPrimary.Text = 'Enable test signing'; $script:primaryAction = 'enable'
            $btnPrimary.BackColor = [System.Drawing.Color]::FromArgb(220, 235, 255)
        }
        'ReadyToInstall' {
            $lblInstruct.Text = "STEP 3 - Install the driver. This patches the Windows 10 driver with your board's subsystem (SUBSYS_$($state.Device.Subsys)), signs it, removes the conflicting Windows 11 driver, and installs. Takes ~30 seconds."
            $btnPrimary.Text = 'Patch && install driver'; $script:primaryAction = 'install'
            $btnPrimary.BackColor = [System.Drawing.Color]::FromArgb(210, 245, 215)
        }
        'WorkingHardenPending' {
            $lblInstruct.Text = "Wi-Fi works! STEP 4 (recommended) - Disable test signing to remove the Test Mode watermark and tighten security. The driver keeps working on its embedded Microsoft signature. Needs a reboot."
            $btnPrimary.Text = 'Disable test signing'; $script:primaryAction = 'disable'
            $btnPrimary.BackColor = [System.Drawing.Color]::FromArgb(210, 245, 215)
        }
        'NeedSecureBootOn' {
            $lblInstruct.Text = "Almost done - Wi-Fi works with test signing OFF. STEP 5 (recommended) - Re-enable Secure Boot in BIOS/UEFI for full security, reboot, then click Re-check. The adapter will keep working."
            $btnPrimary.Text = 'How to open BIOS'; $script:primaryAction = 'bioson'
        }
        'Done' {
            $lblInstruct.Text = "All done. Secure Boot is ON, test signing is OFF, and the MT7925 adapter is working. Nothing left to do - enjoy your Wi-Fi."
            $btnPrimary.Text = 'Completed'; $btnPrimary.Enabled = $false
            $btnPrimary.BackColor = [System.Drawing.Color]::FromArgb(210, 245, 215)
        }
    }
}

# ---------------------------------------------------------------------------
# Button handlers
# ---------------------------------------------------------------------------
$btnPrimary.Add_Click({
    switch ($script:primaryAction) {
        'enable'  { Start-Worker 'enable' }
        'disable' { Start-Worker 'disable' }
        'install' {
            $c = [System.Windows.Forms.MessageBox]::Show(
                "This will create a self-signed certificate, modify and sign a copy of the Windows 10 MediaTek driver, remove the conflicting Windows 11 driver, and install the patched one.`n`nProceed?",
                'Confirm install', 'YesNo', 'Question')
            if ($c -eq 'Yes') { Start-Worker 'install' }
        }
        'biosoff' {
            [System.Windows.Forms.MessageBox]::Show(
                "To disable Secure Boot:`n`n1. Reboot and enter BIOS/UEFI (usually F2, F1, Del, or Esc at power-on; on many laptops: Settings > Update & Security > Recovery > Restart now > Troubleshoot > UEFI Firmware Settings).`n2. Find Secure Boot (often under Security or Boot).`n3. Set it to Disabled. Save & Exit.`n4. Back in Windows, open this tool and click Re-check.",
                'Disable Secure Boot in BIOS', 'OK', 'Information') | Out-Null
        }
        'bioson' {
            [System.Windows.Forms.MessageBox]::Show(
                "To re-enable Secure Boot:`n`n1. Reboot into BIOS/UEFI (F2/F1/Del/Esc, or Settings > Update & Security > Recovery > Restart now > Troubleshoot > UEFI Firmware Settings).`n2. Set Secure Boot to Enabled. Save & Exit.`n3. Back in Windows, open this tool and click Re-check to confirm Wi-Fi still works.",
                'Re-enable Secure Boot in BIOS', 'OK', 'Information') | Out-Null
        }
    }
})

$btnRecheck.Add_Click({ Append-Log '[re-checking system state...]' 'step'; Refresh-State })
$btnLog.Add_Click({
    if (Test-Path $logFile) { Start-Process notepad.exe $logFile }
    else { [System.Windows.Forms.MessageBox]::Show('No log written yet.', 'Log', 'OK', 'Information') | Out-Null }
})
$btnHelp.Add_Click({
    [System.Windows.Forms.MessageBox]::Show(
        "MediaTek MT7925 Wi-Fi Fix for Windows 10`n`nThis laptop's Wi-Fi chip (MT7925) shipped with Windows 11-only drivers, so on Windows 10 it fails to install (Code 28). This tool patches the Windows 10 MediaTek driver to recognize your exact board and installs it.`n`nFollow the steps in order; the banner always tells you what's next:`n  1. Disable Secure Boot (BIOS)`n  2. Enable test signing (reboot)`n  3. Patch & install the driver`n  4. Disable test signing again (reboot)`n  5. Re-enable Secure Boot (BIOS)`n`nAfter step 5 you have Secure Boot ON, test signing OFF, and working Wi-Fi.`n`nThis is an unofficial workaround. The official fix is upgrading to Windows 11.",
        'Help', 'OK', 'Information') | Out-Null
})

$form.Add_FormClosing({
    if ($script:busyAction) {
        $r = [System.Windows.Forms.MessageBox]::Show(
            'A task is still running. Close anyway?', 'Busy', 'YesNo', 'Warning')
        if ($r -ne 'Yes') { $_.Cancel = $true; return }
    }
    try { if ($script:ps) { $script:ps.Stop(); $script:ps.Dispose() } } catch {}
    try { if ($script:rs) { $script:rs.Dispose() } } catch {}
})

# ---------------------------------------------------------------------------
# Startup
# ---------------------------------------------------------------------------
if (-not (Test-MTAdmin)) {
    [System.Windows.Forms.MessageBox]::Show(
        'This tool must run as Administrator. Please launch it with Run-MT7925-GUI.bat (it self-elevates).',
        'Administrator required', 'OK', 'Warning') | Out-Null
    return
}

$form.Add_Shown({
    Append-Log 'MT7925 Wi-Fi Fix started.' 'step'
    Append-Log "Log file: $logFile" 'info'
    Refresh-State
})
[void]$form.ShowDialog()
