<#
.SYNOPSIS
    Configure WinRM for Packer communication during VM provisioning

.DESCRIPTION
    Sets up WinRM service with appropriate authentication and encryption settings
    to allow Packer to communicate with the VM during the build process.

.NOTES
    Author: Devon Casey
    Email: me@devoncasey.com
    GitHub: https://github.com/DevonCasey
    Created: July 1, 2025
#>

# Configure WinRM for Packer
Write-Host "Configuring WinRM..." -ForegroundColor Yellow

# Enable WinRM service
Enable-PSRemoting -Force -ErrorAction SilentlyContinue
Set-Service WinRM -StartupType Automatic
Start-Service WinRM

# Configure WinRM settings
& winrm quickconfig -q -force
& winrm set winrm/config/service/auth '@{Basic="true"}'
& winrm set winrm/config/service '@{AllowUnencrypted="true"}'
& winrm set winrm/config/winrs '@{MaxMemoryPerShellMB="2048"}'

# Set network location to private to enable WinRM
Get-NetConnectionProfile | Set-NetConnectionProfile -NetworkCategory Private

Write-Host "WinRM configuration completed." -ForegroundColor Green
