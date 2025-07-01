<#
.SYNOPSIS
    Enhanced Weekly Golden Image Build Script for Windows Server 2025

.DESCRIPTION
    Automates the creation of Windows Server 2025 golden images using Packer and Vagrant.
    Enhanced with improved error handling, progress reporting, and modular design.

.PARAMETER BoxName
    Name of the Vagrant box to create (uses config default if not specified)

.PARAMETER IsoPath
    Path to the Windows Server 2025 ISO file (auto-detected if not specified)

.PARAMETER ConfigPath
    Path to custom configuration file (JSON format)

.PARAMETER Force
    Force rebuild even if the image is recent

.PARAMETER ScheduleWeekly
    Create a Windows scheduled task for weekly builds

.PARAMETER CheckOnly
    Only check if rebuild is needed (returns exit code)

.PARAMETER DaysBeforeRebuild
    Number of days before forcing a rebuild (uses config default if not specified)

.PARAMETER Interactive
    Enable interactive mode with menus and prompts

.EXAMPLE
    .\Build-WeeklyGoldenImage.ps1
    Build with default settings (auto-detect ISO, use config defaults)

.EXAMPLE
    .\Build-WeeklyGoldenImage.ps1 -Force -Interactive
    Force rebuild with interactive prompts

.EXAMPLE
    .\Build-WeeklyGoldenImage.ps1 -ConfigPath ".\custom-config.json"
    Use custom configuration file

.EXAMPLE
    .\Build-WeeklyGoldenImage.ps1 -CheckOnly
    Check if rebuild is needed without building

.NOTES
    Version: 2.0.0
    Requires: PowerShell 5.1+, Packer, Vagrant, Hyper-V, Windows ADK
#>

[CmdletBinding(DefaultParameterSetName = 'Build')]
param(
    [Parameter(ParameterSetName = 'Build')]
    [Parameter(ParameterSetName = 'Check')]
    [string]$BoxName,
    
    [Parameter(ParameterSetName = 'Build')]
    [ValidateScript({
            if (-not $_ -or (Test-Path $_ -PathType Leaf)) { $true }
            else { throw "ISO file not found: $_" }
        })]
    [string]$IsoPath,
    
    [Parameter(ParameterSetName = 'Build')]
    [Parameter(ParameterSetName = 'Check')]
    [ValidateScript({
            if (-not $_ -or (Test-Path $_ -PathType Leaf)) { $true }
            else { throw "Configuration file not found: $_" }
        })]
    [string]$ConfigPath,
    
    [Parameter(ParameterSetName = 'Build')]
    [switch]$Force,
    
    [Parameter(ParameterSetName = 'Schedule')]
    [switch]$ScheduleWeekly,
    
    [Parameter(ParameterSetName = 'Check')]
    [switch]$CheckOnly,
    
    [Parameter(ParameterSetName = 'Build')]
    [Parameter(ParameterSetName = 'Check')]
    [ValidateRange(1, 30)]
    [int]$DaysBeforeRebuild,
    
    [Parameter(ParameterSetName = 'Build')]
    [switch]$Interactive
)

#region Module Imports
# Import core functions
$coreModulePath = Join-Path $PSScriptRoot "core\Common.psm1"
if (Test-Path $coreModulePath) {
    Import-Module $coreModulePath
}
else {
    throw "Core module not found: $coreModulePath. Please ensure the project structure is intact."
}
#endregion

#region Script Variables
$script:effectiveBoxName = $null
$script:effectiveIsoPath = $null
$script:effectiveDaysBeforeRebuild = $null
#endregion

#region Interactive Functions
function Show-InteractiveMenu {
    <#
    .SYNOPSIS
        Shows interactive menu for build options
    #>
    [CmdletBinding()]
    param()
    
    Clear-Host
    Write-Host "=" * 70 -ForegroundColor Green
    Write-Host "   Windows Server 2025 Golden Image Builder v2.0" -ForegroundColor Green
    Write-Host "=" * 70 -ForegroundColor Green
    Write-Host ""
    
    $currentBox = Get-CurrentBoxInfo -BoxName $script:effectiveBoxName
    
    # Display current status
    Write-Host "Current Configuration:" -ForegroundColor Yellow
    Write-Host "  Box Name: $script:effectiveBoxName" -ForegroundColor White
    Write-Host "  ISO Path: $script:effectiveIsoPath" -ForegroundColor White
    Write-Host "  Rebuild Interval: $script:effectiveDaysBeforeRebuild days" -ForegroundColor White
    
    if ($currentBox.Exists) {
        $ageColor = if ($currentBox.NeedsRebuild) { "Red" } else { "Green" }
        Write-Host "  Current Box Age: $($currentBox.AgeDays) days" -ForegroundColor $ageColor
        Write-Host "  Rebuild Required: $($currentBox.NeedsRebuild)" -ForegroundColor $ageColor
    }
    else {
        Write-Host "  Current Box: Not Found" -ForegroundColor Red
    }
    
    Write-Host ""
    Write-Host "Available Actions:" -ForegroundColor Yellow
    Write-Host "  1. Build Golden Image Now" -ForegroundColor White
    Write-Host "  2. Force Rebuild (ignore age)" -ForegroundColor White
    Write-Host "  3. Check Build Status Only" -ForegroundColor White
    Write-Host "  4. Schedule Weekly Builds" -ForegroundColor White
    Write-Host "  5. Configure Settings" -ForegroundColor White
    Write-Host "  6. View System Information" -ForegroundColor White
    Write-Host "  Q. Quit" -ForegroundColor White
    Write-Host ""
    
    do {
        $choice = Read-Host "Select an option (1-6, Q)"
        
        switch ($choice.ToUpper()) {
            "1" { return "build" }
            "2" { 
                $script:Force = $true
                return "build"
            }
            "3" { return "check" }
            "4" { return "schedule" }
            "5" { 
                Show-ConfigurationMenu
                Show-InteractiveMenu
                return
            }
            "6" { 
                Show-SystemInformation
                Read-Host "`nPress Enter to continue"
                Show-InteractiveMenu
                return
            }
            "Q" { return "quit" }
            default { 
                Write-Host "Invalid selection. Please choose 1-6 or Q." -ForegroundColor Red
            }
        }
    } while ($true)
}

