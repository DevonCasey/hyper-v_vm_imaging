<#
.SYNOPSIS
    Final cleanup and preparation for Vagrant packaging

.DESCRIPTION
    Performs comprehensive cleanup operations including clearing temporary files,
    event logs, and other artifacts to minimize the size of the final golden image
    and prepare it for Vagrant box packaging.

.NOTES
    Author: Devon Casey
    Email: me@devoncasey.com
    GitHub: https://github.com/DevonCasey
    Created: July 1, 2025
#>

# Final Cleanup and Preparation for Vagrant
Write-Host "Performing final cleanup..." -ForegroundColor Yellow

try {
    # Clear Windows Update downloads
    Write-Host "Clearing Windows Update cache..." -ForegroundColor Cyan
    Stop-Service wuauserv -Force -ErrorAction SilentlyContinue
    Remove-Item C:\Windows\SoftwareDistribution\Download\* -Recurse -Force -ErrorAction SilentlyContinue
    Start-Service wuauserv -ErrorAction SilentlyContinue
    
    # Clear temporary files
    Write-Host "Clearing temporary files..." -ForegroundColor Cyan
    Remove-Item C:\Windows\Temp\* -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item C:\Temp\* -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $env:TEMP\* -Recurse -Force -ErrorAction SilentlyContinue
    
    # Clear event logs
    Write-Host "Clearing event logs..." -ForegroundColor Cyan
    wevtutil el | ForEach-Object {
        wevtutil cl "$_" 2>$null
    }
    
    # Clear browser cache and history
    Write-Host "Clearing browser data..." -ForegroundColor Cyan
    Remove-Item "$env:LOCALAPPDATA\Microsoft\Windows\Temporary Internet Files\*" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item "$env:APPDATA\Microsoft\Windows\Recent\*" -Force -ErrorAction SilentlyContinue
    
    # Clear PowerShell history
    Write-Host "Clearing PowerShell history..." -ForegroundColor Cyan
    Remove-Item "$env:APPDATA\Microsoft\Windows\PowerShell\PSReadline\*" -Force -ErrorAction SilentlyContinue
    
    # Optimize and defragment the disk
    Write-Host "Optimizing disk..." -ForegroundColor Cyan
    Optimize-Volume -DriveLetter C -Defrag -Verbose -ErrorAction SilentlyContinue
    
    # Clear DNS cache
    Write-Host "Clearing DNS cache..." -ForegroundColor Cyan
    Clear-DnsClientCache
    
    # Reset Windows Search index
    Write-Host "Resetting Windows Search..." -ForegroundColor Cyan
    Stop-Service wsearch -Force -ErrorAction SilentlyContinue
    Remove-Item C:\ProgramData\Microsoft\Search\Data\Applications\Windows\* -Recurse -Force -ErrorAction SilentlyContinue
    
    # Final registry cleanup for Vagrant
    Write-Host "Configuring registry for Vagrant..." -ForegroundColor Cyan
    
    # Ensure LocalAccountTokenFilterPolicy is set for remote management
    Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name 'LocalAccountTokenFilterPolicy' -Value 1 -Type DWord -Force
    
    # Disable shutdown event tracker
    Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Reliability' -Name 'ShutdownReasonUI' -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
    
    # Configure automatic logon count to 0 (will be managed by Vagrant)
    Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -Name 'AutoLogonCount' -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
    
    Write-Host "Final cleanup completed. System ready for Vagrant packaging." -ForegroundColor Green
}
catch {
    Write-Warning "Error during cleanup: $($_.Exception.Message)"
    # Don't fail the build for cleanup issues
}
