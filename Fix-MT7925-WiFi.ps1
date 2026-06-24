<#
.SYNOPSIS
    Command-line front-end for the MediaTek MT7925 Wi-Fi-on-Windows-10 fix.

.DESCRIPTION
    Thin wrapper over engine\MT7925-Core.ps1 (the shared logic used by both this
    CLI and the GUI, so they never drift apart). Idempotent and phase-aware:

      PRE-CHECK  Secure Boot must be OFF (test signing cannot take effect otherwise).
                 If it is ON, prints how to disable it and stops (exit 2).
      PHASE 1    Test signing OFF -> enables it, asks you to REBOOT and re-run (exit 0).
      PHASE 2    Test signing ON  -> patches the in-box mtkwl6ex driver with this
                 board's detected subsystem, signs it, removes the competing
                 Windows 11 mtkwecx driver, installs, and verifies.

    Run from an ELEVATED PowerShell (Run as Administrator).

.NOTES
    The Windows 11 'mtkwecx' driver is built against KMDF 1.33 and can never load
    on Windows 10 (KMDF 1.31). The Windows 10 'mtkwl6ex' driver is a pure NDIS
    miniport with a valid Microsoft signature; it only lacks this board's
    subsystem ID, which the engine injects and re-signs.
#>

[CmdletBinding()]
param(
    # Folder holding the driver package (mtkwl6ex.inf/.sys/.cat/.dll/.dat).
    # Defaults to the 'driver' folder next to this script (resolved below).
    [string]$DriverSource,
    # Certificate subject used for signing the modified catalog.
    [string]$CertSubject = 'CN=MTKDriverCert'
)

$ErrorActionPreference = 'Stop'
# $PSScriptRoot is not reliably populated in param defaults under PS 5.1; resolve here.
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $DriverSource) { $DriverSource = Join-Path $here 'driver' }
. (Join-Path $here 'engine\MT7925-Core.ps1')

# Route engine log lines to both the console (colored) and a timestamped file.
$logFile = Join-Path $here ("Fix-MT7925-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))
Set-MTLogSink {
    param($Message, $Level)
    $color = switch ($Level) {
        'good'  { 'Green' }  'warn' { 'Yellow' }
        'error' { 'Red' }    'step' { 'Cyan' }
        default { 'Gray' }
    }
    Write-Host $Message -ForegroundColor $color
    Add-Content -Path $logFile -Value $Message -ErrorAction SilentlyContinue
}

if (-not (Test-MTAdmin)) {
    Write-MTLog 'Run this script as Administrator (right-click PowerShell -> Run as administrator).' 'error'
    exit 1
}
Write-MTLog "MT7925 Wi-Fi auto-fix starting. Log: $logFile" 'step'

$state = Get-MTState
if ($state.Device) {
    Write-MTLog "Device: $($state.Device.FriendlyName)"
    Write-MTLog ("Status: {0}  Problem: {1}" -f $state.Device.Status, $state.Device.Problem)
    if ($state.Device.Subsys) { Write-MTLog "Subsystem detected: SUBSYS_$($state.Device.Subsys)" 'step' }
}

switch ($state.Phase) {
    'NoDevice' {
        Write-MTLog 'No MediaTek MT7925 (VEN_14C3 & DEV_7925) device found on this system.' 'error'
        exit 1
    }
    { $_ -in 'Done', 'NeedSecureBootOn', 'WorkingHardenPending' } {
        Write-MTLog 'Device already reports Status=OK. Nothing to install.' 'good'
        if ($state.Phase -eq 'WorkingHardenPending') {
            Write-MTLog 'Optional: run with test signing still ON; you may disable it (bcdedit /set testsigning off) and reboot.' 'info'
        } elseif ($state.Phase -eq 'NeedSecureBootOn') {
            Write-MTLog 'Optional: re-enable Secure Boot in BIOS for full security; the adapter will keep working.' 'info'
        }
        exit 0
    }
    'NeedSecureBootOff' {
        Write-MTLog 'Secure Boot is ENABLED. Disable it in BIOS/UEFI, reboot, then re-run this script.' 'warn'
        exit 2
    }
    'NeedTestSigning' {
        Write-MTLog '=== PHASE 1 ===' 'step'
        if (Enable-MTTestSigning) { exit 0 } else { exit 1 }
    }
    'ReadyToInstall' {
        Write-MTLog '=== PHASE 2: building, signing, and installing driver ===' 'step'
        if (Invoke-MTInstall -DriverSource $DriverSource -CertSubject $CertSubject) {
            Write-MTLog 'Visible networks:' 'info'
            (netsh wlan show networks) | Where-Object { $_ -match '^SSID' } | Select-Object -First 10 |
                ForEach-Object { Write-MTLog "  $_" }
            exit 0
        } else {
            exit 3
        }
    }
}