function Show-ConfigurationMenu {
    <#
    .SYNOPSIS
        Shows configuration options menu
    #>
    [CmdletBinding()]
    param()
    
    Clear-Host
    Write-Host "=" * 70 -ForegroundColor Cyan
    Write-Host "   Configuration Settings" -ForegroundColor Cyan
    Write-Host "=" * 70 -ForegroundColor Cyan
    Write-Host ""
    
    Write-Host "Current Settings:" -ForegroundColor Yellow
    Write-Host "  1. Box Name: $script:effectiveBoxName" -ForegroundColor White
    Write-Host "  2. ISO Path: $script:effectiveIsoPath" -ForegroundColor White
    Write-Host "  3. Rebuild Interval: $script:effectiveDaysBeforeRebuild days" -ForegroundColor White
    Write-Host ""
    Write-Host "  R. Reset to Defaults" -ForegroundColor White
    Write-Host "  B. Back to Main Menu" -ForegroundColor White
    Write-Host ""
    
    do {
        $choice = Read-Host "Select setting to change (1-3, R, B)"
        
        switch ($choice.ToUpper()) {
            "1" {
                $newBoxName = Read-Host "Enter new box name [$script:effectiveBoxName]"
                if ($newBoxName) {
                    $script:effectiveBoxName = Get-SafeVMName -Name $newBoxName
                    Write-Host "Box name updated to: $script:effectiveBoxName" -ForegroundColor Green
                }
                break
            }
            "2" {
                $newIsoPath = Read-Host "Enter new ISO path [$script:effectiveIsoPath]"
                if ($newIsoPath -and (Test-Path $newIsoPath)) {
                    $script:effectiveIsoPath = $newIsoPath
                    Write-Host "ISO path updated to: $script:effectiveIsoPath" -ForegroundColor Green
                }
                elseif ($newIsoPath) {
                    Write-Host "ISO file not found: $newIsoPath" -ForegroundColor Red
                }
                break
            }
            "3" {
                $newDays = Read-Host "Enter rebuild interval in days (1-30) [$script:effectiveDaysBeforeRebuild]"
                if ($newDays -and $newDays -match '^\d+$' -and [int]$newDays -ge 1 -and [int]$newDays -le 30) {
                    $script:effectiveDaysBeforeRebuild = [int]$newDays
                    Write-Host "Rebuild interval updated to: $script:effectiveDaysBeforeRebuild days" -ForegroundColor Green
                }
                elseif ($newDays) {
                    Write-Host "Invalid input. Please enter a number between 1 and 30." -ForegroundColor Red
                }
                break
            }
            "R" {
                Reset-ToDefaults
                Write-Host "Settings reset to defaults" -ForegroundColor Green
                break
            }
            "B" {
                return
            }
            default {
                Write-Host "Invalid selection. Please choose 1-3, R, or B." -ForegroundColor Red
            }
        }
        
        if ($choice.ToUpper() -ne "B") {
            Start-Sleep -Seconds 1
        }
    } while ($choice.ToUpper() -ne "B")
}

