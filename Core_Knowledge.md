# Windows Pro to Enterprise Subscription Step-Up

## Core Mechanism
The Subscription Step-Up (Pro to Enterprise via Entra ID) relies on:
1. **Valid Base License:** The OS must be fully activated Windows Pro.
2. **Primary Refresh Token (PRT):** The OS relies on a healthy PRT to authenticate seamlessly.
3. **Windows Store APIs:** GPO `RemoveWindowsStore=1` will block step-up.
4. **LicenseAcquisition Task:** Triggered via Task Scheduler (`\Microsoft\Windows\Subscription\`).

## Known Blockers & Remediation Strategies

### 1. TokenBroker Conflicts & Orphaned .tbacct Thrashing (0xCAA100D8)
**Symptom:** "Fix work or school account" popups, failure to sync licenses, or persistent `0x87E10C0A` MFA loops driven by underlying `0xCAA100D8` (Login hint mismatch) errors in the WAM Operational log.
**Root Cause:** If a remediation script only deletes `.tbacct` files that match existing `WorkplaceJoin` registry keys, any orphaned `.tbacct` files are left behind permanently. Over time, TokenBroker can accumulate dozens of orphaned files (e.g., 40+), completely corrupting the identity cache.
**Fix:** A Session Revoke only drops the token in the cloud. You must physically wipe the cache by unconditionally deleting ALL `.tbacct` files in `AppData\Local\Packages\Microsoft.AAD.BrokerPlugin_cw5n1h2txyewy\AC\TokenBroker\Accounts\`, regardless of whether a matching registry key exists. 
**Threshold:** On strictly single-user devices, a healthy PRT cache should have 1-2 `.tbacct` files. If you detect > 3 files, the cache is thrashing and must be aggressively purged.
**Critical Testing Note:** A reboot alone does **not** rebuild the PRT. The actual human end-user must physically type their password or use Windows Hello to log into the desktop. If you wipe the TokenBroker and attempt to trigger `LicenseAcquisition` via SYSTEM before the user logs in, WAM will have 0 tokens, and the task will instantly throw `2279672842` (Decimal for `0x87E10C0A`). **Do not let this false-positive error deceive you.** The aggressive purge successfully unblocks the license channel, allowing the OS to fetch the Enterprise SKU shortly after, despite the task scheduler throwing this error initially.

### 2. AAD Broker Plugin Appx Missing
**Symptom:** The `Microsoft.AAD.BrokerPlugin` Appx package is uninstalled or corrupted. Cloud AP cannot communicate with Entra ID.
**Fix:** Re-register for all users using:
`Add-AppxPackage -Register "C:\Windows\SystemApps\Microsoft.AAD.BrokerPlugin_cw5n1h2txyewy\Appxmanifest.xml" -DisableDevelopmentMode -ForceApplicationShutdown -AllUsers`

### 3. The MFA ClipRenew Bug (Error 0x87E10C0A)
**Symptom:** Task scheduler stuck in infinite MFA validation loop.
**Fix:** `HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\MfaRequiredInClipRenew` -> `Verify Multifactor Authentication in ClipRenew` = 0 (DWORD). Requires Interactive (S-1-5-4) read permissions.

### 4. OEM Channel Lock
**Symptom:** OS is activated but stuck on hardware OEM channel.
**Fix:** Shift via generic key: `slmgr /ipk VK7JG-NPHTM-C97JM-9MPGT-3V66T` -> `slmgr /ato`.

### 5. The "Dead SID" Red Herring (Event 1104 / 0xC00485D3 / HTTP 400)
**Symptom:** Entra ID `sidtoname` endpoint returns HTTP 400. Error `0xC00485D3` in AAD Operational Log.
**Root Cause:** This error is frequently **ambient background noise** on perfectly healthy PCs when SYSTEM processes attempt to resolve local non-AAD SIDs against the Cloud AP plugin. Do NOT assume it is the root cause of a step-up failure without verification.
**Verification:** A true "Dead SID" means the local user profile is orphaned because the Entra ID user was deleted/recreated. Verify this by decoding the local `S-1-12-1` SID back into a GUID and cross-referencing it with the user's actual Object ID in Entra ID.
**Fix:** Wiping the local Windows user profile (`C:\Users\<user>`) is only necessary if the decoded Object ID does NOT match.

### 6. LicenseAcquisition Exit Code 0 (Success Delay)
**Symptom:** `LicenseAcquisition` task runs but the OS still reports Windows 11 Pro immediately after.
**Root Cause:** The OS step-up is not instantaneous. If the Task Scheduler exit code is `0`, the acquisition succeeded. It can take up to 30 minutes (or a forced MDM Sync + Reboot) for the SKU switch to reflect in the OS caption.

### 7. WAM / TPM Failure
**Symptom:** Error `0xD0000272` and Event Log `1098`.
**Root Cause:** TPM corruption preventing decryption of PRT.
**Fix:** Clear TPM or unjoin/rejoin Entra ID.

## Diagnostic Scripting Notes
**CRITICAL:** When running diagnostics via System Context (e.g., RMM/MDM deployments), `dsregcmd /status` will always report `AzureAdPrt : NO`. PRT status must be evaluated in the Interactive User context.
