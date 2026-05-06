function Invoke-Remediation {
    $ErrorActionPreference = 'Stop'

    $preCheckOS = Get-CimInstance Win32_OperatingSystem
    if ($preCheckOS.Caption -match "Enterprise") {
        Write-Output "PRE-CHECK: Device is already running $($preCheckOS.Caption). No remediation needed."
        return
    }

    Write-Output "--- PRE-REQUISITE: Evaluating WorkplaceJoin TokenBroker Conflicts ---"
    $cloudDomainJoinPath = "Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\CloudDomainJoin\JoinInfo"
    $primaryDomain = $null
    if (Test-Path $cloudDomainJoinPath) {
        $cloudGuids = Get-ChildItem -Path $cloudDomainJoinPath -ErrorAction SilentlyContinue
        foreach ($guid in $cloudGuids) {
            $props = Get-ItemProperty -Path $guid.PSPath -ErrorAction SilentlyContinue
            if ($props.UserEmail) { $primaryDomain = $props.UserEmail -replace '^[^@]+@', ''; break }
        }
    }

    $userSIDs = Get-ChildItem -Path "Registry::HKEY_USERS" -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match "^S-1-\d+(-\d+)+$" -and $_.PSChildName -notmatch "_Classes$" -and $_.PSChildName -notmatch "^S-1-5-(18|19|20)$" }
    $accountsToRemove = @()
    foreach ($user in $userSIDs) {
        $joinInfoBasePath = "Registry::HKEY_USERS\$($user.PSChildName)\Software\Microsoft\Windows NT\CurrentVersion\WorkplaceJoin\JoinInfo"
        if (Test-Path $joinInfoBasePath) {
            $guids = Get-ChildItem $joinInfoBasePath -ErrorAction SilentlyContinue
            foreach ($guid in $guids) {
                $props = Get-ItemProperty -Path $guid.PSPath -ErrorAction SilentlyContinue
                if ($props.UserEmail -and $primaryDomain) {
                    $accountsToRemove += [PSCustomObject]@{ UserEmail = $props.UserEmail; GuidPath = $guid.PSPath }
                }
            }
        }
    }

    if ($accountsToRemove.Count -gt 0) {
        Write-Output "CRITICAL ERROR: Found $($accountsToRemove.Count) orphaned WorkplaceJoin entries in the registry."
        Write-Output "-> AUTO-REMEDIATING: Deleting conflicting TokenBroker .tbacct files and Registry keys..."
        $basePath = "C:\Users"
        $relativePath = "AppData\Local\Packages\Microsoft.AAD.BrokerPlugin_cw5n1h2txyewy\AC\TokenBroker\Accounts"
        foreach ($account in $accountsToRemove) {
            $searchTerm = $account.UserEmail
            foreach ($userProfile in Get-ChildItem -Path $basePath -Directory -ErrorAction SilentlyContinue) {
                $folderPath = Join-Path -Path $userProfile.FullName -ChildPath $relativePath
                if (Test-Path -Path $folderPath) {
                    $tbacctFiles = Get-ChildItem -Path $folderPath -Filter "*.tbacct" -ErrorAction SilentlyContinue
                    foreach ($file in $tbacctFiles) {
                        $fileContent = [System.IO.File]::ReadAllBytes($file.FullName)
                        $textContent = -join ($fileContent | ForEach-Object { if ($_ -ge 0x20 -and $_ -le 0x7E) { [char]$_ } })
                        if ($textContent -like "*$searchTerm*") { Remove-Item -Path $file.FullName -Force -ErrorAction SilentlyContinue }
                    }
                }
            }
            Remove-Item -Path $account.GuidPath -Recurse -Force -ErrorAction SilentlyContinue
        }
        Write-Output "-> REMEDIATION COMPLETE: Duplicate accounts purged."
        Write-Output "ACTION REQUIRED: Revoke the user's session in Entra ID now, before the user reboots."
        Write-Output "NOTE: Returning Exit Code 33 to signal the RMM to trigger a reboot prompt after identity remediation."
        [Environment]::ExitCode = 33
        return
    }

    Write-Output "--- PRE-REQUISITE: Evaluating AAD Broker Plugin ---"
    $brokerPkgs = @(Get-AppxPackage -Name "Microsoft.AAD.BrokerPlugin" -AllUsers -ErrorAction SilentlyContinue)
    $brokerPkg = if ($brokerPkgs.Count -gt 0) { $brokerPkgs[0] } else { $null }

    if ($brokerPkg -and $brokerPkg.Version -match "^1000\.19041") {
        Write-Output "WARNING: Legacy AAD Broker Plugin detected. Forcing Appx Upgrade..."
        $loggedOnUser = (Get-CimInstance Win32_ComputerSystem).UserName
        if ($loggedOnUser) {
            $stName = "FixAADBroker_$(Get-Random)"
            $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-WindowStyle Hidden -Command `"Add-AppxPackage -Register 'C:\Windows\SystemApps\Microsoft.AAD.BrokerPlugin_cw5n1h2txyewy\Appxmanifest.xml' -DisableDevelopmentMode -ForceApplicationShutdown`""
            $principal = New-ScheduledTaskPrincipal -UserId $loggedOnUser -LogonType Interactive
            $taskDef = New-ScheduledTask -Action $action -Principal $principal
            Register-ScheduledTask -TaskName $stName -InputObject $taskDef -Force -ErrorAction SilentlyContinue | Out-Null
            Start-ScheduledTask -TaskName $stName -ErrorAction SilentlyContinue | Out-Null
            Start-Sleep -Seconds 5
            Unregister-ScheduledTask -TaskName $stName -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
            Write-Output "-> Appx upgrade dispatched."
        }
    }

    Write-Output "--- TIER 1: Standard License Acquisition Refresh ---"
    Get-ScheduledTask -TaskName 'LicenseAcquisition' -TaskPath "\Microsoft\Windows\Subscription\" | Start-ScheduledTask
    Write-Output "Waiting 3 minutes for Entra ID License Step-up to process..."
    Start-Sleep -Seconds 180

    $OS = Get-CimInstance Win32_OperatingSystem
    if ($OS.Caption -match "Enterprise") {
        Write-Output "SUCCESS: Device successfully upgraded to $($OS.Caption) with Tier 1 Refresh."
        return
    }

    Write-Output "Tier 1 FAILED. Device is still running $($OS.Caption). Proceeding to TIER 2 (Base Activation Remediation)..."

    # --- TIER 2: BASE ACTIVATION REMEDIATION ---
    Write-Output "Step 1: Shifting license channel from OEM to Retail..."
    cscript //nologo $env:SystemRoot\System32\slmgr.vbs /ipk VK7JG-NPHTM-C97JM-9MPGT-3V66T | Out-Null

    Write-Output "Step 2: Triggering base Windows activation..."
    cscript //nologo $env:SystemRoot\System32\slmgr.vbs /ato | Out-Null

    Write-Output "Step 3: Applying MFA ClipRenew Registry Bypass..."
    $registryPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\MfaRequiredInClipRenew"
    if (-not (Test-Path -Path $registryPath)) {
        New-Item -Path $registryPath -Force | Out-Null
    }
    Set-ItemProperty -Path $registryPath -Name "Verify Multifactor Authentication in ClipRenew" -Value 0 -Type DWORD
    $acl = Get-Acl -Path $registryPath
    $sid = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-4")
    $ruleSID = New-Object System.Security.AccessControl.RegistryAccessRule($sid, "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")
    $acl.AddAccessRule($ruleSID)
    Set-Acl -Path $registryPath -AclObject $acl

    Write-Output "Step 4: Triggering Subscription License Acquisition..."
    Get-ScheduledTask -TaskName 'LicenseAcquisition' -TaskPath "\Microsoft\Windows\Subscription\" | Start-ScheduledTask

    Write-Output "Waiting 3 minutes for Entra ID License Step-up to process..."
    Start-Sleep -Seconds 180

    $OS = Get-CimInstance Win32_OperatingSystem
    if ($OS.Caption -match "Enterprise") {
        Write-Output "SUCCESS: Device successfully upgraded to $($OS.Caption) with Tier 2 Remediation."
        return
    }

    Write-Output "Tier 2 FAILED. Device is still running $($OS.Caption). Proceeding to TIER 3 (Complete Licensing Rebuild)..."

    # --- TIER 3: COMPLETE LICENSING REBUILD ---
    Write-Output "Step 1: Uninstalling existing product key and clearing registry..."
    cscript //nologo $env:SystemRoot\System32\slmgr.vbs /upk | Out-Null
    cscript //nologo $env:SystemRoot\System32\slmgr.vbs /cpky | Out-Null

    Write-Output "Step 2: Reinstalling system license files..."
    cscript //nologo $env:SystemRoot\System32\slmgr.vbs /rilc | Out-Null

    Write-Output "Step 3: Re-applying Generic Retail Pro Key..."
    cscript //nologo $env:SystemRoot\System32\slmgr.vbs /ipk VK7JG-NPHTM-C97JM-9MPGT-3V66T | Out-Null

    Write-Output "Step 4: Triggering base Windows activation..."
    cscript //nologo $env:SystemRoot\System32\slmgr.vbs /ato | Out-Null

    Write-Output "Step 5: Verifying Windows Store is not blocked by Policy..."
    $storeRegPath = "HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore"
    if (Test-Path $storeRegPath) {
        $blocked = Get-ItemProperty -Path $storeRegPath -Name "RemoveWindowsStore" -ErrorAction SilentlyContinue
        if ($blocked.RemoveWindowsStore -eq 1) {
            Write-Output "Removing Windows Store block..."
            Set-ItemProperty -Path $storeRegPath -Name "RemoveWindowsStore" -Value 0 -Type DWORD
        }
    }

    Write-Output "Step 6: Triggering Subscription License Acquisition..."
    Get-ScheduledTask -TaskName 'LicenseAcquisition' -TaskPath "\Microsoft\Windows\Subscription\" | Start-ScheduledTask

    Write-Output "Waiting 3 minutes for Entra ID License Step-up to process..."
    Start-Sleep -Seconds 180

    $OS = Get-CimInstance Win32_OperatingSystem
    if ($OS.Caption -match "Enterprise") {
        Write-Output "SUCCESS: Device successfully upgraded to $($OS.Caption) with Tier 3 Rebuild."
        return
    }
    else {
        Write-Output "--- MICROSOFT SUPPORT DIAGNOSTIC SUMMARY ---"
        Write-Output "Device failed to step-up to Enterprise after 3 tiers of remediation."

        $allLic = Get-CimInstance SoftwareLicensingProduct -Filter "PartialProductKey IS NOT NULL"
        $baseArray = @($allLic | Where-Object { $_.Name -match "Windows.*(Pro|Core|Home)" -and $_.Name -notmatch "Enterprise" })
        $base = if ($baseArray.Count -gt 0) { $baseArray[0] } else { $null }

        if ($base -and $base.LicenseStatus -ne 1) {
            Write-Output "CRITICAL ERROR: Base OS is NOT properly activated. License Status is $($base.LicenseStatus). Check internet access to MS Activation Servers."
        }

        $storeRegPath = "HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore"
        $blocked = Get-ItemProperty -Path $storeRegPath -Name "RemoveWindowsStore" -ErrorAction SilentlyContinue
        if ($blocked.RemoveWindowsStore -eq 1) {
            Write-Output "CRITICAL ERROR: Windows Store is explicitly blocked by Policy/GPO. Subscription step-up requires Store APIs to function."
        }

        $brokerPkgs = @(Get-AppxPackage -Name "Microsoft.AAD.BrokerPlugin" -AllUsers -ErrorAction SilentlyContinue)
        $brokerPkg = if ($brokerPkgs.Count -gt 0) { $brokerPkgs[0] } else { $null }
    
        if ($brokerPkg) {
            if ($brokerPkg.Version -match "^1000\.19041") {
                Write-Output "WARNING: Microsoft.AAD.BrokerPlugin is running legacy version ($($brokerPkg.Version)). Appx auto-upgrade may have failed."
            }
        }
        else {
            Write-Output "CRITICAL ERROR: Microsoft.AAD.BrokerPlugin Appx Package is MISSING!"
        }

        $taskName = "LicenseAcquisition"
        $taskPath = "\Microsoft\Windows\Subscription\"
        $task = Get-ScheduledTask -TaskName $taskName -TaskPath $taskPath -ErrorAction SilentlyContinue

        if ($task) {
            $lastRun = $task | Get-ScheduledTaskInfo
            $hexResult = "0x$($lastRun.LastTaskResult.ToString('X'))"
            if ($lastRun.LastTaskResult -ne 0) {
                Write-Output "CRITICAL ERROR: LicenseAcquisition task failed with error code $hexResult."
                if ($hexResult -eq "0x87E10C0A") { Write-Output "  -> Indicates MFA ClipRenew loop or Entra token failure. Primary TokenBroker cache must be wiped." }
                if ($hexResult -eq "0xD0000272") { Write-Output "  -> Indicates WAM Token decryption failure, often caused by TPM corruption." }
                if ($hexResult -eq "0x80072EE2") { 
                    Write-Output "  -> Indicates ERROR_INTERNET_TIMEOUT (Proxy/Firewall blocking MS servers)." 
                    Write-Output "  -> NETWORK DIAGNOSTIC:"
                    ipconfig /flushdns | Out-Null
                    $dnsTest = Resolve-DnsName licensing.mp.microsoft.com -ErrorAction SilentlyContinue
                    if ($dnsTest) { Write-Output "     - DNS Resolution to licensing.mp.microsoft.com: SUCCESS" } else { Write-Output "     - DNS Resolution to licensing.mp.microsoft.com: FAILED" }
                    $tcpTest = Test-NetConnection licensing.mp.microsoft.com -Port 443 -WarningAction SilentlyContinue
                    if ($tcpTest.TcpTestSucceeded) { Write-Output "     - TCP Port 443 Connection: SUCCESS" } else { Write-Output "     - TCP Port 443 Connection: FAILED (Blocked by Firewall/Proxy)" }
                }
                [Environment]::ExitCode = 1
                return
            }
            else {
                Write-Output "SUCCESS: LicenseAcquisition task completed without errors (Exit Code 0)."
                Write-Output "NOTE: The OS has not yet updated its caption to Enterprise, but the license has been acquired. It can take up to 30 minutes, an Intune Sync, and a Reboot for the change to fully apply."
                [Environment]::ExitCode = 0
                return
            }
        }
        else {
            Write-Output "CRITICAL ERROR: LicenseAcquisition Scheduled Task is MISSING from the OS."
            [Environment]::ExitCode = 1
            return
        }
    }

}

Invoke-Remediation
