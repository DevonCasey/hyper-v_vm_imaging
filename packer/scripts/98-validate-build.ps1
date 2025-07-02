# Author: Devon Casey (me@devoncasey.com) - https://github.com/devoncasey
# Purpose: Validate successful build completion and system readiness

Write-Host "=== Build Validation Report ===" -ForegroundColor Green

# System Information
Write-Host "`n--- System Information ---" -ForegroundColor Yellow
Write-Host "Computer Name: $env:COMPUTERNAME"
Write-Host "OS Version: $((Get-WmiObject -Class Win32_OperatingSystem).Caption)"
Write-Host "PowerShell Version: $($PSVersionTable.PSVersion)"
Write-Host "Build Date: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"

# Service Status
Write-Host "`n--- Critical Services ---" -ForegroundColor Yellow
$services = @("WinRM", "RpcSs", "Themes", "UmRdpService")
foreach ($service in $services) {
    $svc = Get-Service -Name $service -ErrorAction SilentlyContinue
    if ($svc) {
        $status = if ($svc.Status -eq "Running") { "✓" } else { "✗" }
        Write-Host "$status $service`: $($svc.Status)" -ForegroundColor $(if ($svc.Status -eq "Running") { "Green" } else { "Red" })
    }
}

# Installed Software
Write-Host "`n--- Installed Software ---" -ForegroundColor Yellow
$software = @()

# Check Chocolatey
if (Get-Command choco -ErrorAction SilentlyContinue) {
    $chocoVersion = choco --version
    $software += "✓ Chocolatey v$chocoVersion"
    
    # Check chocolatey packages
    try {
        $packages = choco list --local-only --limit-output | ForEach-Object { $_.Split('|')[0] }
        if ($packages) {
            $software += "  - Chocolatey packages: $($packages -join ', ')"
        }
    } catch {
        $software += "  - Could not enumerate Chocolatey packages"
    }
} else {
    $software += "✗ Chocolatey not installed"
}

# Check .NET Framework
try {
    $dotNet = Get-ItemProperty "HKLM:SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full\" -ErrorAction SilentlyContinue
    if ($dotNet -and $dotNet.Release -ge 528040) {
        $software += "✓ .NET Framework 4.8"
    } else {
        $software += "✗ .NET Framework 4.8 not detected"
    }
} catch {
    $software += "? .NET Framework status unknown"
}

foreach ($item in $software) {
    Write-Host $item
}

# Network Configuration
Write-Host "`n--- Network Configuration ---" -ForegroundColor Yellow
try {
    $adapters = Get-NetAdapter | Where-Object { $_.Status -eq "Up" }
    foreach ($adapter in $adapters) {
        Write-Host "✓ $($adapter.Name): $($adapter.Status)"
        $ip = Get-NetIPAddress -InterfaceIndex $adapter.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
        if ($ip) {
            Write-Host "  IP: $($ip.IPAddress)"
        }
    }
} catch {
    Write-Host "Could not retrieve network information"
}

# Windows Updates Status
Write-Host "`n--- Windows Updates ---" -ForegroundColor Yellow
try {
    if (Get-Module -ListAvailable -Name PSWindowsUpdate) {
        Write-Host "✓ PSWindowsUpdate module available"
        # Check for pending updates
        $pendingUpdates = Get-WUList -ErrorAction SilentlyContinue
        if ($pendingUpdates) {
            Write-Host "⚠ $($pendingUpdates.Count) pending updates found"
        } else {
            Write-Host "✓ No pending updates"
        }
    } else {
        Write-Host "✗ PSWindowsUpdate module not available"
    }
} catch {
    Write-Host "Could not check Windows Updates status"
}

# Disk Space
Write-Host "`n--- Disk Space ---" -ForegroundColor Yellow
try {
    $drives = Get-WmiObject -Class Win32_LogicalDisk | Where-Object { $_.DriveType -eq 3 }
    foreach ($drive in $drives) {
        $freeGB = [math]::Round($drive.FreeSpace / 1GB, 2)
        $totalGB = [math]::Round($drive.Size / 1GB, 2)
        $percentFree = [math]::Round(($drive.FreeSpace / $drive.Size) * 100, 1)
        Write-Host "Drive $($drive.DeviceID) $freeGB GB free of $totalGB GB ($percentFree% free)"
    }
} catch {
    Write-Host "Could not retrieve disk space information"
}

Write-Host "`n=== Validation Complete ===" -ForegroundColor Green
Write-Host "Image is ready for use!" -ForegroundColor Green
