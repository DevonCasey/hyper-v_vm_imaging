<#
.SYNOPSIS
    Configure Windows settings for golden image optimization

.DESCRIPTION
    Applies various Windows configuration changes including UAC settings,
    Windows Defender configuration, and Windows Update settings to optimize
    the system for use as a golden image template.

.NOTES
    Author: Devon Casey
    Email: me@devoncasey.com
    GitHub: https://github.com/DevonCasey
    Created: July 1, 2025
#>

# Configure Windows Settings
Write-Host "Configuring Windows settings..." -ForegroundColor Yellow

try {
    # Disable User Account Control (UAC)
    Write-Host "Disabling UAC..." -ForegroundColor Cyan
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "EnableLUA" -Value 0 -Type DWord
    
    # Disable Windows Defender (for golden image)
    Write-Host "Configuring Windows Defender..." -ForegroundColor Cyan
    try {
        Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction SilentlyContinue
        Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender" -Name "DisableAntiSpyware" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
    }
    catch {
        Write-Warning "Could not disable Windows Defender: $($_.Exception.Message)"
    }
    
    # Configure Windows Updates to manual
    Write-Host "Configuring Windows Update settings..." -ForegroundColor Cyan
    Set-Service -Name wuauserv -StartupType Manual -ErrorAction SilentlyContinue
    
    # Disable Windows Error Reporting
    Write-Host "Disabling Windows Error Reporting..." -ForegroundColor Cyan
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting" -Name "Disabled" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
    
    # Configure power settings for servers
    Write-Host "Configuring power settings..." -ForegroundColor Cyan
    & powercfg.exe /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c  # High Performance
    & powercfg.exe /change standby-timeout-ac 0
    & powercfg.exe /change hibernate-timeout-ac 0
    
    # Enable Remote Desktop
    Write-Host "Enabling Remote Desktop..." -ForegroundColor Cyan
    Set-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server" -Name "fDenyTSConnections" -Value 0 -Type DWord
    Enable-NetFirewallRule -DisplayGroup "Remote Desktop"
    
    # Configure time zone
    Write-Host "Setting time zone to Eastern Standard Time..." -ForegroundColor Cyan
    & tzutil.exe /s "Eastern Standard Time"
    
    # Disable automatic sample submission
    Write-Host "Disabling automatic sample submission..." -ForegroundColor Cyan
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting" -Name "DontSendAdditionalData" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
    
    Write-Host "Windows configuration completed." -ForegroundColor Green
}
catch {
    Write-Warning "Error configuring Windows: $($_.Exception.Message)"
    # Continue without failing the build
}
