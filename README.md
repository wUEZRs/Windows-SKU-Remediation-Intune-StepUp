# Credit to call4cloud.nl for parts of the logic

# Windows 11 Pro to Enterprise SKU Remediation Pipeline

This repository contains automated PowerShell remediation logic designed to fix persistent issues where Windows 11 Pro devices fail to natively "Step-Up" to their licensed Enterprise subscription via Entra ID (Azure AD).

## Overview
When an organization licenses users for Windows 10/11 Enterprise E3/E5, devices joined to Entra ID should automatically step up from Pro to Enterprise without entering a product key. However, this process relies heavily on the Primary Refresh Token (PRT), the WAM (Web Account Manager) TokenBroker, the `Microsoft.AAD.BrokerPlugin`, and base Windows activation. 

If any of these components become corrupted or misconfigured, the device will remain stuck on Windows Pro. The `Invoke-WindowsSkuRemediation.ps1` script acts as a multi-tier remediation pipeline to forcefully resolve these edge cases remotely.

## Included Files
- **`Invoke-WindowsSkuRemediation.ps1`**: The main execution script. It runs through three tiers of automated repair (Standard Refresh, Base Activation Remediation, and Complete Licensing Rebuild) and provides a deep diagnostic output if the device still refuses to step-up. It is designed to be executed via SYSTEM context (e.g., through an RMM or MDM like Intune).
- **`Core_Knowledge.md`**: A detailed technical breakdown of the specific blockers this script addresses (e.g., TokenBroker cache corruption, the MFA ClipRenew loop bug, missing Broker Appx packages, and OEM channel locks), along with deeper diagnostic logic.

## Environment Support
**Disclaimer:** This script and the accompanying knowledge base were developed and tested exclusively in **Cloud-Only** (Entra ID joined) environments. It has not been tested for Hybrid Azure AD / On-Premises Active Directory setups, and Hybrid-specific identity token mechanisms (like TGTs) are not accounted for in this logic.

## Usage
Deploy `Invoke-WindowsSkuRemediation.ps1` to the affected endpoints running as SYSTEM. The script handles non-interactive deployment safely and exits with specific codes indicating success, failure, or the need for a reboot following a token cache wipe.

**Important Operational Step:** If the script wipes the token cache and requests a reboot, you should **Revoke the user's session in Entra ID** before they reboot. This forces the device to request a completely fresh Primary Refresh Token (PRT) upon the next login, pairing cleanly with the local TokenBroker cache wipe. Also expect the PC to wait 30-60 minutes to sync a final clear. We saw this happen in prod, where it would only go from PRO to ENT after a full remediation AND some time.

*Note: Review `Core_Knowledge.md` for a comprehensive understanding of what the script is doing behind the scenes.*
