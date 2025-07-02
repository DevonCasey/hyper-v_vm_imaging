#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Debug script to monitor Packer build and connect to VM console

.DESCRIPTION
    This script helps debug Packer build issues by:
    1. Starting a Packer build
    2. Connecting to the VM console via Hyper-V Manager
    3. Monitoring the build process

.NOTES
    Author: Devon Casey
    Email: me@devoncasey.com
    GitHub: https://github.com/DevonCasey
    Created: July 1, 2025
#>

param(
    [switch]$ConnectConsole,
    [switch]$MonitorOnly
)

# Colors for output
function Write-DebugInfo($Message) { Write-Host "🔍 $Message" -ForegroundColor Cyan }
function Write-DebugSuccess($Message) { Write-Host "✅ $Message" -ForegroundColor Green }
function Write-DebugWarning($Message) { Write-Host "⚠️ $Message" -ForegroundColor Yellow }
function Write-DebugError($Message) { Write-Host "❌ $Message" -ForegroundColor Red }

Write-Host "=== Packer Build Debugger ===" -ForegroundColor Yellow

if ($MonitorOnly) {
    Write-DebugInfo "Monitoring existing VMs..."
    
    # Check for existing Packer VMs
    $packerVMs = Get-VM | Where-Object { $_.Name -like "*packer*" -or $_.Name -like "*windows-server*" }
    
    if ($packerVMs) {
        Write-DebugSuccess "Found Packer VMs:"
        $packerVMs | ForEach-Object {
            Write-Host "  - $($_.Name) (State: $($_.State))" -ForegroundColor White
        }
        
        if ($ConnectConsole) {
            $vm = $packerVMs | Select-Object -First 1
            Write-DebugInfo "Connecting to VM console: $($vm.Name)"
            vmconnect.exe localhost $vm.Name
        }
    } else {
        Write-DebugWarning "No Packer VMs found"
    }
    
    exit 0
}

# Full debug process
Write-DebugInfo "Starting Packer build debug process..."

# Check if another Packer process is running
$existingPacker = Get-Process -Name "packer" -ErrorAction SilentlyContinue
if ($existingPacker) {
    Write-DebugWarning "Existing Packer process found (PID: $($existingPacker.Id)). Kill it first if needed."
}

# Clean up any existing VMs
Write-DebugInfo "Cleaning up existing Packer VMs..."
Get-VM | Where-Object { $_.Name -like "*packer*" } | ForEach-Object {
    Write-DebugWarning "Removing existing VM: $($_.Name)"
    if ($_.State -eq "Running") {
        Stop-VM -Name $_.Name -Force -ErrorAction SilentlyContinue
    }
    Remove-VM -Name $_.Name -Force -ErrorAction SilentlyContinue
}

# Start the build
Write-DebugInfo "Starting Packer build..."
$packerDir = "C:\Users\dcasey.AS-ADMVMH61\Programming\hyper-v_vm_imaging\packer"
$customIso = "E:\packer\custom_windows_server_2025.iso"

if (-not (Test-Path $customIso)) {
    Write-DebugError "Custom ISO not found: $customIso"
    Write-DebugInfo "Run the ISO creation first: .\Build-GoldenImage.ps1 -CreateIsoOnly -PatchNoPrompt"
    exit 1
}

Write-DebugSuccess "Custom ISO found: $customIso"

# Start Packer build in background
$packerJob = Start-Job -ScriptBlock {
    param($PackerDir, $CustomIso)
    cd $PackerDir
    & packer build -var "iso_url=$CustomIso" windows-server-2025.pkr.hcl
} -ArgumentList $packerDir, $customIso

Write-DebugInfo "Packer build started (Job ID: $($packerJob.Id))"
Write-DebugInfo "Waiting for VM to be created..."

# Wait for VM to appear
$timeout = 300  # 5 minutes
$elapsed = 0
$vmFound = $false

while ($elapsed -lt $timeout -and -not $vmFound) {
    Start-Sleep -Seconds 5
    $elapsed += 5
    
    $packerVMs = Get-VM | Where-Object { $_.Name -like "*packer*" -or $_.Name -like "*windows-server*" }
    if ($packerVMs) {
        $vmFound = $true
        $vm = $packerVMs | Select-Object -First 1
        Write-DebugSuccess "VM created: $($vm.Name)"
        
        if ($ConnectConsole) {
            Write-DebugInfo "Connecting to VM console..."
            Start-Process "vmconnect.exe" -ArgumentList "localhost", $vm.Name
        }
        
        Write-DebugInfo "VM State: $($vm.State)"
        Write-DebugInfo "Monitoring build progress..."
        
        # Monitor the job
        while ($packerJob.State -eq "Running") {
            $vm = Get-VM -Name $vm.Name -ErrorAction SilentlyContinue
            if ($vm) {
                Write-Host "$(Get-Date -Format 'HH:mm:ss') - VM State: $($vm.State)" -ForegroundColor Gray
            }
            Start-Sleep -Seconds 30
        }
        
        break
    }
    
    Write-Host "." -NoNewline -ForegroundColor Gray
}

if (-not $vmFound) {
    Write-DebugError "VM was not created within $timeout seconds"
    Write-DebugInfo "Check Packer logs for errors"
}

# Get job results
Write-DebugInfo "Getting Packer build results..."
$result = Receive-Job -Job $packerJob
Write-Host $result

if ($packerJob.State -eq "Failed") {
    Write-DebugError "Packer build failed"
} else {
    Write-DebugSuccess "Packer build completed"
}

Remove-Job -Job $packerJob
