<#
.SYNOPSIS
    Install Chocolatey package manager for Windows

.DESCRIPTION
    Installs or upgrades Chocolatey package manager to enable easy software
    installation during the VM provisioning process.

.NOTES
    Author: Devon Casey
    Email: me@devoncasey.com
    GitHub: https://github.com/DevonCasey
    Created: July 1, 2025
#>

# Install Chocolatey Package Manager
Write-Host "Installing Chocolatey..." -ForegroundColor Yellow

try {
    # Check if Chocolatey is already installed
    if (Get-Command choco -ErrorAction SilentlyContinue) {
        Write-Host "Chocolatey is already installed." -ForegroundColor Green
        & choco upgrade chocolatey -y
    } else {
        # Install Chocolatey
        Set-ExecutionPolicy Bypass -Scope Process -Force
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
        Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
        
        # Verify installation
        if (Get-Command choco -ErrorAction SilentlyContinue) {
            Write-Host "Chocolatey installed successfully." -ForegroundColor Green
        } else {
            throw "Chocolatey installation failed"
        }
    }
    
    # Configure Chocolatey
    & choco feature enable -n allowGlobalConfirmation
    & choco feature enable -n useRememberedArgumentsForUpgrades
    
    Write-Host "Chocolatey configuration completed." -ForegroundColor Green
}
catch {
    Write-Warning "Error installing Chocolatey: $($_.Exception.Message)"
}
