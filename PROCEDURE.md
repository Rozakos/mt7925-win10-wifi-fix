# MediaTek MT7925 Wi-Fi on Windows 10 — Full Procedure

**Goal:** Get the MediaTek MT7925 Wi-Fi 7 adapter working on Windows 10 when the
machine shipped with Windows 11 drivers only.

**Machine this was solved on:** Lenovo IdeaPad Slim 3 15ARP10 (83K7),
Windows 10 IoT Enterprise 10.0.19045.

---

## 1. The problem

The Wi-Fi adapter shows in Device Manager as an unknown **Network Controller** with
**Code 28 (`CM_PROB_FAILED_INSTALL`)**. `netsh wlan show interfaces` reports
"There is no wireless interface on the system."

- **Device:** MediaTek MT7925 Wi-Fi 7
- **Hardware ID:** `PCI\VEN_14C3&DEV_7925&SUBSYS_E0FF17AA&REV_00`
  - `VEN_14C3` = MediaTek
  - `DEV_7925` = MT7925 chip
  - `SUBSYS_E0FF17AA` = the Lenovo OEM board variant (the part numbers in the suffix
    `17AA` = Lenovo). **This subsystem is the crux of the whole problem.**

## 2. Why it fails out of the box

There are **two** MediaTek driver packages relevant to this chip:

| Driver | Built for | Knows our `SUBSYS_E0FF17AA`? | Loads on Win10? |
|--------|-----------|------------------------------|-----------------|
| `mtkwecx.inf` (new, "wecx") | **Windows 11** (build 22000+) | ✅ Yes | ❌ **No** |
| `mtkwl6ex.inf` (older, "wl6ex") | **Windows 10** (build 16299+) | ❌ No (lists other subsystems) | ✅ Yes |

So you are stuck in a gap:
- The driver that *knows your exact hardware* (`mtkwecx`) is **Windows 11 only**.
- The driver that *runs on Windows 10* (`mtkwl6ex`) **doesn't list your subsystem**.

### Why the Windows 11 driver can never work on Win10 (the real wall)
We initially tried to force `mtkwecx` onto Win10 by adding a Win10 install section to
its INF and test-signing it. It got further each time but ultimately failed with
**Code 37 (`CM_PROB_FAILED_DRIVER_ENTRY`)**, NTSTATUS `0xC000000D`
(`STATUS_INVALID_PARAMETER`). The System event log showed the decisive reason:

```
Wdf01000: Drivers Bind Minor version is greater than the minor version of the
currently Loaded KMDF library -- Driver Version: 1.33  Kmdf Lib. Version: 1.31
```

`mtkwecx.sys` is compiled against **KMDF 1.33**, which ships with Windows 11.
Windows 10 (19041/19045) only has **KMDF 1.31**. KMDF is backward-compatible but
**not forward-compatible**, and there is no KMDF 1.33 runtime for Windows 10. The
binary therefore cannot initialize on Win10 no matter what we do to the INF or
signature. **This path is a dead end — do not pursue it.**

## 3. The solution that works

Use the **Windows 10-native `mtkwl6ex` driver** (which is a pure NDIS miniport with
**no KMDF dependency**, so it has no version wall) and simply **add our subsystem ID**
to its INF. The `mtkwl6ex` package already supports `DEV_7925` for several other
subsystems and maps them to the `MTK7925_MODE1.ndi` install section — we just point
our subsystem at that same section.

Because we modify the INF, its catalog signature is invalidated, so we re-sign the
package with a self-signed certificate, which in turn requires **test signing** to be
enabled.

### Step-by-step (exactly what was done)

**Phase 0 — Diagnose**
```powershell
Get-PnpDevice | Where-Object { $_.HardwareID -like "*14C3*7925*" } |
  Format-List FriendlyName, Status, Problem, InstanceId
```

**Phase 1 — Enable test signing (requires reboot)**
Secure Boot must be OFF first (set in BIOS), otherwise `bcdedit` is blocked.
```powershell
bcdedit /set testsigning on
# reboot
```
After reboot you get a "Test Mode" watermark on the desktop — expected and harmless.

