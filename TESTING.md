# RUDRA-Live-PE test checklist

Status definitions: **Completed** means the check ran and passed. **Failed** means a check did not pass. **Blocked** means it could not run because a required privilege or dependency was unavailable. **Not yet tested** means it has not been attempted.

## Completed

- Project workspace safe-write check: created and removed a harmless temporary file successfully.
- Project-local base WIM exists (340,134,390 bytes).
- Project-local base WIM SHA-256 matches C:\RUDRA-Live-PE-Build\media\sources\boot.wim: FBCBDB1C6651AB3A69384E9D4F95F2C02321318603849453B252E21E827C8197.
- ADK Deployment Tools, copype.cmd, MakeWinPEMedia.cmd, oscdimg.exe, and amd64/en-us WinPE optional-component CABs were found.
- Seven boot files were copied from the original staging tree into the project-local bootbins folder; the original remains the source and is not modified.
- PowerShell project-file/parser and path-safety checks: 28 passed, 0 failed. The suite includes a regression for the validator's Boolean `Require` condition, validation-only no-servicing/output-conflict checks, collision-safe transcript checks, report smoke checks for the four read-only diagnostic functions, and ping-target validation.
- Elevated build log confirms the project-local working WIM mounted, all five requested WinPE packages and en-us resources installed, DISM committed and unmounted the image, and MakeWinPEMedia created a 559,646,720-byte temporary ISO successfully.
- Temporary ISO: `RUDRA-Live-PE-Build\work\RUDRA-Live-PE-20261019-182219.iso` (SHA-256 `6AB12BC2A0BC219DFDCA517C345A4787E0E3852199FCB5D347EDFC3B4C08C2E5`). Project-local base WIM still matches the original staged WIM (SHA-256 `FBCBDB1C6651AB3A69384E9D4F95F2C02321318603849453B252E21E827C8197`). Final ISO and manifest paths are currently absent.

## Failed (recovered)

- An initial host smoke run reported access denied while checking C:\Windows\System32\Config\SYSTEM; recovery diagnostics were updated to handle inaccessible volumes, and the repeat suite passed. The first boot-file copy command used a literal wildcard and failed with Copy-Item: Cannot find path 'C:\RUDRA-Live-PE-Build\bootbins\*' because it does not exist. The copy was corrected to enumerate the source files; all seven expected boot files are now present in the project-local folder. No original files were changed. A supplemental ripgrep check also rejected a look-behind expression unsupported by its default regex engine; the script test suite verified the launcher type names instead.
- The latest build's final validation stopped because `Validate-RUDRA.ps1` passed the nonempty DISM executable path string directly to `Require([bool]$Condition)`. The root cause is fixed by requiring a Boolean null check and `Test-Path` result. The pre-existing build and validation logs are preserved.

## Blocked

- Structural validation of the existing temporary ISO still requires administrator privileges. The current session is not elevated; a prior read-only DISM query returned Windows error 740. Run the validation-only command below from an elevated Deployment and Imaging Tools Environment.

## Not yet tested

- ISO catalog, filesystem, WIM contents, and startup-script validation for the temporary ISO.
- Promotion of the temporary ISO into the final output path.
- WinPE diagnostics running inside a booted environment.
- BIOS or UEFI boot in a virtual machine or on hardware.
- Hardware-specific network and storage visibility.
- Log export from a live WinPE session.

## Repeatable local checks

Run these from the project folder:

    .\Test-RUDRA.ps1

After opening an elevated Deployment and Imaging Tools Environment, build and validate with:

    Set-Location 'C:\Users\krish\Documents\Codex\2026-10-19\hel-2'
    .\Build-RUDRA.ps1

To resume validation of the already-created ISO without servicing the working WIM, use:

    .\Build-RUDRA.ps1 -ValidateOnly -IsoPath '.\RUDRA-Live-PE-Build\work\RUDRA-Live-PE-20261019-182219.iso'

The temporary ISO exists, but it is not yet validated or published. This checklist records only checks actually performed; no BIOS/UEFI boot test has been run.







## Added recovery workflows (not yet VM-verified)

- Password/account recovery guidance function and launcher item.
- Lazesoft external-boot workflow; ISO booted standalone, but the password wizard did not detect a Windows installation in the current VM test.
- Disk/data recovery triage guidance.
- Technician toolkit guidance and explicit PowerShell/File Explorer launch action.
- These additions require `Test-RUDRA.ps1`, a new ISO build, and a fresh disposable-VM boot test before field use.
