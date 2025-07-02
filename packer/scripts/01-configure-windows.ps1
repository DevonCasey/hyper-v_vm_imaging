<#
.SYNOPSIS
    Configure Windows settings for scalable golden image

.DESCRIPTION
    Applies essential Windows configuration changes to create a stable,
    scalable golden image. Focuses on system-level settings that benefit
    all derived VMs while avoiding environment-specific configurations.

.NOTES
    Author: Devon Casey
    Email: me@devoncasey.com
    GitHub: https://github.com/DevonCasey
    Created: July 2, 2025
#>

# Configure Windows Settings for Golden Image
Write-Host "Configuring Windows for golden image..." -ForegroundColor Yellow

try {
    # === POWER MANAGEMENT ===
    # Configure power settings for VM stability and performance
    Write-Host "Configuring power settings..." -ForegroundColor Cyan
    & powercfg.exe /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c  # High Performance
    & powercfg.exe /change standby-timeout-ac 0      # Never standby
    & powercfg.exe /change hibernate-timeout-ac 0    # Never hibernate
    & powercfg.exe /change monitor-timeout-ac 0      # Never turn off monitor
    & powercfg.exe /change disk-timeout-ac 0         # Never turn off disks
    
    # === REMOTE MANAGEMENT ===
    # Enable Remote Desktop for VM management
    Write-Host "Enabling Remote Desktop..." -ForegroundColor Cyan
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server" -Name "fDenyTSConnections" -Value 0 -Type DWord
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" -Name "UserAuthentication" -Value 0 -Type DWord
    Enable-NetFirewallRule -DisplayGroup "Remote Desktop"
    
    # Configure WinRM service for Vagrant/automation reliability
    Write-Host "Configuring WinRM service..." -ForegroundColor Cyan
    Set-Service -Name WinRM -StartupType Automatic -ErrorAction SilentlyContinue
    Set-Service -Name RemoteRegistry -StartupType Automatic -ErrorAction SilentlyContinue
    
    # === TIME AND UPDATES ===
    # Set timezone to EST (best practice for VMs and cloud environments)
    Write-Host "Setting timezone to EST..." -ForegroundColor Cyan
    & tzutil.exe /s "Eastern Standard Time"
    
    # Configure Windows Updates to manual (prevents interference during provisioning)
    Write-Host "Configuring Windows Update settings..." -ForegroundColor Cyan
    Set-Service -Name wuauserv -StartupType Manual -ErrorAction SilentlyContinue
    
    # Disable automatic restart after updates (prevents unexpected reboots)
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" -Name "UxOption" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
    
    # === SYSTEM RELIABILITY ===
    # Disable Windows Error Reporting (reduces noise in golden image)
    Write-Host "Disabling Windows Error Reporting..." -ForegroundColor Cyan
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting" -Name "Disabled" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting" -Name "DontSendAdditionalData" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
    
    # Disable automatic sample submission
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Spynet" -Name "SubmitSamplesConsent" -Value 2 -Type DWord -Force -ErrorAction SilentlyContinue
    
    # === PERFORMANCE OPTIMIZATIONS ===
    # Disable unnecessary visual effects for better VM performance
    Write-Host "Optimizing visual performance..." -ForegroundColor Cyan
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" -Name "VisualFXSetting" -Value 2 -Type DWord -Force -ErrorAction SilentlyContinue
    
    # Disable System Restore (saves disk space in golden image)
    Write-Host "Disabling System Restore..." -ForegroundColor Cyan
    try {
        Disable-ComputerRestore -Drive "C:\" -ErrorAction SilentlyContinue
        vssadmin delete shadows /for=C: /all /quiet 2>$null
    } catch {
        Write-Warning "Could not disable System Restore: $($_.Exception.Message)"
    }
    
    # === DISK AND STORAGE ===
    # Disable hibernation (saves disk space)
    Write-Host "Disabling hibernation..." -ForegroundColor Cyan
    & powercfg.exe /hibernate off
    
    # Disable paging file on C: drive (can be reconfigured per environment)
    Write-Host "Configuring virtual memory..." -ForegroundColor Cyan
    try {
        $cs = Get-WmiObject -Class Win32_ComputerSystem -EnableAllPrivileges
        $cs.AutomaticManagedPagefile = $false
        $cs.Put() | Out-Null
        
        Get-WmiObject -Class Win32_PageFileSetting | ForEach-Object { $_.Delete() }
        Write-Host "Disabled automatic paging file. Can be reconfigured per environment." -ForegroundColor Green
    } catch {
        Write-Warning "Could not configure virtual memory: $($_.Exception.Message)"
    }
    
    # === NETWORK OPTIMIZATION ===
    # Configure network adapter settings for VM environments
    Write-Host "Optimizing network settings..." -ForegroundColor Cyan
    
    # Disable IPv6 (often not needed in VM environments)
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters" -Name "DisabledComponents" -Value 255 -Type DWord -Force -ErrorAction SilentlyContinue
    
    # Configure TCP settings for VM environments
    netsh int tcp set global autotuninglevel=normal 2>$null
    netsh int tcp set global chimney=enabled 2>$null
    netsh int tcp set global rss=enabled 2>$null
    
    # === SECURITY BASELINE ===
    # Configure basic security settings appropriate for golden image
    Write-Host "Applying security baseline..." -ForegroundColor Cyan
    
    # Disable anonymous SID enumeration
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa" -Name "RestrictAnonymousSAM" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa" -Name "RestrictAnonymous" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
    
    # Configure audit policy (basic logging)
    auditpol /set /category:"Logon/Logoff" /success:enable /failure:enable 2>$null
    auditpol /set /category:"Account Management" /success:enable /failure:enable 2>$null
    
    # === SERVICES OPTIMIZATION ===
    # Disable unnecessary services for golden image
    Write-Host "Optimizing services..." -ForegroundColor Cyan
    
    $ServicesToDisable = @(
        'Fax',                    # Fax service
        'SharedAccess',           # Internet Connection Sharing
        'TapiSrv',               # Telephony service
        'WMPNetworkSvc',         # Windows Media Player Network Sharing
        'WSearch'                # Windows Search (can be re-enabled per environment)
    )
    
    foreach ($Service in $ServicesToDisable) {
        try {
            $ServiceObj = Get-Service -Name $Service -ErrorAction SilentlyContinue
            if ($ServiceObj -and $ServiceObj.Status -ne 'Stopped') {
                Stop-Service -Name $Service -Force -ErrorAction SilentlyContinue
                Set-Service -Name $Service -StartupType Disabled -ErrorAction SilentlyContinue
                Write-Host "Disabled service: $Service" -ForegroundColor Gray
            }
        } catch {
            # Service might not exist, continue
        }
    }
    
    Write-Host "Golden image Windows configuration completed successfully." -ForegroundColor Green
    Write-Host "Configuration optimized for scalability and VM environments." -ForegroundColor Green
}
catch {
    Write-Warning "Error during Windows configuration: $($_.Exception.Message)"
    Write-Warning "Golden image may not be fully optimized, but build can continue."
}
