<#
.SYNOPSIS
    List and manage available Vagrant golden images

.DESCRIPTION
    This script helps manage Vagrant boxes that serve as golden images
    for the Hyper-V VM imaging workflow.

.PARAMETER List
    List all available golden image boxes

.PARAMETER Clean
    Remove old or unused golden image boxes

.PARAMETER Info
    Show detailed information about golden image boxes

.NOTES
    Author: Devon Casey
    Email: me@devoncasey.com
    GitHub: https://github.com/DevonCasey
    Created: July 2, 2025
#>

param(
    [switch]$List,
    [switch]$Clean,
    [switch]$Info,
    [string]$BoxName
)

function Get-GoldenImages {
    Write-Host "=== Available Golden Images ===" -ForegroundColor Green
    
    try {
        $boxes = vagrant box list | Where-Object { 
            $_ -match "(golden|server|windows).*hyperv" 
        }
        
        if ($boxes) {
            Write-Host "Installed Golden Image Boxes:" -ForegroundColor Yellow
            $boxes | ForEach-Object {
                $parts = $_ -split '\s+'
                $boxName = $parts[0]
                $provider = $parts[1] -replace '[()]', ''
                $version = if ($parts.Length -gt 2) { $parts[2] } else { "latest" }
                
                Write-Host "  ✓ $boxName ($provider) - $version" -ForegroundColor Cyan
            }
        } else {
            Write-Host "No golden image boxes found." -ForegroundColor Yellow
            Write-Host "Expected box names should contain: golden, server, or windows" -ForegroundColor Gray
        }
        
        Write-Host "`nTo create a new golden image:" -ForegroundColor Yellow
        Write-Host "  cd packer" -ForegroundColor Gray
        Write-Host "  packer build windows-server-2019.pkr.hcl" -ForegroundColor Gray
        Write-Host "  vagrant box add --name windows-server-2019-golden .\output-hyperv-iso\*" -ForegroundColor Gray
        
    } catch {
        Write-Error "Failed to list boxes: $($_.Exception.Message)"
    }
}

function Get-BoxInfo {
    param([string]$Name)
    
    if ([string]::IsNullOrEmpty($Name)) {
        Write-Host "Available boxes for detailed info:" -ForegroundColor Yellow
        vagrant box list | Where-Object { 
            $_ -match "(golden|server|windows)" 
        } | ForEach-Object {
            $boxName = ($_ -split '\s+')[0]
            Write-Host "  - $boxName" -ForegroundColor Cyan
        }
        return
    }
    
    Write-Host "=== Box Information: $Name ===" -ForegroundColor Green
    
    try {
        # Get basic box info
        $boxInfo = vagrant box list | Where-Object { $_ -match "^$Name\s+" }
        if ($boxInfo) {
            Write-Host "Status: Installed" -ForegroundColor Green
            Write-Host "Details: $boxInfo" -ForegroundColor Cyan
            
            # Try to get additional metadata
            $boxPath = "$env:USERPROFILE\.vagrant.d\boxes\$($Name.Replace('/', '-VAGRANTSLASH-'))"
            if (Test-Path $boxPath) {
                Write-Host "Local Path: $boxPath" -ForegroundColor Gray
                
                $metadata = Get-ChildItem $boxPath -Recurse -Name "metadata.json" -ErrorAction SilentlyContinue
                if ($metadata) {
                    Write-Host "Metadata available: Yes" -ForegroundColor Green
                } else {
                    Write-Host "Metadata available: No" -ForegroundColor Yellow
                }
            }
        } else {
            Write-Host "Status: Not installed" -ForegroundColor Red
            Write-Host "Box '$Name' is not available locally." -ForegroundColor Yellow
        }
    } catch {
        Write-Error "Failed to get box info: $($_.Exception.Message)"
    }
}

function Remove-OldBoxes {
    Write-Host "=== Cleaning Old Golden Images ===" -ForegroundColor Green
    
    Write-Host "This will show you old boxes that can be removed..." -ForegroundColor Yellow
    Write-Host "WARNING: This is a dry-run. Review before actual deletion." -ForegroundColor Red
    
    try {
        $allBoxes = vagrant box list | Where-Object { 
            $_ -match "(golden|server|windows)" 
        }
        
        if ($allBoxes) {
            Write-Host "`nFound golden image boxes:" -ForegroundColor Yellow
            $allBoxes | ForEach-Object {
                $boxName = ($_ -split '\s+')[0]
                Write-Host "  $boxName" -ForegroundColor Cyan
                
                # You could add logic here to detect old versions
                # For now, just list them for manual review
            }
            
            Write-Host "`nTo remove a specific box:" -ForegroundColor Yellow
            Write-Host "  vagrant box remove <box-name>" -ForegroundColor Gray
            Write-Host "`nTo remove all versions of a box:" -ForegroundColor Yellow
            Write-Host "  vagrant box remove <box-name> --all" -ForegroundColor Gray
        } else {
            Write-Host "No golden image boxes found to clean." -ForegroundColor Green
        }
    } catch {
        Write-Error "Failed to clean boxes: $($_.Exception.Message)"
    }
}

# Main execution
if ($List) {
    Get-GoldenImages
} elseif ($Info) {
    Get-BoxInfo -Name $BoxName
} elseif ($Clean) {
    Remove-OldBoxes
} else {
    Write-Host "Vagrant Golden Image Manager" -ForegroundColor Green
    Write-Host "=============================" -ForegroundColor Green
    Write-Host ""
    Write-Host "Usage:" -ForegroundColor Yellow
    Write-Host "  .\Manage-GoldenImages.ps1 -List                    # List available boxes"
    Write-Host "  .\Manage-GoldenImages.ps1 -Info -BoxName <name>    # Get box information"
    Write-Host "  .\Manage-GoldenImages.ps1 -Clean                   # Clean old boxes"
    Write-Host ""
    
    # Show quick summary
    Get-GoldenImages
}
