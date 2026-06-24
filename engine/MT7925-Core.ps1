<#
.SYNOPSIS
    Shared engine for the MediaTek MT7925-on-Windows-10 Wi-Fi fix.

.DESCRIPTION
    Pure logic, no UI. Dot-source this file from either the GUI
    (MT7925-Fix-GUI.ps1) or the CLI (Fix-MT7925-WiFi.ps1). All progress text is
    emitted through a pluggable "log sink" so the same functions can print to a
    console, append to a file, or stream into a GUI text box.

    Set the sink with Set-MTLogSink { param($Message,$Level) ... }. Levels are
    'info' | 'good' | 'warn' | 'error' | 'step'. If no sink is set, lines go to
    the host with sensible colors.

.NOTES
    Background: the Windows 11 'mtkwecx' driver is built against KMDF 1.33 and can
    never load on Windows 10 (KMDF 1.31). The Windows 10 'mtkwl6ex' driver is a
    pure NDIS miniport with a valid Microsoft signature on its .sys; it only lacks
    this board's PCI subsystem ID, which this engine injects, re-signs, installs.
#>

# MediaTek MT7925 identifiers (constant across all OEM board variants).
$script:MT_VEN = '14C3'   # MediaTek
$script:MT_DEV = '7925'   # MT7925

# ---------------------------------------------------------------------------
# Logging sink
# ---------------------------------------------------------------------------
$script:MTLogSink = $null

function Set-MTLogSink {
    <# Provide a scriptblock: param($Message,$Level). Pass $null to reset. #>
    param([scriptblock]$Sink)
    $script:MTLogSink = $Sink
}

function Write-MTLog {
    param(
        [string]$Message,
        [ValidateSet('info','good','warn','error','step')]
        [string]$Level = 'info'
    )
    $line = "[{0:HH:mm:ss}] {1}" -f (Get-Date), $Message
    if ($script:MTLogSink) {
        & $script:MTLogSink $line $Level
    } else {
        $color = switch ($Level) {
            'good'  { 'Green' }  'warn' { 'Yellow' }
            'error' { 'Red' }    'step' { 'Cyan' }
            default { 'Gray' }
        }
        Write-Host $line -ForegroundColor $color
    }
}

# ---------------------------------------------------------------------------
# Read-only state queries (safe to call any time, no admin side effects)
# ---------------------------------------------------------------------------
function Test-MTAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-MTDevice {
    <#
        Returns a PSCustomObject describing the MT7925, or $null if absent:
          Found, FriendlyName, Status, Problem, InstanceId, Subsys, HardwareId
    #>
    $dev = Get-PnpDevice -ErrorAction SilentlyContinue |
           Where-Object { $_.HardwareID -like "*VEN_$($script:MT_VEN)*DEV_$($script:MT_DEV)*" } |
           Select-Object -First 1
    if (-not $dev) { return $null }

    $hwids = (Get-PnpDeviceProperty -InstanceId $dev.InstanceId `
                -KeyName 'DEVPKEY_Device_HardwareIds' -ErrorAction SilentlyContinue).Data
    $full = ($hwids | Where-Object { $_ -match 'SUBSYS_' } | Select-Object -First 1)
    if (-not $full) { $full = $dev.InstanceId }
    $subsys = if ($full -match 'SUBSYS_([0-9A-Fa-f]{8})') { $Matches[1].ToUpper() } else { $null }

    [pscustomobject]@{
        Found        = $true
        FriendlyName = $dev.FriendlyName
        Status       = $dev.Status
        Problem      = $dev.Problem
        InstanceId   = $dev.InstanceId
        Subsys       = $subsys
        HardwareId   = $full
    }
}

function Test-MTSecureBoot {
    # $true = ON, $false = OFF or non-UEFI (legacy BIOS has no Secure Boot).
    try { return [bool](Confirm-SecureBootUEFI) } catch { return $false }
}

function Test-MTTestSigning {
    ((bcdedit /enum '{current}') -join "`n") -match '(?im)^\s*testsigning\s+Yes'
}

function Get-MTState {
    <#
        One call that snapshots everything the UI needs to pick the next step.
        Also computes a 'Phase' string the front-end can switch on:
          NoDevice | NeedSecureBootOff | NeedTestSigning | ReadyToInstall |
          WorkingHardenPending | NeedSecureBootOn | Done
    #>
    $dev = Get-MTDevice
    $sb  = Test-MTSecureBoot
    $ts  = Test-MTTestSigning
    $ok  = ($dev -and $dev.Status -eq 'OK' -and $dev.Problem -eq 'CM_PROB_NONE')

    $phase =
        if (-not $dev)            { 'NoDevice' }
        elseif ($ok) {
            if     ($ts)          { 'WorkingHardenPending' }   # works, but test signing still on
            elseif (-not $sb)     { 'NeedSecureBootOn' }       # secure: just re-enable Secure Boot
            else                  { 'Done' }                   # Secure Boot ON + test signing OFF
        }
        elseif ($sb)              { 'NeedSecureBootOff' }      # can't load a test-signed driver yet
        elseif (-not $ts)         { 'NeedTestSigning' }        # enable test signing, reboot
        else                      { 'ReadyToInstall' }         # build + sign + install now

    [pscustomobject]@{
        Device      = $dev
        SecureBoot  = $sb
        TestSigning = $ts
        DeviceOK    = $ok
        IsAdmin     = (Test-MTAdmin)
        Phase       = $phase
    }
}

# ---------------------------------------------------------------------------
# Actions (require admin)
# ---------------------------------------------------------------------------
function Enable-MTTestSigning {
    Write-MTLog '=== Enabling test signing ===' 'step'
    bcdedit /set testsigning on | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-MTLog 'Failed to enable test signing (is Secure Boot still on?).' 'error'; return $false }
    Write-MTLog 'Test signing enabled. REBOOT, then run the fix again to finish.' 'good'
    Write-MTLog "(A 'Test Mode' watermark after reboot is expected and harmless.)" 'info'
    $true
}