function Show-SystemInformation {
    <#
    .SYNOPSIS
        Displays system information and environment status
    #>
    [CmdletBinding()]
    param()
    
    Clear-Host
    Write-Host "=" * 70 -ForegroundColor Magenta
    Write-Host "   System Information" -ForegroundColor Magenta
    Write-Host "=" * 70 -ForegroundColor Magenta
    Write-Host ""
    
    try {
        # System basics
        $os = Get-CimInstance Win32_OperatingSystem
        $computer = Get-CimInstance Win32_ComputerSystem
        
        Write-Host "System Information:" -ForegroundColor Yellow
        Write-Host "  Computer: $($computer.Name)" -ForegroundColor White
        Write-Host "  OS: $($os.Caption)" -ForegroundColor White
        Write-Host "  Version: $($os.Version)" -ForegroundColor White
        Write-Host "  Memory: $([math]::Round($computer.TotalPhysicalMemory / 1GB, 1)) GB" -ForegroundColor White
        Write-Host ""
        
        # Check prerequisites
        Write-Host "Tool Availability:" -ForegroundColor Yellow
        $tools = @(
            @{ Name = "Packer"; Command = "packer version" },
            @{ Name = "Vagrant"; Command = "vagrant --version" },
            @{ Name = "Hyper-V"; Test = {
                    $feature = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All
                    $feature.State -eq 'Enabled'
                } 
            }
        )
        
        foreach ($tool in $tools) {
            try {
                if ($tool.Command) {
                    $version = Invoke-Expression $tool.Command 2>$null
                    Write-Host "  ✓ $($tool.Name): $version" -ForegroundColor Green
                }
                elseif ($tool.Test) {
                    $result = & $tool.Test
                    if ($result) {
                        Write-Host "  ✓ $($tool.Name): Enabled" -ForegroundColor Green
                    }
                    else {
                        Write-Host "  ✗ $($tool.Name): Not Available" -ForegroundColor Red
                    }
                }
            }
            catch {
                Write-Host "  ✗ $($tool.Name): Not Available" -ForegroundColor Red
            }
        }
        
        Write-Host ""
        
        # Check for virtual switches
        Write-Host "Hyper-V Virtual Switches:" -ForegroundColor Yellow
        try {
            $switches = Get-VMSwitch -ErrorAction SilentlyContinue
            if ($switches) {
                foreach ($switch in $switches) {
                    Write-Host "  • $($switch.Name) ($($switch.SwitchType))" -ForegroundColor White
                }
            }
            else {
                Write-Host "  No virtual switches found" -ForegroundColor Red
            }
        }
        catch {
            Write-Host "  Unable to query virtual switches" -ForegroundColor Red
        }
        
        Write-Host ""
        
        # Check existing Vagrant boxes
        Write-Host "Vagrant Boxes:" -ForegroundColor Yellow
        try {
            $boxes = & vagrant box list 2>$null
            if ($boxes) {
                foreach ($box in $boxes) {
                    Write-Host "  • $box" -ForegroundColor White
                }
            }
            else {
                Write-Host "  No Vagrant boxes found" -ForegroundColor Gray
            }
        }
        catch {
            Write-Host "  Unable to query Vagrant boxes" -ForegroundColor Red
        }
        
    }
    catch {
        Write-Host "Error retrieving system information: $($_.Exception.Message)" -ForegroundColor Red
    }
}
#endregion

#region Build Functions
function Get-CurrentBoxInfo {
    <#
    .SYNOPSIS
        Gets information about the current golden image box
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$BoxName
    )
    
    try {
        $boxInfo = & vagrant box list 2>$null | Where-Object { $_ -like "*$BoxName*" }
        
        if (-not $boxInfo) {
            return @{
                Exists       = $false
                AgeDays      = $null
                NeedsRebuild = $true
            }
        }
        
        # Check box directory timestamp
        $boxPath = Join-Path $env:USERPROFILE ".vagrant.d\boxes"
        $boxDirs = Get-ChildItem $boxPath -Directory -ErrorAction SilentlyContinue | 
        Where-Object { $_.Name -like "*$BoxName*" }
        
        if ($boxDirs) {
            $latestBox = $boxDirs | Sort-Object LastWriteTime -Descending | Select-Object -First 1
            $ageDays = [math]::Floor(((Get-Date) - $latestBox.LastWriteTime).TotalDays)
            $needsRebuild = $ageDays -ge $script:effectiveDaysBeforeRebuild
            
            return @{
                Exists       = $true
                AgeDays      = $ageDays
                NeedsRebuild = $needsRebuild
                LastModified = $latestBox.LastWriteTime
            }
        }
        
        return @{
            Exists       = $true
            AgeDays      = $null
            NeedsRebuild = $true
        }
    }
    catch {
        Write-Warning "Could not determine box information: $($_.Exception.Message)"
        return @{
            Exists       = $false
            AgeDays      = $null
            NeedsRebuild = $true
        }
    }
}

