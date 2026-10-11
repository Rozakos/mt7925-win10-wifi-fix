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

# bcdedit localizes its Yes/No values (Ja, Oui, Greek Nai, ...), so the element name
# is matched literally and the value against every yes-word we know of.
$script:MTBcdYes = 'Yes|Ja|Oui|S[i\u00ED]|Sim|\u039D\u03B1\u03B9|\u0414\u0430|\u0422\u0430\u043A|Tak|Evet|Ano|\u00C1no|Igen|Kyll\u00E4|Jah|Taip|J\u0101|Da|\u306F\u3044|\u662F|\uC608'   # .NET regex \uXXXX escapes keep this file ASCII

function ConvertFrom-MTBcdTestSigning {
    <# Pure: does this 'bcdedit /enum {current}' text have testsigning set to yes? #>
    param([string]$BcdText)
    $BcdText -match "(?im)^\s*testsigning\s+($script:MTBcdYes)\s*$"
}

function Test-MTTestSigning {
    # Configured for the NEXT boot (what bcdedit says).
    ConvertFrom-MTBcdTestSigning ((bcdedit /enum '{current}') -join "`n")
}

function Test-MTTestSigningActive {
    # In effect for THIS boot. The loader records boot options here; the value
    # is language-independent (" ... TESTSIGNING ..." when test mode is on).
    $opts = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control' -Name SystemStartOptions -ErrorAction SilentlyContinue).SystemStartOptions
    [bool]($opts -match '(^|\s)TESTSIGNING(\s|$)')
}

function Get-MTPhase {
    <#
        Pure decision table (unit-tested in tests\Run-Tests.ps1):
          NoDevice | RebootPending | NeedSecureBootOff | NeedTestSigning |
          ReadyToInstall | WorkingHardenPending | NeedSecureBootOn | Done
        RebootPending: test signing was switched on or off but the PC has not
        rebooted yet. Installing then would stage a driver that cannot load.
    #>
    param(
        [bool]$DevicePresent,
        [bool]$DeviceOK,
        [bool]$SecureBoot,
        [bool]$TestSigningConfigured,
        [bool]$TestSigningActive
    )
    if (-not $DevicePresent) { return 'NoDevice' }
    if ($TestSigningConfigured -ne $TestSigningActive) { return 'RebootPending' }
    if ($DeviceOK) {
        if ($TestSigningActive)  { return 'WorkingHardenPending' }   # works, test signing still on
        if (-not $SecureBoot)    { return 'NeedSecureBootOn' }       # secure: re-enable Secure Boot
        return 'Done'                                                # Secure Boot ON + test signing OFF
    }
    if ($SecureBoot)             { return 'NeedSecureBootOff' }      # can't load a self-signed catalog yet
    if (-not $TestSigningActive) { return 'NeedTestSigning' }        # enable test signing, reboot
    return 'ReadyToInstall'                                          # build + sign + install now
}

