# MediaTek MT7925 Wi-Fi Fix for Windows 10

[![Latest release](https://img.shields.io/github/v/release/Rozakos/mt7925-win10-wifi-fix?label=download&sort=semver)](https://github.com/Rozakos/mt7925-win10-wifi-fix/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/Rozakos/mt7925-win10-wifi-fix/total)](https://github.com/Rozakos/mt7925-win10-wifi-fix/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![Platform: Windows 10](https://img.shields.io/badge/platform-Windows%2010-0078D6)

**➡️ [Download the latest release](https://github.com/Rozakos/mt7925-win10-wifi-fix/releases/latest)** — extract the ZIP and double-click `Run-MT7925-GUI.bat`.

Get the **MediaTek MT7925 Wi-Fi 7** adapter working on **Windows 10** when the laptop
shipped with **Windows 11-only drivers**, so the adapter fails to install.

> **Symptoms this fixes** (search keywords): MT7925 not working on Windows 10 ·
> "Network Controller" with a yellow **Code 28** (`CM_PROB_FAILED_INSTALL`) ·
> `netsh wlan show interfaces` says *"There is no wireless interface on the system"* ·
> no Wi-Fi after a Windows 10 install/downgrade · MediaTek MT7925 `Code 37`.

It works by patching the **in-box Windows 10 `mtkwl6ex` driver** to recognize *your*
board's PCI subsystem ID, re-signing it, removing the conflicting Windows 11 driver,
and installing it. See [`PROCEDURE.md`](PROCEDURE.md) for the full technical write-up
of why this happens and exactly what the tool does.

---

## Does this apply to me?

Open Device Manager. If you see an unknown **Network Controller** (Code 28), check its
hardware ID (Properties → Details → Hardware Ids). If it starts with:

```
PCI\VEN_14C3&DEV_7925
```

…then yes — this is the MediaTek MT7925, and this tool is for you. The part after
`SUBSYS_` is your OEM board variant; the tool detects it automatically, so it works on
any MT7925 laptop (Lenovo, HP, Dell, Asus, …), not just one model.

## Quick start (GUI — recommended)

1. Download/clone this repo.
2. Double-click **`Run-MT7925-GUI.bat`** and accept the UAC prompt.
3. Follow the on-screen banner — it always tells you the next step and won't let you do
   them out of order:

   | Step | What you do | Why |
   |------|-------------|-----|
   | 1 | **Disable Secure Boot** in BIOS/UEFI, then click **Re-check** | A self-signed driver can't load with Secure Boot on |
   | 2 | Click **Enable test signing**, then reboot | Lets the re-signed driver load |
   | 3 | Click **Patch & install** (~30 s) | Adds your subsystem, signs, removes the Win11 driver, installs |
   | 4 | Click **Disable test signing**, then reboot | Removes the "Test Mode" watermark; driver keeps working on its embedded Microsoft signature |
   | 5 | **Re-enable Secure Boot** in BIOS, then click **Re-check** | Back to full security |

   End state: **Secure Boot ON, test signing OFF, Wi-Fi working.**

The tool can't change Secure Boot itself (no Windows program can — it's a firmware
setting, by design), so steps 1 and 5 are done in BIOS and the tool **verifies** them
for you with the **Re-check** button.

## Quick start (CLI alternative)

```powershell
# From an elevated PowerShell, with Secure Boot already OFF in BIOS:
powershell -ExecutionPolicy Bypass -File .\Fix-MT7925-WiFi.ps1
# It enables test signing and asks you to reboot; run it again to install.
```

Or double-click **`Run-Fix.bat`** (self-elevates).

## About the driver

This repo **does not include** MediaTek's driver binaries — they're proprietary. The
tool uses the **Windows 10 `mtkwl6ex` package already on your PC**, found under
`C:\Windows\System32\DriverStore\FileRepository\mtkwl6ex.inf_amd64_*`.

If that package isn't present on your machine, install it first via **Settings →
Windows Update → Optional updates → Driver updates** (look for a MediaTek Wi-Fi entry),
or point the tool at a folder containing it:

```powershell
.\Fix-MT7925-WiFi.ps1 -DriverSource "C:\path\to\mtkwl6ex"
```

## How it works (short version)

There are two MediaTek driver packages for this chip:

| Driver | Built for | Knows your `SUBSYS`? | Loads on Win10? |
|--------|-----------|----------------------|-----------------|
| `mtkwecx` (newer) | **Windows 11** | ✅ | ❌ (KMDF 1.33 wall) |
| `mtkwl6ex` (older) | **Windows 10** | ❌ | ✅ |

The Windows 11 driver knows your hardware but **cannot** run on Windows 10 (it needs
KMDF 1.33; Win10 only has 1.31, and there's no forward-compat). The Windows 10 driver
runs fine but doesn't list your subsystem. This tool adds your subsystem to the
Windows 10 driver — the one path that actually works. Full details in
[`PROCEDURE.md`](PROCEDURE.md).

## Repository layout

```
MT7925-Fix-GUI.ps1     Desktop GUI (WinForms wizard)
Run-MT7925-GUI.bat     Self-elevating launcher for the GUI
Fix-MT7925-WiFi.ps1    Command-line front-end
Run-Fix.bat            Self-elevating launcher for the CLI
engine/MT7925-Core.ps1 Shared engine (all logic; GUI and CLI both use it)
PROCEDURE.md           Full technical explanation and manual steps
TEST_STATUS.md         Verification notes (works with Secure Boot ON, test signing OFF)
```

## Requirements

- Windows 10 (x64) with the MediaTek MT7925 adapter
- Administrator rights
- The in-box `mtkwl6ex` Windows 10 driver available (see *About the driver*)
- Ability to change BIOS/UEFI settings (Secure Boot)

## ⚠️ Disclaimer

This is an **unofficial workaround**, provided as-is with no warranty (see
[`LICENSE`](LICENSE)). It temporarily enables **test signing** and requires turning
**Secure Boot off** during install — both are restored by the end of the procedure.
You run it at your own risk. The officially supported fix for this hardware is to use
**Windows 11**. Not affiliated with or endorsed by MediaTek, Lenovo, or Microsoft.

## Contributing

Got it working on a different laptop (different `SUBSYS`)? Open an issue or PR noting
your model and hardware ID — it helps confirm the auto-detection works broadly.