function Disable-MTTestSigning {
    Write-MTLog '=== Disabling test signing (hardening) ===' 'step'
    bcdedit /set testsigning off | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-MTLog 'Failed to disable test signing.' 'error'; return $false }
    Write-MTLog 'Test signing disabled. REBOOT; the driver keeps working on its embedded' 'good'
    Write-MTLog 'Microsoft signature. After reboot you can re-enable Secure Boot in BIOS.' 'good'
    $true
}

function Invoke-MTInstall {
    <#
        The full build/sign/install (Phase 2). Assumes Secure Boot OFF and test
        signing ON (caller should have verified via Get-MTState). Returns $true
        on a verified-working device.
    #>
    param(
        [string]$DriverSource,
        [string]$CertSubject = 'CN=MTKDriverCert'
    )
    try {
        $VEN = $script:MT_VEN; $DEV = $script:MT_DEV

        $dev = Get-MTDevice
        if (-not $dev)         { Write-MTLog "No MT7925 (VEN_$VEN&DEV_$DEV) device present." 'error'; return $false }
        if (-not $dev.Subsys)  { Write-MTLog "Could not read this board's SUBSYS id." 'error'; return $false }
        $subsys = $dev.Subsys
        Write-MTLog "Device: $($dev.FriendlyName)"
        Write-MTLog "Subsystem detected: SUBSYS_$subsys" 'step'

        # --- locate driver source: bundled folder, else in-box DriverStore ----
        $srcInf = Join-Path $DriverSource 'mtkwl6ex.inf'
        if (-not (Test-Path $srcInf)) {
            $store = Get-ChildItem 'C:\Windows\System32\DriverStore\FileRepository' -Directory -ErrorAction SilentlyContinue |
                     Where-Object { $_.Name -like 'mtkwl6ex.inf_amd64_*' } | Select-Object -First 1
            if (-not $store) { Write-MTLog 'Bundled driver missing and no in-box mtkwl6ex in the DriverStore.' 'error'; return $false }
            $DriverSource = $store.FullName
            $srcInf = Join-Path $DriverSource 'mtkwl6ex.inf'
            Write-MTLog "Bundled driver missing; using in-box package: $DriverSource" 'warn'
        }

        # --- working copy -----------------------------------------------------
        $work = Join-Path $env:TEMP 'MT7925_wl6ex_work'
        if (Test-Path $work) { Remove-Item $work -Recurse -Force }
        New-Item -ItemType Directory -Force -Path $work | Out-Null
        Copy-Item (Join-Path $DriverSource '*') $work -Recurse -Force
        $inf = Join-Path $work 'mtkwl6ex.inf'
        $cat = Join-Path $work 'mtkwl6ex.cat'
        Write-MTLog "Working copy: $work"

        # --- inject this board's subsystem into the INF (UTF-16 LE) -----------
        $idLine = "PCI\VEN_$VEN&DEV_$DEV&SUBSYS_$subsys"
        $lines  = [System.IO.File]::ReadAllLines($inf)
        if ($lines -match [regex]::Escape("SUBSYS_$subsys")) {
            Write-MTLog 'Subsystem already present in INF; no edit needed.' 'good'
        } else {
            $out = New-Object System.Collections.Generic.List[string]
            $done = $false
            foreach ($l in $lines) {
                $out.Add($l)
                if (-not $done -and $l -match "DEV_$DEV&SUBSYS_[0-9A-Fa-f]{8}\s*$") {
                    $out.Add(($l -replace 'SUBSYS_[0-9A-Fa-f]{8}', "SUBSYS_$subsys"))
                    $out.Add(($l -replace 'SUBSYS_[0-9A-Fa-f]{8}', "SUBSYS_$subsys&REV_00"))
                    $done = $true
                }
            }
            if (-not $done) { Write-MTLog "Could not find a DEV_$DEV anchor line in the INF." 'error'; return $false }
            $enc = New-Object System.Text.UnicodeEncoding($false, $true)   # UTF-16 LE + BOM
            [System.IO.File]::WriteAllLines($inf, $out, $enc)
            Write-MTLog "Injected $idLine into the INF." 'good'
        }

        # --- code-signing certificate (create+trust or reuse) -----------------
        $cert = Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.Subject -eq $CertSubject } | Select-Object -First 1
        if (-not $cert) {
            Write-MTLog "Creating self-signed code-signing certificate $CertSubject ..."
            $cert = New-SelfSignedCertificate -Subject $CertSubject -Type CodeSigning `
                    -CertStoreLocation 'Cert:\LocalMachine\My' -HashAlgorithm SHA256
        } else {
            Write-MTLog "Reusing certificate (thumbprint $($cert.Thumbprint))."
        }
        foreach ($storeName in 'Root', 'TrustedPublisher') {
            $st = New-Object Security.Cryptography.X509Certificates.X509Store($storeName, 'LocalMachine')
            $st.Open('ReadWrite')
            if (-not ($st.Certificates | Where-Object { $_.Thumbprint -eq $cert.Thumbprint })) {
                $st.Add($cert); Write-MTLog "Added cert to $storeName store."
            }
            $st.Close()
        }

        # --- regenerate catalog (to TEMP, never inside the package) + sign ----
        $tmpCat = Join-Path $env:TEMP 'mtkwl6ex_new.cat'
        if (Test-Path $cat)    { Remove-Item $cat -Force }
        if (Test-Path $tmpCat) { Remove-Item $tmpCat -Force }
        Write-MTLog 'Regenerating catalog ...'
        New-FileCatalog -Path $work -CatalogFilePath $tmpCat -CatalogVersion 2 | Out-Null
        Copy-Item $tmpCat $cat -Force
        $r = Set-AuthenticodeSignature -FilePath $cat -Certificate $cert -HashAlgorithm SHA256
        if ($r.Status -ne 'Valid') { Write-MTLog "Catalog signing failed ($($r.Status))." 'error'; return $false }
        Write-MTLog "Catalog signature status: $($r.Status)" 'good'

        # --- remove competing Win11 'mtkwecx' packages (they out-rank) --------
        $enum = pnputil /enum-drivers
        $published = $null; $isMtkwecx = $false
        foreach ($ln in $enum) {
            if ($ln -match 'Published Name\s*:\s*(oem\d+\.inf)') { $published = $Matches[1]; $isMtkwecx = $false }
            if ($ln -match 'Original Name\s*:\s*mtkwecx\.inf')   { $isMtkwecx = $true }
            if ($isMtkwecx -and $published) {
                Write-MTLog "Removing competing Win11 driver $published (mtkwecx) ..." 'warn'
                pnputil /delete-driver $published /uninstall /force | Out-Null
                $published = $null; $isMtkwecx = $false
            }
        }

        # --- install, rescan, verify -----------------------------------------
        Write-MTLog 'Installing patched driver package ...'
        pnputil /add-driver $inf /install | Out-Null
        pnputil /scan-devices | Out-Null
        Start-Sleep -Seconds 5

        $res = Get-MTDevice
        Write-MTLog '=== RESULT ===' 'step'
        Write-MTLog "FriendlyName : $($res.FriendlyName)"
        Write-MTLog ("Status       : {0}" -f $res.Status) ($(if ($res.Status -eq 'OK') {'good'} else {'error'}))
        Write-MTLog "Problem      : $($res.Problem)"

        if ($res.Status -eq 'OK' -and $res.Problem -eq 'CM_PROB_NONE') {
            Write-MTLog 'SUCCESS - Wi-Fi adapter installed. Connect to a network from the taskbar.' 'good'
            return $true
        }
        Write-MTLog 'Driver installed but device is not OK. See Event Viewer (System log).' 'error'
        return $false
    }
    catch {
        Write-MTLog "Unexpected error: $($_.Exception.Message)" 'error'
        return $false
    }
}