function Reset-ToDefaults {
    <#
    .SYNOPSIS
        Resets parameters to configuration defaults
    #>
    [CmdletBinding()]
    param()
    
    $config = Get-WorkflowConfig
    $script:effectiveBoxName = $config.golden_image.box_name
    $script:effectiveDaysBeforeRebuild = $config.golden_image.rebuild_interval_days
    
    # Try to find ISO
    $foundIso = Find-WindowsServerIso
    if ($foundIso -is [string] -and -not [string]::IsNullOrWhiteSpace($foundIso)) {
        $script:effectiveIsoPath = $foundIso
    }
    elseif ($foundIso -is [array]) {
        # God damn Find-WindowsServerIso. If it ever returns an array, pick the first valid string
        $firstString = $foundIso | Where-Object { $_ -is [string] -and -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1
        if ($firstString) {
            $script:effectiveIsoPath = $firstString
        }
    }
}

function New-CustomIso {
    <#
    .SYNOPSIS
        Creates a custom Windows ISO with embedded autounattend.xml
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SourceIsoPath,
        
        [Parameter(Mandatory)]
        [string]$OutputIsoPath,
        
        [Parameter(Mandatory)]
        [string]$UnattendXmlPath
    )
    
    $config = Get-WorkflowConfig
    $tempBase = $config.global.temp_directory
    $workingDir = Join-Path $tempBase "winiso_$(Get-Random)"
    
    try {
        Write-WorkflowProgress -Activity "Creating Custom ISO" -Status "Setting up working directory..." -PercentComplete 10
        
        New-Item -ItemType Directory -Path $workingDir -Force | Out-Null
        
        # Validate source files
        @($SourceIsoPath, $UnattendXmlPath) | ForEach-Object {
            if (-not (Test-Path $_)) {
                throw "Required file not found: $_"
            }
        }
        
        # Mount and copy source ISO
        Write-WorkflowProgress -Activity "Creating Custom ISO" -Status "Mounting source ISO..." -PercentComplete 20
        $mount = Mount-DiskImage -ImagePath $SourceIsoPath -PassThru -ErrorAction Stop
        $driveLetter = ($mount | Get-Volume).DriveLetter + ":"
        $volumeLabel = (Get-Volume -DriveLetter $driveLetter.TrimEnd(':')).FileSystemLabel
        
        if (-not $volumeLabel) { 
            $volumeLabel = "CCSEVAL_X64FRE_EN-US_DV9" 
        }
        
        Write-WorkflowProgress -Activity "Creating Custom ISO" -Status "Copying ISO contents..." -PercentComplete 40
        Copy-Item "$driveLetter\*" $workingDir -Recurse -Force
        Dismount-DiskImage -ImagePath $SourceIsoPath | Out-Null
        
        # Add autounattend.xml to the ROOT of the ISO
        Write-WorkflowProgress -Activity "Creating Custom ISO" -Status "Adding autounattend.xml..." -PercentComplete 60
        $autounattendDestination = Join-Path $workingDir "autounattend.xml"
        Copy-Item $UnattendXmlPath $autounattendDestination -Force
        
        # Try to copy scripts directory
        $scriptsSource = Join-Path (Split-Path $PSScriptRoot -Parent) "packer\scripts"
        if (Test-Path $scriptsSource) {
            $scriptsDestination = Join-Path $workingDir "scripts"
            New-Item -ItemType Directory -Path $scriptsDestination -Force | Out-Null
            Copy-Item "$scriptsSource\*" $scriptsDestination -Recurse -Force
        }
        
        # Create bootable ISO
        Write-WorkflowProgress -Activity "Creating Custom ISO" -Status "Building bootable ISO..." -PercentComplete 80
        $oscdimgPath = Find-OscdimgPath
        if (-not $oscdimgPath) {
            throw "oscdimg.exe not found. Please install Windows ADK."
        }
        
        $etfsboot = Join-Path $workingDir 'boot\etfsboot.com'
        $efiSys = Join-Path $workingDir 'efi\microsoft\boot\efisys.bin'
        
        $oscdimgArgs = @('-m', '-o', '-u2', '-udfver102', "-l$volumeLabel")
        
        # Configure boot options
        if ((Test-Path $etfsboot) -and (Test-Path $efiSys)) {
            $bootdata = "2#p0,e,b$etfsboot#pEF,e,b$efiSys"
            $oscdimgArgs += "-bootdata:$bootdata"
        }
        elseif (Test-Path $etfsboot) {
            $oscdimgArgs += "-b$etfsboot"
        }
        elseif (Test-Path $efiSys) {
            $oscdimgArgs += @('-efi', $efiSys)
        }
        else {
            throw "No boot files found in ISO"
        }
        
        $oscdimgArgs += @($workingDir, $OutputIsoPath)
        
        & $oscdimgPath @oscdimgArgs
        
        if ($LASTEXITCODE -ne 0) {
            throw "oscdimg failed with exit code: $LASTEXITCODE"
        }
        
        Write-WorkflowProgress -Activity "Creating Custom ISO" -Status "Verifying custom ISO..." -PercentComplete 95
        
        # Verify the custom ISO
        $verifyMount = Mount-DiskImage -ImagePath $OutputIsoPath -PassThru
        $verifyDrive = ($verifyMount | Get-Volume).DriveLetter + ":"
        $autounattendExists = Test-Path "$verifyDrive\autounattend.xml"
        Dismount-DiskImage -ImagePath $OutputIsoPath | Out-Null
        
        if (-not $autounattendExists) {
            throw "autounattend.xml not found in custom ISO root after verification"
        }
        
        Write-WorkflowProgress -Activity "Creating Custom ISO" -Status "Complete" -PercentComplete 100
        Write-Information "Custom bootable ISO created successfully: $OutputIsoPath" -InformationAction Continue
        
    }
    finally {
        if (Test-Path $workingDir) {
            Remove-Item $workingDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-PackerBuild {
    <#
    .SYNOPSIS
        Executes Packer build with enhanced error handling
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$CustomIsoPath,
        
        [Parameter(Mandatory)]
        [string]$PackerConfigPath,
        
        [Parameter(Mandatory)]
        [string]$PackerWorkingDir
    )
    
    $originalLocation = Get-Location
    $config = Get-WorkflowConfig
    
    try {
        # Change to packer directory
        Set-Location $PackerWorkingDir
        
        # Clean previous build artifacts
        $outputDir = Join-Path $PackerWorkingDir "output-hyperv-iso"
        if (Test-Path $outputDir) {
            Write-WorkflowProgress -Activity "Packer Build" -Status "Cleaning previous artifacts..." -PercentComplete 5
            Remove-Item $outputDir -Recurse -Force
        }
        
        # Remove any lingering VHDX files
        Get-ChildItem -Path $PackerWorkingDir -Filter "*.vhdx" -Recurse -ErrorAction SilentlyContinue | 
        ForEach-Object {
            Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
        }
        
        # Validate inputs
        @($CustomIsoPath, $PackerConfigPath) | ForEach-Object {
            if (-not (Test-Path $_)) {
                throw "Required file not found: $_"
            }
        }
        
        $buildStartTime = Get-Date
        Write-WorkflowProgress -Activity "Packer Build" -Status "Starting build (estimated 30-60 minutes)..." -PercentComplete 10
        
        # Build with custom ISO
        $configFileName = Split-Path $PackerConfigPath -Leaf
        $packerArgs = @(
            'build', 
            '-var', "iso_url=$CustomIsoPath",
            $configFileName
        )
        
        # Execute packer with logging
        $env:PACKER_LOG = "1"
        $packerLogPath = Join-Path $PackerWorkingDir "packer-build.log"
        $env:PACKER_LOG_PATH = $packerLogPath
        
        Write-Information "Executing: packer $($packerArgs -join ' ')" -InformationAction Continue
        
        & packer @packerArgs
        
        if ($LASTEXITCODE -ne 0) {
            $errorDetails = ""
            if (Test-Path $packerLogPath) {
                $errorDetails = Get-Content $packerLogPath | Select-Object -Last 20 | Out-String
            }
            throw "Packer build failed with exit code: $LASTEXITCODE`n$errorDetails"
        }
        
        $buildDuration = (Get-Date) - $buildStartTime
        Write-Information "Packer build completed in $($buildDuration.ToString('hh\:mm\:ss'))" -InformationAction Continue
        
        # Verify output
        if (-not (Test-Path $outputDir)) {
            throw "Packer output directory not found: $outputDir"
        }
        
        $vhdxFiles = Get-ChildItem $outputDir -Filter "*.vhdx" -Recurse
        if ($vhdxFiles.Count -eq 0) {
            throw "No VHDX files found in Packer output directory"
        }
        
        return $buildDuration
    }
    finally {
        Set-Location $originalLocation
        $env:PACKER_LOG = $null
        $env:PACKER_LOG_PATH = $null
    }
}

function New-VagrantBoxFromPacker {
    <#
    .SYNOPSIS
        Creates a Vagrant box from Packer output
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$BoxName,
        
        [Parameter(Mandatory)]
        [string]$PackerOutputDirectory,
        
        [Parameter(Mandatory)]
        [string]$VagrantBoxDirectory
    )
    
    Write-WorkflowProgress -Activity "Creating Vagrant Box" -Status "Preparing box packaging..." -PercentComplete 10
    
    # Find VHDX file
    $vhdxPath = Join-Path $PackerOutputDirectory "Virtual Hard Disks\*.vhdx"
    $vhdxFile = Get-ChildItem $vhdxPath -ErrorAction SilentlyContinue | Select-Object -First 1
    
    if (-not $vhdxFile) {
        throw "No VHDX file found in $PackerOutputDirectory"
    }
    
    # Create boxes directory
    if (-not (Test-Path $VagrantBoxDirectory)) {
        New-Item -ItemType Directory -Path $VagrantBoxDirectory -Force | Out-Null
    }
    
    # Create temporary directory for box packaging
    $config = Get-WorkflowConfig
    $tempBase = $config.global.temp_directory
    $tempDirectory = Join-Path $tempBase "vagrant-box-$BoxName-$(Get-Random)"
    
    try {
        New-Item -ItemType Directory -Path $tempDirectory -Force | Out-Null
        
        Write-WorkflowProgress -Activity "Creating Vagrant Box" -Status "Copying VHDX file..." -PercentComplete 30
        
        # Copy VHDX with safe naming
        $safeVMName = Get-SafeVMName -Name $BoxName
        $boxVhdx = Join-Path $tempDirectory "${safeVMName}_os.vhdx"
        Copy-Item $vhdxFile.FullName $boxVhdx
        
        Write-WorkflowProgress -Activity "Creating Vagrant Box" -Status "Creating box metadata..." -PercentComplete 50
        
        # Create Vagrantfile for Windows box
        $boxVagrantfile = @"
Vagrant.configure("2") do |config|
  config.vm.guest = :windows
  config.vm.communicator = "winrm"
  config.winrm.username = "vagrant"
  config.winrm.password = "vagrant"
  config.winrm.transport = :plaintext
  config.winrm.basic_auth_only = true
  
  config.vm.provider "hyperv" do |hv|
    hv.enable_virtualization_extensions = false
    hv.linked_clone = false
    hv.enable_secure_boot = false
  end
end
"@
        
        Set-Content -Path (Join-Path $tempDirectory "Vagrantfile") -Value $boxVagrantfile
        
        # Create metadata.json
        $metadata = @{
            provider  = "hyperv"
            format    = "vhdx"
            vm_name   = $safeVMName
            vhdx_file = "${safeVMName}_os.vhdx"
        } | ConvertTo-Json
        
        Set-Content -Path (Join-Path $tempDirectory "metadata.json") -Value $metadata
        
        Write-WorkflowProgress -Activity "Creating Vagrant Box" -Status "Packaging box file..." -PercentComplete 70
        
        # Package the box
        $boxFile = Join-Path $VagrantBoxDirectory "$BoxName.box"
        Set-Location $tempDirectory
        
        # Use tar if available, otherwise PowerShell compression
        if (Get-Command tar -ErrorAction SilentlyContinue) {
            & tar -czf $boxFile *
        }
        else {
            Compress-Archive -Path "$tempDirectory\*" -DestinationPath "$boxFile.zip"
            Move-Item "$boxFile.zip" $boxFile
        }
        
        Write-WorkflowProgress -Activity "Creating Vagrant Box" -Status "Adding box to Vagrant..." -PercentComplete 90
        
        # Add box to Vagrant
        & vagrant box add $BoxName $boxFile --force
        
        Write-WorkflowProgress -Activity "Creating Vagrant Box" -Status "Complete" -PercentComplete 100
        Write-Information "Box '$BoxName' created and added to Vagrant successfully" -InformationAction Continue
        
    }
    finally {
        Set-Location $PSScriptRoot
        if (Test-Path $tempDirectory) {
            Remove-Item $tempDirectory -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-GoldenImageBuild {
    <#
    .SYNOPSIS
        Main function to build the golden image
    #>
    [CmdletBinding()]
    param()
    
    try {
        Write-Host ("=" * 70) -ForegroundColor Green
        Write-Host "Starting Golden Image Build Process" -ForegroundColor Green
        Write-Host ("=" * 70) -ForegroundColor Green
        Write-Host ""
        
        Write-Host "Configuration:" -ForegroundColor Yellow
        Write-Host "  Box Name: $script:effectiveBoxName" -ForegroundColor White
        Write-Host "  ISO Path: $script:effectiveIsoPath" -ForegroundColor White
        Write-Host "  Force Rebuild: $Force" -ForegroundColor White
        Write-Host "  Started: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor White
        Write-Host ""
        
        $buildStartTime = Get-Date
        
        # Validate environment
        Write-WorkflowProgress -Activity "Golden Image Build" -Status "Validating environment..." -PercentComplete 5
        Test-Prerequisites
        Test-HyperVEnvironment
        
        # Validate ISO
        Write-WorkflowProgress -Activity "Golden Image Build" -Status "Validating ISO file..." -PercentComplete 10
        if ([string]::IsNullOrWhiteSpace($script:effectiveIsoPath) -or -not (Test-Path $script:effectiveIsoPath)) {
            throw "effectiveIsoPath is not a valid string path: $($script:effectiveIsoPath)"
        }

        Test-IsoFile -Path $script:effectiveIsoPath
        
        # Check if rebuild is needed
        if (-not $Force) {
            Write-WorkflowProgress -Activity "Golden Image Build" -Status "Checking if rebuild is needed..." -PercentComplete 15
            $boxInfo = Get-CurrentBoxInfo -BoxName $script:effectiveBoxName
            
            if ($boxInfo.Exists -and -not $boxInfo.NeedsRebuild) {
                Write-Host "`nGolden image is still fresh (age: $($boxInfo.AgeDays) days)." -ForegroundColor Green
                Write-Host "Use -Force to rebuild anyway." -ForegroundColor Yellow
                return
            }
        }
        
        # Get project paths
        $config = Get-WorkflowConfig
        $projectRoot = Split-Path $PSScriptRoot -Parent
        $packerDir = Join-Path $projectRoot "packer"
        $boxesDir = Join-Path $projectRoot $config.global.boxes_directory
        
        # Ensure directories exist
        @($boxesDir) | ForEach-Object {
            if (-not (Test-Path $_)) {
                $null = New-Item -ItemType Directory -Path $_ -Force
            }
        }
        
        # Prepare file paths
        $unattendXmlPath = Join-Path $packerDir "autounattend.xml"
        $packerConfigPath = Join-Path $packerDir "windows-server-2025.pkr.hcl"
        $customIsoPath = Join-Path $packerDir "custom_windows_server_2025.iso"
        
        # Validate required files exist
        @($unattendXmlPath, $packerConfigPath) | ForEach-Object {
            if (-not (Test-Path $_)) {
                throw "Required file not found: $_"
            }
        }
        
        # Remove existing custom ISO
        if (Test-Path $customIsoPath) {
            Write-WorkflowProgress -Activity "Golden Image Build" -Status "Cleaning previous build artifacts..." -PercentComplete 20
            Remove-Item $customIsoPath -Force
        }
        
        # Create custom ISO with autounattend.xml
        Write-WorkflowProgress -Activity "Golden Image Build" -Status "Creating custom Windows ISO..." -PercentComplete 25
        New-CustomIso -SourceIsoPath $script:effectiveIsoPath -OutputIsoPath $customIsoPath -UnattendXmlPath $unattendXmlPath
        
        # Execute Packer build
        Write-WorkflowProgress -Activity "Golden Image Build" -Status "Starting Packer build (this may take 30-60 minutes)..." -PercentComplete 30
        $buildDuration = Invoke-PackerBuild -CustomIsoPath $customIsoPath -PackerConfigPath $packerConfigPath -PackerWorkingDir $packerDir
        
        # Package as Vagrant box
        Write-WorkflowProgress -Activity "Golden Image Build" -Status "Packaging as Vagrant box..." -PercentComplete 85
        $packerOutputDir = Join-Path $packerDir "output-hyperv-iso"
        
        if ($Force) {
            try {
                & vagrant box remove $script:effectiveBoxName --provider hyperv --force 2>$null
                Write-Information "Removed existing box: $script:effectiveBoxName" -InformationAction Continue
            }
            catch {
                Write-Verbose "No existing box to remove"
            }
        }
        
        New-VagrantBoxFromPacker -BoxName $script:effectiveBoxName -PackerOutputDirectory $packerOutputDir -VagrantBoxDirectory $boxesDir
        
        # Cleanup
        Write-WorkflowProgress -Activity "Golden Image Build" -Status "Cleaning up temporary files..." -PercentComplete 95
        if (Test-Path $customIsoPath) {
            Remove-Item $customIsoPath -Force -ErrorAction SilentlyContinue
        }
        
        # Final summary
        Write-Progress -Activity "Golden Image Build" -Completed
        $totalDuration = (Get-Date) - $buildStartTime
        $nextBuildDate = (Get-Date).AddDays($script:effectiveDaysBeforeRebuild)
        
        Write-Host ("=" * 70) -ForegroundColor Green
        Write-Host "Golden Image Build Complete!" -ForegroundColor Green
        Write-Host ("=" * 70) -ForegroundColor Green
        Write-Host ""
        Write-Host "Build Summary:" -ForegroundColor Yellow
        Write-Host "  Total time: $($totalDuration.ToString('hh\:mm\:ss'))" -ForegroundColor White
        Write-Host "  Box name: $script:effectiveBoxName" -ForegroundColor White
        Write-Host "  Built on: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor White
        Write-Host "  Next build needed after: $($nextBuildDate.ToString('yyyy-MM-dd'))" -ForegroundColor White
        Write-Host ""
        
        # Show deployment options
        Show-DeploymentInstructions
        
    }
    catch {
        Write-Progress -Activity "Golden Image Build" -Completed
        Write-Host ("=" * 70) -ForegroundColor Red
        Write-Host "Golden Image Build Failed!" -ForegroundColor Red
        Write-Host ("=" * 70) -ForegroundColor Red
        Write-Host ""
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host ""
        Write-Host "Check the log file for detailed error information." -ForegroundColor Yellow
        throw
    }
}

function Show-DeploymentInstructions {
    <#
    .SYNOPSIS
        Shows instructions for deploying VMs with the new golden image
    #>
    [CmdletBinding()]
    param()
    
    $config = Get-WorkflowConfig
    $projectRoot = Split-Path $PSScriptRoot -Parent
    $vagrantDir = Join-Path $projectRoot "vagrant"
    
    Write-Host "Deployment Instructions:" -ForegroundColor Yellow
    Write-Host "You can now deploy VMs using the new golden image:" -ForegroundColor White
    Write-Host ""
    
    foreach ($env in $config.environments.PSObject.Properties) {
        $envConfig = $env.Value
        $envPath = Join-Path $vagrantDir $env.Name
        Write-Host "  $($env.Name.ToUpper()) ($($envConfig.description)):" -ForegroundColor Cyan
        Write-Host "    Set-Location '$envPath'" -ForegroundColor Gray
        Write-Host "    vagrant up --provider=hyperv" -ForegroundColor Gray
        Write-Host ""
    }
    
    # Check for running VMs
    Write-Host "Checking for running VMs that may need updates..." -ForegroundColor Yellow
    try {
        $runningVMs = Get-RunningVagrantVMs -VagrantBaseDir $vagrantDir
        if ($runningVMs.Count -gt 0) {
            Write-Host "`nWARNING: The following VMs are running with the old golden image:" -ForegroundColor Yellow
            $runningVMs | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
            Write-Host "`nTo update them with the new golden image:" -ForegroundColor Yellow
            $runningVMs | ForEach-Object {
                $envPath = Join-Path $vagrantDir $_
                Write-Host "  Set-Location '$envPath'; vagrant destroy -f; vagrant up --provider=hyperv" -ForegroundColor Gray
            }
        }
        else {
            Write-Host "[OK] No running VMs detected - all future VMs will use the new golden image" -ForegroundColor Green
        }
    }
    catch {
        Write-Warning "Could not check for running VMs: $($_.Exception.Message)"
    }
}

function Get-RunningVagrantVMs {
    <#
    .SYNOPSIS
        Gets list of running Vagrant VMs
    #>
    [CmdletBinding()]
    param(
        [string]$VagrantBaseDir
    )
    
    if (-not $VagrantBaseDir) {
        $projectRoot = Split-Path $PSScriptRoot -Parent
        $VagrantBaseDir = Join-Path $projectRoot "vagrant"
    }
    
    $config = Get-WorkflowConfig
    $environments = $config.environments.PSObject.Properties.Name
    $runningVMs = @()
    $originalLocation = Get-Location
    
    try {
        foreach ($env in $environments) {
            $envPath = Join-Path $VagrantBaseDir $env
            
            if (Test-Path $envPath) {
                try {
                    Set-Location $envPath
                    $status = & vagrant status 2>$null
                    
                    if ($status -and ($status -match "running")) {
                        $runningVMs += $env
                    }
                }
                catch {
                    Write-Verbose "Could not check status for environment: $env"
                }
            }
        }
    }
    finally {
        Set-Location $originalLocation
    }
    
    return $runningVMs
}

function Invoke-BuildCheck {
    <#
    .SYNOPSIS
        Checks if a build is needed
    #>
    [CmdletBinding()]
    param()
    
    try {
        $boxInfo = Get-CurrentBoxInfo -BoxName $script:effectiveBoxName
        
        Write-Host "`nGolden Image Status:" -ForegroundColor Cyan
        Write-Host "Box: $script:effectiveBoxName" -ForegroundColor White
        
        if ($boxInfo.Exists) {
            Write-Host "Age: $($boxInfo.AgeDays) days" -ForegroundColor White
            Write-Host "Last Modified: $($boxInfo.LastModified)" -ForegroundColor White
            Write-Host "Rebuild Needed: $($boxInfo.NeedsRebuild)" -ForegroundColor $(if ($boxInfo.NeedsRebuild) { "Yellow" } else { "Green" })
        }
        else {
            Write-Host "Status: Not Found" -ForegroundColor Red
            Write-Host "Rebuild Needed: Yes" -ForegroundColor Yellow
        }
        
        exit $(if ($boxInfo.NeedsRebuild) { 1 } else { 0 })
    }
    catch {
        Write-Error "Failed to check build status: $($_.Exception.Message)"
        exit 2
    }
}

function New-WeeklyScheduledTask {
    <#
    .SYNOPSIS
        Creates a scheduled task for weekly builds
    #>
    [CmdletBinding()]
    param()
    
    $config = Get-WorkflowConfig
    $taskName = $config.golden_image.scheduled_task_name
    $taskDescription = "Weekly Windows Server 2025 Golden Image Build"
    
    try {
        Write-Host "Creating scheduled task for weekly builds..." -ForegroundColor Yellow
        
        # Remove existing task
        $existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if ($existingTask) {
            Write-Host "Removing existing scheduled task..." -ForegroundColor Gray
            $null = Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        }
        
        # Create new task
        $scriptPath = $PSCommandPath
        $action = New-ScheduledTaskAction -Execute "PowerShell.exe" -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`""
        
        $triggerTime = $config.golden_image.scheduled_time
        $triggerDay = $config.golden_image.scheduled_day
        $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $triggerDay -At $triggerTime
        
        $timeoutMinutes = $config.packer.timeout_minutes
        $retryAttempts = $config.packer.retry_attempts
        $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes $timeoutMinutes) -RestartCount $retryAttempts
        
        $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Highest
        
        $null = Register-ScheduledTask -TaskName $taskName -Description $taskDescription -Action $action -Trigger $trigger -Settings $settings -Principal $principal
        
        Write-Host "[OK] Scheduled task '$taskName' created successfully" -ForegroundColor Green
        Write-Host "Task will run every $triggerDay at $triggerTime" -ForegroundColor White
        
        # Show task information
        $task = Get-ScheduledTask -TaskName $taskName
        Write-Host "`nTask Details:" -ForegroundColor Yellow
        Write-Host "  Name: $($task.TaskName)" -ForegroundColor White
        Write-Host "  State: $($task.State)" -ForegroundColor White
        Write-Host "  Next Run: $((Get-ScheduledTask -TaskName $taskName | Get-ScheduledTaskInfo).NextRunTime)" -ForegroundColor White
        
    }
    catch {
        throw "Failed to create scheduled task: $($_.Exception.Message)"
    }
}
#endregion

#region Main Execution
try {
    # Initialize configuration and logging
    Initialize-WorkflowConfiguration -ConfigPath $ConfigPath
    Initialize-WorkflowLogging -ScriptName "Build-WeeklyGoldenImage"
    
    $config = Get-WorkflowConfig
    
    # Set effective parameters from config or parameters
    $script:effectiveBoxName = if ($BoxName) { $BoxName } else { $config.golden_image.box_name }
    $script:effectiveDaysBeforeRebuild = if ($DaysBeforeRebuild) { $DaysBeforeRebuild } else { $config.golden_image.rebuild_interval_days }
    
    # Find ISO path
    if ($PSBoundParameters.ContainsKey('IsoPath')) {
        if ($null -eq $IsoPath -or $IsoPath -isnot [string] -or [string]::IsNullOrWhiteSpace($IsoPath)) {
            throw "You must provide a valid string path for -IsoPath. Example: -IsoPath 'F:\\Install\\Microsoft\\Windows Server\\WinServer_2025.iso'"
        }
        $script:effectiveIsoPath = ConvertTo-AbsolutePath -Path $IsoPath
    }
    else {
        $foundIso = Find-WindowsServerIso
        if ($foundIso -is [string] -and -not [string]::IsNullOrWhiteSpace($foundIso)) {
            $script:effectiveIsoPath = $foundIso
        }
        elseif ($foundIso -is [array]) {
            # Defensive: If Find-WindowsServerIso ever returns an array, pick the first valid string
            $firstString = $foundIso | Where-Object { $_ -is [string] -and -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1
            if ($firstString) {
                $script:effectiveIsoPath = $firstString
            }
            else {
                throw "Windows Server ISO not found. Please specify -IsoPath or place ISO in one of the default locations."
            }
        }
        else {
            throw "Windows Server ISO not found. Please specify -IsoPath or place ISO in one of the default locations."
        }
    }
    
    # Execute based on parameter set
    switch ($PSCmdlet.ParameterSetName) {
        'Schedule' {
            Write-Host "Setting up weekly scheduled task..." -ForegroundColor Yellow
            New-WeeklyScheduledTask
            exit 0
        }
        'Check' {
            Invoke-BuildCheck
        }
        'Build' {
            if ($Interactive) {
                $action = Show-InteractiveMenu
                switch ($action) {
                    "build" { Invoke-GoldenImageBuild }
                    "check" { Invoke-BuildCheck }
                    "schedule" { New-WeeklyScheduledTask }
                    "quit" { 
                        Write-Host "Exiting..." -ForegroundColor Yellow
                        exit 0
                    }
                    default { 
                        Write-Host "Unknown action: $action" -ForegroundColor Red
                        exit 1
                    }
                }
            }
            else {
                Invoke-GoldenImageBuild
            }
        }
    }
}

catch {
    Write-Error $_.Exception.Message
    exit 1
}

finally {
    Stop-WorkflowLogging
}
# Endregion