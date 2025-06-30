# Script to check available Windows editions in your ISO
param(
    [Parameter(Mandatory = $true)]
    [string]$IsoPath = "F:\Install\Microsoft\Windows Server\WinServer_2022.iso"
)

Write-Host "Checking Windows editions in ISO: $IsoPath" -ForegroundColor Green

try {
    # Mount the ISO
    $mount = Mount-DiskImage -ImagePath $IsoPath -PassThru
    $driveLetter = ($mount | Get-Volume).DriveLetter + ":"
    
    # Find the install.wim file
    $wimPath = "$driveLetter\sources\install.wim"
    if (-not (Test-Path $wimPath)) {
        $wimPath = "$driveLetter\sources\install.esd"
    }
    
    if (Test-Path $wimPath) {
        Write-Host "Found Windows image file: $wimPath" -ForegroundColor Yellow
        Write-Host "`nAvailable Windows editions:" -ForegroundColor Cyan
        Write-Host "=" * 50
        
        # Get image information
        $images = Get-WindowsImage -ImagePath $wimPath
        
        foreach ($image in $images) {
            Write-Host "Index: $($image.ImageIndex)" -ForegroundColor White
            Write-Host "Name: $($image.ImageName)" -ForegroundColor Green
            Write-Host "Description: $($image.ImageDescription)" -ForegroundColor Gray
            Write-Host "Size: $([math]::Round($image.ImageSize / 1GB, 2)) GB" -ForegroundColor Yellow
            Write-Host "-" * 30
        }
        
        Write-Host "`nFor autounattend.xml, use one of these options:" -ForegroundColor Cyan
        Write-Host "Option 1 - By Index (recommended):" -ForegroundColor White
        foreach ($image in $images) {
            Write-Host "  <Key>/IMAGE/INDEX</Key>" -ForegroundColor Gray
            Write-Host "  <Value>$($image.ImageIndex)</Value>" -ForegroundColor Gray
            Write-Host "  <!-- $($image.ImageName) -->" -ForegroundColor Green
            Write-Host ""
        }
        
        Write-Host "Option 2 - By Name:" -ForegroundColor White
        foreach ($image in $images) {
            Write-Host "  <Key>/IMAGE/NAME</Key>" -ForegroundColor Gray
            Write-Host "  <Value>$($image.ImageName)</Value>" -ForegroundColor Gray
            Write-Host ""
        }
        
        # Recommend the Datacenter (Desktop Experience) edition
        $recommendedEdition = $images | Where-Object { $_.ImageName -like "*Datacenter*Desktop*" }
        if ($recommendedEdition) {
            Write-Host "RECOMMENDED for your setup:" -ForegroundColor Yellow
            Write-Host "Index: $($recommendedEdition.ImageIndex) - $($recommendedEdition.ImageName)" -ForegroundColor Green
        }
        
    }
    else {
        Write-Error "Could not find install.wim or install.esd in the ISO"
    }
    
}
catch {
    Write-Error "Failed to analyze ISO: $($_.Exception.Message)"
}
finally {
    # Dismount the ISO
    if ($mount) {
        Dismount-DiskImage -ImagePath $IsoPath
    }
}