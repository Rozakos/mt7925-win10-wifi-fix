# Contributing

Thanks for helping improve the MT7925 Windows 10 Wi-Fi fix! Contributions of all
sizes are welcome — especially **compatibility reports** from laptops other than the
one this was first solved on.

## The most useful contribution: a compatibility report

If you ran the tool on your machine, please open a
[Compatibility report](../../issues/new/choose) and include your **laptop model** and
**PCI hardware ID** (the form has a one-line PowerShell command to get it). Reports of
both successes *and* failures help confirm the subsystem auto-detection works across
OEM variants. This is the single most valuable thing you can do.

## Reporting a bug

Open an issue with:
- What you expected vs. what happened
- The device's final Status/Problem and any error code (Code 28 / 37 / 39)
- A relevant excerpt from the log the tool wrote (redact your MAC/SSID/BSSID)
- Your Windows version (`winver`) and which front-end you used (GUI or CLI)

## Project layout

```
MT7925-Fix-GUI.ps1      WinForms GUI (presentation only)
Fix-MT7925-WiFi.ps1     CLI front-end (presentation only)
engine/MT7925-Core.ps1  All the real logic lives here
```

**Key principle: the engine is the single source of truth.** The GUI and CLI are thin
front-ends over `engine/MT7925-Core.ps1`. Put behavior changes in the engine so both
front-ends stay in sync — don't duplicate logic into a front-end.

The engine emits all progress through a pluggable log sink (`Set-MTLogSink`), so the
same functions can print to a console, a file, or stream into the GUI. Read-only state
queries (`Get-MTState`, `Get-MTDevice`, `Test-MTSecureBoot`, `Test-MTTestSigning`) have
no side effects and drive the phase state machine; the action functions
(`Enable-MTTestSigning`, `Invoke-MTInstall`, `Disable-MTTestSigning`) require admin.

## Coding conventions

- **PowerShell 5.1 compatible** — this targets in-box Windows 10 PowerShell. Don't use
  PS 7+ only syntax (`&&`, `||`, ternary, `??`, `?.`).
- **ASCII only** in `.ps1` files, and save them **UTF-8 with BOM**. Non-ASCII
  characters (e.g. em dashes) without a BOM get mis-decoded by PS 5.1 and break
  parsing. Use `-` instead of `—`.
- Match the surrounding style: 4-space indent, comment-based help headers on scripts,
  short banner comments (`# --- section ---`) for sections.
- Keep firmware steps (Secure Boot) as *guided + verified*, never assume they can be
  toggled from code — they can't.

## Do NOT commit

- **Proprietary driver binaries** (`mtkwl6ex.sys/.dll/.dat`, `mtkwecx.*`, any vendor
  `.sys/.cat`). They belong to MediaTek / the OEM and are intentionally excluded; the
  tool uses the copy already on the user's machine. The `.gitignore` blocks `driver/`
  and `historical/`.
- **Personal data** — run logs contain MAC, SSID, BSSID, and hostname. `logs/` and
  `*.log` are gitignored. Scrub any such values from docs or pasted output.

## Testing your changes

No build step. Before opening a PR, sanity-check locally:

```powershell
# 1. Parse-check every script (no errors expected)
foreach ($f in 'engine\MT7925-Core.ps1','MT7925-Fix-GUI.ps1','Fix-MT7925-WiFi.ps1') {
    $errs = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile(
        (Resolve-Path $f), [ref]$null, [ref]$errs)
    if ($errs) { "ERRORS in $f:"; $errs } else { "OK: $f" }
}

# 2. Exercise the read-only engine state (safe; no changes)
. .\engine\MT7925-Core.ps1
Get-MTState | Format-List
```

If you changed install behavior, please note in the PR how you tested it (ideally on a
real MT7925 machine) — the install path makes system changes and can't be fully
verified on already-working hardware.

## Pull requests

- Keep PRs focused; describe what changed and why.
- Note which laptop/hardware you tested on.
- By contributing, you agree your changes are released under the repository's
  [MIT License](LICENSE).