function Get-MTState {
    <# One call that snapshots everything the UI needs to pick the next step. #>
    $dev = Get-MTDevice
    $sb  = Test-MTSecureBoot
    $ts  = Test-MTTestSigning
    $tsa = Test-MTTestSigningActive
    $ok  = [bool]($dev -and $dev.Status -eq 'OK' -and $dev.Problem -eq 'CM_PROB_NONE')

    [pscustomobject]@{
        Device            = $dev
        SecureBoot        = $sb
        TestSigning       = $ts
        TestSigningActive = $tsa
        DeviceOK          = $ok
        IsAdmin           = (Test-MTAdmin)
        Phase             = (Get-MTPhase -DevicePresent ([bool]$dev) -DeviceOK $ok -SecureBoot $sb `
                                         -TestSigningConfigured $ts -TestSigningActive $tsa)
    }
}

# ---------------------------------------------------------------------------
# Pure helpers (unit-tested)
# ---------------------------------------------------------------------------
function Add-MTSubsysToInf {
    <#
        Returns @{ Lines = [string[]]; Added = <sections patched>; AlreadyPresent = bool }.
        Adds 'SUBSYS_<id>' and 'SUBSYS_<id>&REV_00' copies of the first
        DEV_<dev>&SUBSYS_ line in EVERY [models] section that has one. Patching
        only the first section in the file could hit a section decorated for
        another OS build (e.g. ...22000) that Windows 10 never reads.
    #>
    param([string[]]$Lines, [string]$Dev, [string]$Subsys)
    if (($Lines -join "`n") -match [regex]::Escape("SUBSYS_$Subsys")) {
        return @{ Lines = $Lines; Added = 0; AlreadyPresent = $true }
    }
    $out = New-Object System.Collections.Generic.List[string]
    $patched = 0; $doneInSection = $false
    foreach ($l in $Lines) {
        $out.Add($l)
        if ($l -match '^\s*\[') { $doneInSection = $false; continue }   # new section
        if (-not $doneInSection -and $l -match "DEV_$Dev&SUBSYS_[0-9A-Fa-f]{8}\s*$") {
            $out.Add(($l -replace 'SUBSYS_[0-9A-Fa-f]{8}', "SUBSYS_$Subsys"))
            $out.Add(($l -replace 'SUBSYS_[0-9A-Fa-f]{8}', "SUBSYS_$Subsys&REV_00"))
            $doneInSection = $true; $patched++
        }
    }
    @{ Lines = $out.ToArray(); Added = $patched; AlreadyPresent = $false }
}

function Get-MTCompetingDrivers {
    <#
        Published names (oemNN.inf) of every staged Windows 11 'mtkwecx' package.
        Uses DISM objects (language-independent); falls back to parsing
        'pnputil /enum-drivers', whose labels are only English on English Windows.
    #>
    try {
        return @(Get-WindowsDriver -Online -All -ErrorAction Stop |
                 Where-Object { [IO.Path]::GetFileName($_.OriginalFileName) -ieq 'mtkwecx.inf' -and $_.Driver -match '^oem\d+\.inf$' } |
                 ForEach-Object { $_.Driver } | Sort-Object -Unique)
    } catch {
        Write-MTLog 'Get-WindowsDriver unavailable; parsing pnputil output instead.' 'warn'
        $found = @(); $published = $null
        foreach ($ln in (pnputil /enum-drivers)) {
            if ($ln -match '(oem\d+\.inf)') { $published = $Matches[1] }
            if ($published -and $ln -match 'mtkwecx\.inf') { $found += $published; $published = $null }
        }
        return @($found | Sort-Object -Unique)
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

function Remove-MTSigningKeys {
    <# Delete our signing certificate(s) WITH their private key from LocalMachine\My. #>
    param([string]$CertSubject = 'CN=MTKDriverCert')
    Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue |
        Where-Object { $_.Subject -eq $CertSubject } |
        ForEach-Object {
            Remove-Item -Path "Cert:\LocalMachine\My\$($_.Thumbprint)" -DeleteKey -ErrorAction SilentlyContinue
            Write-MTLog "Deleted signing key $($_.Thumbprint.Substring(0,8))... from the machine store." 'info'
        }
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
        $patch = Add-MTSubsysToInf -Lines ([System.IO.File]::ReadAllLines($inf)) -Dev $DEV -Subsys $subsys
        if ($patch.AlreadyPresent) {
            Write-MTLog 'Subsystem already present in INF; no edit needed.' 'good'
        } elseif ($patch.Added -eq 0) {
            Write-MTLog "Could not find a DEV_$DEV anchor line in the INF." 'error'; return $false
        } else {
            $enc = New-Object System.Text.UnicodeEncoding($false, $true)   # UTF-16 LE + BOM
            [System.IO.File]::WriteAllLines($inf, $patch.Lines, $enc)
            Write-MTLog "Injected $idLine into $($patch.Added) INF models section(s)." 'good'
        }

        # --- code-signing certificate (create+trust or reuse) -----------------
        # The private key is only needed for the one catalog signature below.
        # Older versions left it in LocalMachine\My for good, next to a copy of
        # the certificate trusted as a Root CA: anything that could read that key
        # could sign code this PC trusts. Clear such leftovers, then use a fresh
        # non-exportable key that is deleted right after signing. Only the
        # public certificate stays trusted (needed for the staged package).
        Remove-MTSigningKeys -CertSubject $CertSubject
        Write-MTLog "Creating a one-time code-signing certificate $CertSubject ..."
        $cert = New-SelfSignedCertificate -Subject $CertSubject -Type CodeSigning `
                -CertStoreLocation 'Cert:\LocalMachine\My' -HashAlgorithm SHA256 `
                -KeyExportPolicy NonExportable -NotAfter (Get-Date).AddYears(10)
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
        Remove-MTSigningKeys -CertSubject $CertSubject   # key no longer needed, whatever happened
        if ($r.Status -ne 'Valid') { Write-MTLog "Catalog signing failed ($($r.Status))." 'error'; return $false }
        Write-MTLog "Catalog signature status: $($r.Status) (signing key deleted)" 'good'

        # --- remove competing Win11 'mtkwecx' packages (they out-rank) --------
        foreach ($published in (Get-MTCompetingDrivers)) {
            Write-MTLog "Removing competing Win11 driver $published (mtkwecx) ..." 'warn'
            pnputil /delete-driver $published /uninstall /force | Out-Null
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
