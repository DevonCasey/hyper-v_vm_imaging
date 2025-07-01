<#
.SYNOPSIS
    Install common tools and utilities via Chocolatey

.DESCRIPTION
    Installs essential tools like Notepad++ and Google Chrome to provide
    a basic set of utilities in the golden image.

.NOTES
    Author: Devon Casey
    Email: me@devoncasey.com
    GitHub: https://github.com/DevonCasey
    Created: July 1, 2025
#>

# Install Common Tools
Write-Host "Installing common tools..." -ForegroundColor Yellow

try {
    # Install common tools via Chocolatey
    $tools = @(
        'notepadplusplus',
        'googlechrome'
    )
    
    foreach ($tool in $tools) {
        try {
            Write-Host "Installing $tool..." -ForegroundColor Cyan
            & choco install $tool -y --limit-output
            if ($LASTEXITCODE -eq 0) {
                Write-Host "$tool installed successfully." -ForegroundColor Green
            } else {
                Write-Warning "Failed to install $tool (exit code: $LASTEXITCODE)"
            }
        }
        catch {
            Write-Warning "Error installing $tool`: $($_.Exception.Message)"
        }
    }
    
    # Refresh environment variables
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
    
    Write-Host "Tools installation completed." -ForegroundColor Green
}
catch {
    Write-Warning "Error during tools installation: $($_.Exception.Message)"
    # Continue without failing the build
}
