<#
.SYNOPSIS
    Install Windows Updates during golden image creation

.DESCRIPTION
    Installs the latest Windows updates using the PSWindowsUpdate module
    to ensure the golden image includes current security patches and fixes.

.NOTES
    Author: Devon Casey
    Email: me@devoncasey.com
    GitHub: https://github.com/DevonCasey
    Created: July 1, 2025
#>

# Install Windows Updates
Write-Host "Installing Windows Updates..." -ForegroundColor Yellow

try {
    # Install PSWindowsUpdate module if not present
    if (-not (Get-Module -ListAvailable -Name PSWindowsUpdate)) {
        Write-Host "Installing PSWindowsUpdate module..." -ForegroundColor Cyan
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
        Install-Module PSWindowsUpdate -Force
    }
    
    Import-Module PSWindowsUpdate -Force
    
    # Get list of available updates
    Write-Host "Checking for available updates..." -ForegroundColor Cyan
    $updates = Get-WUList -MicrosoftUpdate
    
    if ($updates.Count -gt 0) {
        Write-Host "Found $($updates.Count) updates. Installing..." -ForegroundColor Cyan
        
        # Install updates (excluding driver updates to avoid issues)
        Get-WUInstall -MicrosoftUpdate -NotCategory "Drivers" -AcceptAll -AutoReboot:$false -Verbose
        
        Write-Host "Windows Updates installation completed." -ForegroundColor Green
        
        # Check if reboot is required (with error handling)
        try {
            $rebootRequired = Get-WURebootStatus -Silent -ErrorAction SilentlyContinue
            if ($rebootRequired) {
                Write-Host "Reboot is required after updates. This will be handled by Packer." -ForegroundColor Yellow
            } else {
                Write-Host "No reboot required after updates." -ForegroundColor Green
            }
        } catch {
            Write-Host "Note: Could not check reboot status (this is normal in some environments)" -ForegroundColor Yellow
        }
    } else {
        Write-Host "No updates available." -ForegroundColor Green
    }
}
catch {
    Write-Warning "Error installing updates: $($_.Exception.Message)"
    # Continue without failing the build - updates are not critical for golden image creation
    Write-Host "Continuing build without updates..." -ForegroundColor Yellow
}
