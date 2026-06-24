# Secure Boot compatibility test — ✅ FULLY PASSED (Secure Boot ON + Wi-Fi working)

**Started:** 2026-06-24
**Result recorded:** 2026-06-24
**Final result:** 2026-06-24

## FINAL OUTCOME — both Secure Boot ON and Wi-Fi working ✅
After re-enabling Secure Boot in BIOS and rebooting, verified live:
- **Secure Boot = ON** (`Confirm-SecureBootUEFI` = True)
- **Test signing = OFF** (no `testsigning` entry in BCD)
- Device Status = **OK**, Problem = **CM_PROB_NONE**
- `netsh wlan` shows the **MediaTek Wi-Fi 7 MT7925 Wireless LAN Card** connected
  (802.11ax, 1201 Mbps TX/RX, strong signal).

**Conclusion:** the adapter works with **Secure Boot ON and test signing OFF**,
relying solely on the embedded Microsoft signature in `mtkwl6ex.sys`. No security
posture had to be weakened to keep Wi-Fi. This closes the last pending item.

## What we're testing
Whether the MT7925 driver still loads with **test signing OFF** (relying on the
Microsoft signature embedded in `mtkwl6ex.sys`, since only the catalog is self-signed).
If it does, Secure Boot can be safely re-enabled.

## Result — test signing OFF ✅ SUCCESS
Verified live after reboot:
- `testsigning` = **No** (OFF)
- Device Status = **OK**, Problem = **CM_PROB_NONE**
- `netsh wlan` shows the **MediaTek Wi-Fi 7 MT7925 Wireless LAN Card** connected
  (802.11ax, ~2402 Mbps, radio on).

**Conclusion:** the driver loads and the adapter works with test signing OFF. The
self-signed catalog is only needed at install time; once the device is bound, the
embedded Microsoft signature on `mtkwl6ex.sys` is sufficient.

## Next step — ✅ DONE
- Secure Boot re-enabled in BIOS/UEFI and rebooted. Verified Status still **OK** with
  Secure Boot **ON** + test signing **OFF**. You now have **both** Secure Boot and
  working Wi-Fi. Nothing left to do.

## After reboot — verify
```powershell
Get-PnpDevice | Where-Object { $_.HardwareID -like "*14C3*7925*" } | Format-List FriendlyName,Status,Problem
netsh wlan show interfaces
```

### If Status = OK  ➜ SUCCESS
The driver loads without test signing. Next: re-enable Secure Boot in BIOS, reboot,
and verify once more. If still OK, you have BOTH Secure Boot and Wi-Fi.

### If Status = Error (Code 39 / failed to load)  ➜ REVERT
The driver needs test signing. Restore it:
```powershell
bcdedit /set testsigning on
```
Then reboot. Wi-Fi returns. Conclusion: must keep Secure Boot OFF + test signing ON.
(This recovery needs no internet.)