**Phase 2 — Create + trust a code-signing certificate**
```powershell
$cert = New-SelfSignedCertificate -Subject "CN=MTKDriverCert" -Type CodeSigning `
        -CertStoreLocation "Cert:\LocalMachine\My" -HashAlgorithm SHA256
# add $cert to both LocalMachine\Root and LocalMachine\TrustedPublisher
```

**Phase 3 — Build the patched Win10 driver package**
1. Locate the in-box Win10 driver:
   `C:\Windows\System32\DriverStore\FileRepository\mtkwl6ex.inf_amd64_*`
2. Copy the whole folder somewhere writable.
3. In the copied `mtkwl6ex.inf` (UTF-16 LE), inside `[MediaTek.NTAMD64.10.0...16299]`,
   add a line next to the existing `DEV_7925` entries:
   ```
   %MT7925.DeviceDescExA% = MTK7925_MODE1.ndi, PCI\VEN_14C3&DEV_7925&SUBSYS_E0FF17AA
   ```
   (We also added a `&REV_00` variant for an exact match.)
4. Regenerate the catalog and sign it (the `.sys` keeps its original WHQL signature):
   ```powershell
   New-FileCatalog -Path $dir -CatalogFilePath $tmp -CatalogVersion 2   # write to TEMP, not inside $dir
   Copy-Item $tmp "$dir\mtkwl6ex.cat" -Force
   Set-AuthenticodeSignature -FilePath "$dir\mtkwl6ex.cat" -Certificate $cert -HashAlgorithm SHA256
   ```
   ⚠ **Gotcha:** `New-FileCatalog` fails ("Unable to create the hash for file …cat")
   if the output `.cat` is inside the folder being cataloged. Write it to `%TEMP%`
   first, then copy it in.

**Phase 4 — Remove the competing Win11 driver, then install**
The Win11 `mtkwecx` packages have a *higher version number* than `mtkwl6ex`, so Windows
will keep choosing the broken one unless you remove it.
```powershell
# find them: pnputil /enum-drivers  (look for mtkwecx -> oemNN.inf)
pnputil /delete-driver oemNN.inf /uninstall /force   # each mtkwecx package
pnputil /add-driver "$dir\mtkwl6ex.inf" /install
pnputil /scan-devices
```

**Phase 5 — Verify**
```powershell
Get-PnpDevice | Where-Object { $_.HardwareID -like "*14C3*7925*" } |
  Format-List FriendlyName, Status, Problem
netsh wlan show interfaces
```
Expected: `Status = OK`, `Problem = CM_PROB_NONE`, and `netsh` lists the
**MediaTek Wi-Fi 7 MT7925 Wireless LAN Card** with the radio on. Then connect to Wi-Fi
normally from the taskbar.

## 4. Result achieved (2026-06-24)
- Status **OK**, no problem code.
- `netsh wlan` shows a working wireless interface (radio Hardware On / Software On).
- Network scan found 43 SSIDs. Wi-Fi fully functional, still on Windows 10.

## 5. Notes / caveats
- **Test signing stays ON.** Turning it off (`bcdedit /set testsigning off`) makes the
  test-signed driver stop loading. Leave it on unless you obtain a properly trusted
  signature.
- This is a **workaround**. The clean/official fix is to install Windows 11 (this
  hardware was designed for it), but the workaround keeps you on Win10 with working Wi-Fi.
- Driver MODE: we used `MTK7925_MODE1.ndi`, which matched the other `DEV_7925`
  subsystems in the Win10 INF. It works for this board. If a future board variant
  misbehaves, the alternative section is `MTK7925_DEFAULT.ndi`.

## 6. Files in this folder
- `driver/` — the **patched, signed Win10 driver package** that fixed it
  (`mtkwl6ex.inf` with our subsystem added + re-signed `mtkwl6ex.cat`).
- `Fix-MT7925-WiFi.ps1` — automation program that reproduces this whole procedure.
- `logs/` — install/verification logs from the actual fix.
- `historical/` — the failed Windows 11 driver attempt (`mtkwecx`) and original notes,
  kept for reference (do not use; KMDF 1.33 wall).
