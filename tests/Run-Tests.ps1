<#
    Unit tests for the pure parts of engine\MT7925-Core.ps1 (no admin, no
    hardware, no Pester needed):  powershell -File tests\Run-Tests.ps1
    Exits 1 on the first failed assertion.
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path $root 'engine\MT7925-Core.ps1')
Set-MTLogSink { param($m, $l) }   # silence engine logging

$script:failed = 0; $script:passed = 0
function Assert-Equal($Name, $Expected, $Actual) {
    if ("$Expected" -ceq "$Actual") { $script:passed++ }
    else { $script:failed++; Write-Host "FAIL  $Name`n      expected: $Expected`n      actual:   $Actual" -ForegroundColor Red }
}

# --- Get-MTPhase: the wizard's decision table ------------------------------
$cases = @(
    # present ok    sb     tsCfg  tsActive  -> phase
    @($false, $false, $false, $false, $false, 'NoDevice'),
    @($true,  $false, $true,  $false, $false, 'NeedSecureBootOff'),
    @($true,  $false, $false, $false, $false, 'NeedTestSigning'),
    @($true,  $false, $false, $true,  $false, 'RebootPending'),        # enabled, not rebooted yet
    @($true,  $false, $false, $true,  $true,  'ReadyToInstall'),
    @($true,  $true,  $false, $true,  $true,  'WorkingHardenPending'),
    @($true,  $true,  $false, $false, $true,  'RebootPending'),        # disabled, not rebooted yet
    @($true,  $true,  $false, $false, $false, 'NeedSecureBootOn'),
    @($true,  $true,  $true,  $false, $false, 'Done')
)
foreach ($c in $cases) {
    Assert-Equal "phase $($c[0..4] -join ',')" $c[5] (Get-MTPhase -DevicePresent $c[0] -DeviceOK $c[1] `
        -SecureBoot $c[2] -TestSigningConfigured $c[3] -TestSigningActive $c[4])
}

# --- bcdedit parsing across languages --------------------------------------
$bcd = @"
Windows Boot Loader
-------------------
identifier              {current}
description             Windows 10
testsigning             VALUE
nx                      OptIn
"@
foreach ($yes in 'Yes', 'Ja', 'Oui', (-join [char[]](0x0053,0x00ED)), (-join [char[]](0x039D,0x03B1,0x03B9)), (-join [char[]](0x0414,0x0430)), 'Evet') {
    Assert-Equal "bcdedit testsigning '$yes'" $true (ConvertFrom-MTBcdTestSigning $bcd.Replace('VALUE', $yes))
}
foreach ($no in 'No', 'Nein', 'Non', (-join [char[]](0x038C,0x03C7,0x03B9)), (-join [char[]](0x041D,0x0435,0x0442)), (-join [char[]](0x0048,0x0061,0x0079,0x0131,0x0072))) {
    Assert-Equal "bcdedit testsigning '$no'" $false (ConvertFrom-MTBcdTestSigning $bcd.Replace('VALUE', $no))
}
Assert-Equal 'bcdedit without testsigning line' $false (ConvertFrom-MTBcdTestSigning ($bcd -replace '(?m)^testsigning.*$', ''))

# --- INF injection ---------------------------------------------------------
$inf = @(
    '[Manufacturer]',
    '%MTK% = MediaTek,NTAMD64.10.0...16299,NTAMD64.10.0...22000',
    '',
    '[MediaTek.NTAMD64.10.0...22000]',
    '%MT7925.DeviceDescExA% = MTK7925_MODE1.ndi, PCI\VEN_14C3&DEV_7925&SUBSYS_7925144D',
    '',
    '[MediaTek.NTAMD64.10.0...16299]',
    '%MT7925.DeviceDescExA% = MTK7925_MODE1.ndi, PCI\VEN_14C3&DEV_7925&SUBSYS_7925144D',
    '%MT7925.DeviceDescExA% = MTK7925_MODE1.ndi, PCI\VEN_14C3&DEV_7925&SUBSYS_E0D917AA',
    '%MT7922.DeviceDesc% = MTK7922.ndi, PCI\VEN_14C3&DEV_0616&SUBSYS_E0CD17AA'
)
$r = Add-MTSubsysToInf -Lines $inf -Dev '7925' -Subsys 'E0FF17AA'
Assert-Equal 'patched both models sections' 2 $r.Added
Assert-Equal 'line count (+2 per section)' ($inf.Count + 4) $r.Lines.Count
$w10 = [array]::IndexOf($r.Lines, '[MediaTek.NTAMD64.10.0...16299]')
Assert-Equal 'Win10 section gets the new id' '%MT7925.DeviceDescExA% = MTK7925_MODE1.ndi, PCI\VEN_14C3&DEV_7925&SUBSYS_E0FF17AA' $r.Lines[$w10 + 2]
Assert-Equal 'and the REV_00 variant' '%MT7925.DeviceDescExA% = MTK7925_MODE1.ndi, PCI\VEN_14C3&DEV_7925&SUBSYS_E0FF17AA&REV_00' $r.Lines[$w10 + 3]
Assert-Equal 'other chips untouched' 1 (@($r.Lines | Where-Object { $_ -match 'DEV_0616' }).Count)

$again = Add-MTSubsysToInf -Lines $r.Lines -Dev '7925' -Subsys 'E0FF17AA'
Assert-Equal 'idempotent' $true $again.AlreadyPresent
Assert-Equal 'no anchor -> nothing added' 0 (Add-MTSubsysToInf -Lines @('[x]', 'foo') -Dev '7925' -Subsys 'E0FF17AA').Added

# --- BitLocker warning text -------------------------------------------------
Assert-Equal 'BitLocker ON warning names the recovery key page' $true ((Get-MTBitLockerWarning -Protected $true) -match 'BitLocker is ON.*recoverykey')
Assert-Equal 'BitLocker unknown/off still gives a hint' $true ((Get-MTBitLockerWarning -Protected $false) -match 'recovery key')
Assert-Equal 'Test-MTBitLocker returns a boolean and never throws' $true ((Test-MTBitLocker) -is [bool])

# --- driver package selection ----------------------------------------------
$pkgRoot = Join-Path $env:TEMP ("mt7925-tests-" + [guid]::NewGuid().ToString('N'))
try {
    $pkgs = @{
        old      = @('DriverVer = 01/01/2023,3.3.0.100',  'x = y, PCI\VEN_14C3&DEV_7925&SUBSYS_7925144D')
        new      = @('DriverVer=06/01/2024, 3.4.10.20',   'x = y, PCI\VEN_14C3&DEV_7925&SUBSYS_7925144D')
        no7925   = @('DriverVer = 01/01/2025,9.9.9.9',    'x = y, PCI\VEN_14C3&DEV_0616&SUBSYS_E0CD17AA')
        noinf    = $null
    }
    foreach ($name in $pkgs.Keys) {
        $dir = Join-Path $pkgRoot $name
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        if ($pkgs[$name]) {
            [System.IO.File]::WriteAllLines((Join-Path $dir 'mtkwl6ex.inf'), [string[]]$pkgs[$name], (New-Object System.Text.UnicodeEncoding($false, $true)))
        }
    }
    $all = @('old', 'no7925', 'noinf', 'new') | ForEach-Object { Join-Path $pkgRoot $_ }
    Assert-Equal 'picks newest package that lists DEV_7925' (Join-Path $pkgRoot 'new') (Select-MTDriverPackage -Folders $all -Dev '7925')
    Assert-Equal 'no package lists the chip -> null' $true ($null -eq (Select-MTDriverPackage -Folders @((Join-Path $pkgRoot 'no7925'), (Join-Path $pkgRoot 'noinf')) -Dev '7925'))
    Assert-Equal 'no candidates -> null' $true ($null -eq (Select-MTDriverPackage -Folders @() -Dev '7925'))
} finally {
    Remove-Item $pkgRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# --- no two variables in one function may differ only by case (issue #1) ----
# PowerShell variable names are case-insensitive, so '$DEV' and '$dev' are the
# same variable and the second assignment silently overwrites the first.
foreach ($file in 'engine\MT7925-Core.ps1', 'Fix-MT7925-WiFi.ps1', 'MT7925-Fix-GUI.ps1') {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root $file), [ref]$null, [ref]$null)
    $functions = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
    foreach ($fn in $functions) {
        $clashes = $fn.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] }, $true) |
                   ForEach-Object { $_.VariablePath.UserPath } |
                   Where-Object { $_ -notmatch '^(true|false|null|_|matches|lastexitcode)$' } |
                   Group-Object |
                   Where-Object { @($_.Group | Sort-Object -Unique -CaseSensitive).Count -gt 1 } |
                   ForEach-Object { (@($_.Group | Sort-Object -Unique -CaseSensitive) | ForEach-Object { '$' + $_ }) -join ' vs ' }
        Assert-Equal "$file $($fn.Name): variables differing only by case" '' (@($clashes) -join '; ')
    }
}

Write-Host "$script:passed passed, $script:failed failed"
if ($script:failed) { exit 1 }
