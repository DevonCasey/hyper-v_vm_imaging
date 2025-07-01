<#
.SYNOPSIS
    Enhanced Weekly Golden Image Build Script for Windows Server 2025

.DESCRIPTION
    Automates the creation of Windows Server 2025 golden images using Packer and Vagrant.
    Enhanced with improved error handling, progress reporting, and modular design.

.PARAMETER BoxName
    Name of the Vagrant box to create (uses config default if not specified)

.PARAMETER IsoPath
    Path to the original Windows Server ISO file. Optional if a custom ISO for the specified WindowsVersion already exists.

.PARAMETER WindowsVersion
    Windows Server version to build (2019 or 2025). Default: 2025. Used to locate existing custom ISOs.

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

.PARAMETER CreateIsoOnly
    Create only the custom Windows Server 2025 ISO with autounattend.xml and exit

.PARAMETER PatchNoPrompt
    Apply no-prompt EFI boot file patching to eliminate "press any key" boot prompt

.PARAMETER CheckImageIndexes
    Check and display available Windows image indexes in the specified ISO file and exit

.EXAMPLE
    .\Build-GoldenImage.ps1
    Build with default settings (auto-detect ISO, use config defaults)

.EXAMPLE
    .\Build-GoldenImage.ps1 -Force -Interactive
    Force rebuild with interactive prompts

.EXAMPLE
    .\Build-GoldenImage.ps1 -CreateIsoOnly -IsoPath "C:\ISOs\WinServer_2025.iso"
    Create only the custom ISO with autounattend.xml

.EXAMPLE
    .\Build-GoldenImage.ps1 -CheckImageIndexes -IsoPath "C:\ISOs\WinServer_2025.iso"
    Check and display available Windows image indexes in the ISO

.EXAMPLE
    .\Build-GoldenImage.ps1 -WindowsVersion 2019
    Build Windows Server 2019 using existing custom ISO (if available) or auto-detect original ISO

.EXAMPLE
    .\Build-GoldenImage.ps1 -WindowsVersion 2019 -IsoPath "F:\Install\Microsoft\Windows Server\WinServer_2019.iso"
    Build Windows Server 2019 golden image with specific original ISO

.EXAMPLE
    .\Build-GoldenImage.ps1 -CreateIsoOnly -WindowsVersion 2019 -IsoPath "F:\Install\Microsoft\Windows Server\WinServer_2019.iso"
    Create only the custom Windows Server 2019 ISO

.EXAMPLE
    .\Build-GoldenImage.ps1 -ConfigPath ".\custom-config.json"
    Use custom configuration file

.EXAMPLE
    .\Build-GoldenImage.ps1 -CheckOnly
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
    [Parameter(ParameterSetName = 'CreateIso')]
    [Parameter(ParameterSetName = 'CheckImages', Mandatory = $true)]
    [ValidateScript({
            if (-not $_ -or (Test-Path $_ -PathType Leaf)) { $true }
            else { throw "ISO file not found: $_" }
        })]
    [string]$IsoPath,
    
    [Parameter(ParameterSetName = 'Build')]
    [Parameter(ParameterSetName = 'CreateIso')]
    [Parameter(ParameterSetName = 'CheckImages')]
    [ValidateSet('2019', '2025')]
    [string]$WindowsVersion = '2025',
    
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
    [switch]$Interactive,
    
    [Parameter(ParameterSetName = 'CreateIso')]
    [switch]$CreateIsoOnly,
    
    [Parameter(ParameterSetName = 'Build')]
    [Parameter(ParameterSetName = 'CreateIso')]
    [switch]$PatchNoPrompt,
    
    [Parameter(ParameterSetName = 'CheckImages')]
    [switch]$CheckImageIndexes
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
    Write-Host ("=" * 70) -ForegroundColor Green
    Write-Host "   Windows Server Golden Image Builder v2.0" -ForegroundColor Green
    Write-Host ("=" * 70) -ForegroundColor Green
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
    Write-Host "  4. Create Custom ISO Only" -ForegroundColor White
    Write-Host "  5. Schedule Weekly Builds" -ForegroundColor White
    Write-Host "  6. Configure Settings" -ForegroundColor White
    Write-Host "  7. View System Information" -ForegroundColor White
    Write-Host "  Q. Quit" -ForegroundColor White
    Write-Host ""
    
    do {
        $choice = Read-Host "Select an option (1-7, Q)"
        
        switch ($choice.ToUpper()) {
            "1" { return "build" }
            "2" { 
                $script:Force = $true
                return "build"
            }
            "3" { return "check" }
            "4" { return "createiso" }
            "5" { return "schedule" }
            "6" { 
                Show-ConfigurationMenu
                Show-InteractiveMenu
                return
            }
            "7" { 
                Show-SystemInformation
                Read-Host "`nPress Enter to continue"
                Show-InteractiveMenu
                return
            }
            "Q" { return "quit" }
            default { 
                Write-Host "Invalid selection. Please choose 1-7 or Q." -ForegroundColor Red
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
        Creates a custom Windows ISO with embedded autounattend.xml and automatic boot prompt elimination
    
    .DESCRIPTION
        This function creates a bootable Windows ISO with the following automatic modifications:
        1. Embeds autounattend.xml for automated installation
        2. Automatically eliminates "press any key" boot prompt if no-prompt EFI files are available
        3. Copies additional packer scripts if available
        4. Creates a fully bootable ISO optimized for automated deployment
        
        Boot Prompt Elimination:
        If the source ISO contains efisys_noprompt.bin and cdboot_noprompt.efi in \efi\microsoft\boot\,
        these will automatically replace the standard boot files to eliminate the "press any key" prompt
        that can cause PXE boot fallback issues in automated environments.
        
        Sources for no-prompt files:
        - Windows 11 ISOs (already include no-prompt versions)
        - Windows ADK deployment tools
        - NTLite-modified ISOs
        - Manual extraction from newer Windows versions
        
    .PARAMETER SourceIsoPath
        Path to the source Windows Server ISO
        
    .PARAMETER OutputIsoPath
        Path where the custom ISO will be created
        
    .PARAMETER UnattendXmlPath
        Path to the autounattend.xml file to embed
        
    .EXAMPLE
        New-CustomIso -SourceIsoPath "C:\ISOs\WinServer_2025.iso" -OutputIsoPath "C:\ISOs\Custom_WinServer_2025.iso" -UnattendXmlPath "C:\autounattend.xml"
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
        
        # Add autounattend.xml to the ROOT of the ISO (always named autounattend.xml)
        Write-WorkflowProgress -Activity "Creating Custom ISO" -Status "Adding autounattend.xml..." -PercentComplete 60
        $autounattendDestination = Join-Path $workingDir "autounattend.xml"
        Copy-Item $UnattendXmlPath $autounattendDestination -Force
        Write-Information "Added autounattend.xml from: $UnattendXmlPath" -InformationAction Continue
        
        # Modify EFI boot files to eliminate "press any key" prompt
        Write-WorkflowProgress -Activity "Creating Custom ISO" -Status "Configuring EFI boot files to eliminate boot prompt..." -PercentComplete 65
        $efiBootPath = Join-Path $workingDir "efi\microsoft\boot"
        if (Test-Path $efiBootPath) {
            try {
                # Check if the no-prompt versions exist
                $efisysNoprompt = Join-Path $efiBootPath "efisys_noprompt.bin"
                $cdbootNoprompt = Join-Path $efiBootPath "cdboot_noprompt.efi"
                $efisysOriginal = Join-Path $efiBootPath "efisys.bin"
                $cdbootOriginal = Join-Path $efiBootPath "cdboot.efi"
                
                if ((Test-Path $efisysNoprompt) -and (Test-Path $cdbootNoprompt)) {
                    Write-Information "Found no-prompt EFI boot files, replacing originals to eliminate boot prompt..." -InformationAction Continue
                    
                    # Backup original files
                    if (Test-Path $efisysOriginal) {
                        Copy-Item $efisysOriginal "$efisysOriginal.backup" -Force
                        Remove-Item $efisysOriginal -Force
                    }
                    if (Test-Path $cdbootOriginal) {
                        Copy-Item $cdbootOriginal "$cdbootOriginal.backup" -Force
                        Remove-Item $cdbootOriginal -Force
                    }
                    
                    # Replace with no-prompt versions
                    Copy-Item $efisysNoprompt $efisysOriginal -Force
                    Copy-Item $cdbootNoprompt $cdbootOriginal -Force
                    
                    Write-Information "EFI boot files successfully modified - ISO will boot without 'press any key' prompt" -InformationAction Continue
                }
                else {
                    Write-Warning "No-prompt EFI boot files (efisys_noprompt.bin, cdboot_noprompt.efi) not found in source ISO."
                    Write-Information "ISO will retain the 'press any key' prompt. To eliminate this:" -InformationAction Continue
                    Write-Information "  1. Use a Windows 11 ISO (includes no-prompt files)" -InformationAction Continue
                    Write-Information "  2. Extract no-prompt files from Windows ADK" -InformationAction Continue
                    Write-Information "  3. Use NTLite to modify the ISO" -InformationAction Continue
                    Write-Information "Continuing with standard boot files..." -InformationAction Continue
                }
            }
            catch {
                Write-Warning "Failed to modify EFI boot files: $($_.Exception.Message)"
                Write-Information "Continuing with standard boot files..." -InformationAction Continue
            }
        }
        else {
            Write-Warning "EFI boot path not found. This may not be a UEFI-compatible ISO."
        }
        
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
        
        # Verify the custom ISO
        Write-WorkflowProgress -Activity "Creating Custom ISO" -Status "Verifying custom ISO..." -PercentComplete 95
        
        $verifyMount = Mount-DiskImage -ImagePath $OutputIsoPath -PassThru
        $verifyDrive = ($verifyMount | Get-Volume).DriveLetter + ":"
        
        # Check for autounattend.xml
        $autounattendExists = Test-Path "$verifyDrive\autounattend.xml"
        
        # Check for Windows image information
        $wimPath = "$verifyDrive\sources\install.wim"
        $installWimExists = Test-Path $wimPath
        
        if ($installWimExists) {
            try {
                # Try to get WIM image information
                $wimInfo = & dism /Get-WimInfo /WimFile:$wimPath
                Write-Information "Available Windows images in ISO:" -InformationAction Continue
                $wimInfo | Where-Object { $_ -match "Index|Name" } | ForEach-Object {
                    Write-Information "  $_" -InformationAction Continue
                }
            }
            catch {
                Write-Verbose "Could not read WIM information: $($_.Exception.Message)"
            }
        }
        
        Dismount-DiskImage -ImagePath $OutputIsoPath | Out-Null
        
        if (-not $autounattendExists) {
            throw "autounattend.xml not found in custom ISO root after verification"
        }
        
        if (-not $installWimExists) {
            Write-Warning "install.wim not found in custom ISO - this may not be a valid Windows installation ISO"
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
        
        # Validate ISO (will be checked later when determining if custom ISO creation is needed)
        Write-WorkflowProgress -Activity "Golden Image Build" -Status "Preparing for build..." -PercentComplete 10
        
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
        
        # Use E: drive for storage (E: has the most available space)
        $packerStorageDir = "E:\packer"
        $boxesStorageDir = "E:\vagrant"
        
        # Get version-specific paths
        $versionPaths = Get-VersionSpecificPaths -WindowsVersion $WindowsVersion -PackerDir $packerDir
        
        # Ensure directories exist
        @($packerStorageDir, $boxesStorageDir) | ForEach-Object {
            if (-not (Test-Path $_)) {
                Write-Host "Creating directory: $_" -ForegroundColor Yellow
                $null = New-Item -ItemType Directory -Path $_ -Force
            }
        }
        
        # Prepare file paths - configs from project, outputs to E: drive
        $unattendXmlPath = $versionPaths.AutoUnattend
        $packerConfigPath = $versionPaths.PackerConfig
        $customIsoPath = Join-Path $packerStorageDir $versionPaths.CustomIsoName
        
        # Validate required files exist
        @($unattendXmlPath, $packerConfigPath) | ForEach-Object {
            if (-not (Test-Path $_)) {
                throw "Required file not found: $_"
            }
        }
        
        # Check if custom ISO already exists, if not create it
        if (-not (Test-Path $customIsoPath)) {
            # Custom ISO doesn't exist - need to create it
            if ($null -eq $script:effectiveIsoPath) {
                throw "Custom ISO not found and no original ISO available to create it. Please provide -IsoPath with the original Windows Server $WindowsVersion ISO."
            }
            Write-WorkflowProgress -Activity "Golden Image Build" -Status "Creating custom Windows ISO..." -PercentComplete 25
            New-CustomIso -SourceIsoPath $script:effectiveIsoPath -OutputIsoPath $customIsoPath -UnattendXmlPath $unattendXmlPath
        }
        else {
            Write-WorkflowProgress -Activity "Golden Image Build" -Status "Using existing custom ISO..." -PercentComplete 25
            Write-Information "Using existing custom ISO: $customIsoPath" -InformationAction Continue
        }
        
        # Execute Packer build
        Write-WorkflowProgress -Activity "Golden Image Build" -Status "Starting Packer build (this may take 30-60 minutes)..." -PercentComplete 30
        $buildDuration = Invoke-PackerBuild -CustomIsoPath $customIsoPath -PackerConfigPath $packerConfigPath -PackerWorkingDir $packerDir
        
        # Package as Vagrant box
        Write-WorkflowProgress -Activity "Golden Image Build" -Status "Packaging as Vagrant box..." -PercentComplete 85
        $packerOutputDir = $versionPaths.OutputDir
        
        # Use version-specific box name if not overridden
        $effectiveBoxName = if ($BoxName) { $BoxName } else { $versionPaths.BoxName }
        
        if ($Force) {
            try {
                & vagrant box remove $effectiveBoxName --provider hyperv --force 2>$null
                Write-Information "Removed existing box: $effectiveBoxName" -InformationAction Continue
            }
            catch {
                Write-Verbose "No existing box to remove"
            }
        }
        
        New-VagrantBoxFromPacker -BoxName $effectiveBoxName -PackerOutputDirectory $packerOutputDir -VagrantBoxDirectory $boxesStorageDir
        
        # Cleanup (preserve custom ISO for reuse)
        Write-WorkflowProgress -Activity "Golden Image Build" -Status "Cleaning up temporary files..." -PercentComplete 95
        # Note: We're preserving the custom ISO for reuse in future builds
        Write-Information "Preserving custom ISO for reuse: $customIsoPath" -InformationAction Continue
        
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
        if ($buildDuration) {
            Write-Host "  Packer build time: $($buildDuration.ToString('hh\:mm\:ss'))" -ForegroundColor White
        }
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

function Invoke-CustomIsoCreation {
    <#
    .SYNOPSIS
        Creates a custom Windows Server 2025 ISO with autounattend.xml as a standalone operation
    
    .DESCRIPTION
        This function creates a custom bootable ISO with embedded autounattend.xml that can be preserved
        between script runs. The ISO is created in the packer directory and will not be automatically cleaned up.
    #>
    [CmdletBinding()]
    param()
    
    Write-Host ("=" * 70) -ForegroundColor Cyan
    Write-Host "Creating Custom Windows Server 2025 ISO" -ForegroundColor Cyan
    Write-Host ("=" * 70) -ForegroundColor Cyan
    Write-Host ""
    
    try {
        # Validate ISO path
        if ($null -eq $script:effectiveIsoPath -or [string]::IsNullOrWhiteSpace($script:effectiveIsoPath)) {
            throw "Original ISO path is required for creating a custom ISO. Please specify -IsoPath with the original Windows Server $WindowsVersion ISO."
        }

        Test-IsoFile -Path $script:effectiveIsoPath
        
        # Get project paths
        $projectRoot = Split-Path $PSScriptRoot -Parent
        $packerDir = Join-Path $projectRoot "packer"
        
        # Use E: drive for storage (E: has the most available space)
        $packerStorageDir = "E:\packer"
        
        # Get version-specific paths
        $versionPaths = Get-VersionSpecificPaths -WindowsVersion $WindowsVersion -PackerDir $packerDir
        
        # Ensure storage directory exists
        if (-not (Test-Path $packerStorageDir)) {
            Write-Host "Creating directory: $packerStorageDir" -ForegroundColor Yellow
            $null = New-Item -ItemType Directory -Path $packerStorageDir -Force
        }
        
        # Prepare file paths - configs from project, outputs to E: drive
        $unattendXmlPath = $versionPaths.AutoUnattend
        $customIsoPath = Join-Path $packerStorageDir $versionPaths.CustomIsoName
        
        # Validate required files exist
        if (-not (Test-Path $unattendXmlPath)) {
            throw "Required file not found: $unattendXmlPath"
        }
        
        # Check if custom ISO already exists
        if (Test-Path $customIsoPath) {
            Write-Host "Existing custom ISO found: $customIsoPath" -ForegroundColor Yellow
            $response = Read-Host "Do you want to recreate it? (y/N)"
            if ($response -notmatch '^[Yy]') {
                Write-Host "Using existing custom ISO." -ForegroundColor Green
                return $customIsoPath
            }
            
            Write-Host "Removing existing custom ISO..." -ForegroundColor Yellow
            Remove-Item $customIsoPath -Force
        }
        
        # Create custom ISO with autounattend.xml
        Write-Host "Creating custom Windows ISO from: $script:effectiveIsoPath" -ForegroundColor Green
        Write-Host "Output location: $customIsoPath" -ForegroundColor Green
        Write-Host ""
        
        New-CustomIso -SourceIsoPath $script:effectiveIsoPath -OutputIsoPath $customIsoPath -UnattendXmlPath $unattendXmlPath
        
        # Verify the result
        if (Test-Path $customIsoPath) {
            $isoSize = (Get-Item $customIsoPath).Length
            $isoSizeMB = [math]::Round($isoSize / 1MB, 2)
            
            Write-Host ""
            Write-Host ("=" * 70) -ForegroundColor Green
            Write-Host "Custom ISO Creation Complete!" -ForegroundColor Green
            Write-Host ("=" * 70) -ForegroundColor Green
            Write-Host ""
            Write-Host "ISO Details:" -ForegroundColor Yellow
            Write-Host "  Location: $customIsoPath" -ForegroundColor White
            Write-Host "  Size: $isoSizeMB MB" -ForegroundColor White
            Write-Host "  Created: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor White
            Write-Host ""
            Write-Host "This ISO contains:" -ForegroundColor Yellow
            Write-Host "  • Windows Server 2025" -ForegroundColor White
            Write-Host "  • Embedded autounattend.xml for automated installation" -ForegroundColor White
            Write-Host "  • Packer automation scripts" -ForegroundColor White
            Write-Host ""
            Write-Host "The ISO is ready for use with Packer or manual VM installation." -ForegroundColor Green
            
            return $customIsoPath
        }
        else {
            throw "Custom ISO was not created successfully"
        }
    }
    catch {
        Write-Host ("=" * 70) -ForegroundColor Red
        Write-Host "Custom ISO Creation Failed!" -ForegroundColor Red
        Write-Host ("=" * 70) -ForegroundColor Red
        Write-Host ""
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
        throw
    }
}

function Get-WindowsImageInfo {
    <#
    .SYNOPSIS
        Gets information about Windows images in an ISO file
    
    .DESCRIPTION
        This function mounts an ISO and extracts information about the available
        Windows installation images, which helps determine the correct image index
        to use in autounattend.xml
    
    .PARAMETER IsoPath
        Path to the Windows ISO file
    
    .EXAMPLE
        Get-WindowsImageInfo -IsoPath "F:\Install\Microsoft\Windows Server\WinServer_2025.iso"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path $_ -PathType Leaf })]
        [string]$IsoPath
    )
    
    try {
        Write-Host "Analyzing Windows images in ISO: $IsoPath" -ForegroundColor Yellow
        
        # Mount the ISO
        $mount = Mount-DiskImage -ImagePath $IsoPath -PassThru -ErrorAction Stop
        $driveLetter = ($mount | Get-Volume).DriveLetter + ":"
        
        # Check for install.wim
        $wimPath = "$driveLetter\sources\install.wim"
        if (Test-Path $wimPath) {
            Write-Host "Found install.wim, getting image information..." -ForegroundColor Green
            
            # Get WIM image information using DISM
            $wimInfo = & dism /Get-WimInfo /WimFile:$wimPath
            
            # Parse and display the information
            $images = @()
            $currentImage = @{
                Index = $null
                Name = $null
                Description = $null
                Size = $null
            }
            
            foreach ($line in $wimInfo) {
                if ($line -match "Index : (\d+)") {
                    if ($currentImage.Index -ne $null) {
                        $images += [PSCustomObject]$currentImage
                    }
                    $currentImage = [ordered]@{ Index = [int]$matches[1] }
                }
                elseif ($line -match "Name : (.+)") {
                    $currentImage.Name = $matches[1].Trim()
                }
                elseif ($line -match "Description : (.+)") {
                    $currentImage.Description = $matches[1].Trim()
                }
                elseif ($line -match "Size : (.+)") {
                    $currentImage.Size = $matches[1].Trim()
                }
            }
            
        # Add the last image
        if ($currentImage.Index -ne $null) {
            $images += [PSCustomObject]$currentImage
        }
        
        # Display results
        Write-Host "`nAvailable Windows Images:" -ForegroundColor Yellow
        Write-Host ("=" * 80) -ForegroundColor Gray
        $images | Format-Table -AutoSize
        
        # Provide recommendations
        Write-Host "`nRecommended image indices for autounattend.xml:" -ForegroundColor Yellow
        $standardImages = $images | Where-Object { $_.Name -match "Datacenter" -and $_.Name -match "(Desktop Experience)" }
        $coreImages = $images | Where-Object { $_.Name -match "Datacenter" -and $_.Name -notmatch "(Desktop Experience)" }
        
        if ($standardImages) {
            Write-Host "For Datacenter Edition (Desktop Experience): Index $($standardImages[0].Index)" -ForegroundColor Green
        }
        if ($coreImages) {
            Write-Host "For Core Edition (no GUI): Index $($coreImages[0].Index)" -ForegroundColor Green
        }
        
        return $images
        }
        else {
            Write-Warning "install.wim not found in ISO sources directory"
            return $null
        }
    }
    catch {
        Write-Error "Failed to analyze ISO: $($_.Exception.Message)"
        return $null
    }
    finally {
        if ($mount) {
            Dismount-DiskImage -ImagePath $IsoPath -ErrorAction SilentlyContinue | Out-Null
        }
    }
}
#endregion

#region Helper Functions for Version Support
function Get-VersionSpecificPaths {
    <#
    .SYNOPSIS
        Gets version-specific file paths for different Windows Server versions
    
    .PARAMETER WindowsVersion
        The Windows Server version (2019 or 2025)
    
    .PARAMETER PackerDir
        The base packer directory containing configuration files
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('2019', '2025')]
        [string]$WindowsVersion,
        
        [Parameter(Mandatory)]
        [string]$PackerDir
    )
    
    $versionPaths = @{
        '2019' = @{
            PackerConfig = Join-Path $PackerDir "windows-server-2019.pkr.hcl"
            AutoUnattend = Join-Path $PackerDir "autounattend-2019.xml"
            CustomIsoName = "custom_windows_server_2019.iso"
            BoxName = "windows-server-2019-golden"
            OutputDir = "E:\packer\output-hyperv-iso-2019"
        }
        '2025' = @{
            PackerConfig = Join-Path $PackerDir "windows-server-2025.pkr.hcl"
            AutoUnattend = Join-Path $PackerDir "autounattend-2025.xml"
            CustomIsoName = "custom_windows_server_2025.iso"
            BoxName = "windows-server-2025-golden"
            OutputDir = "E:\packer\output-hyperv-iso"
        }
    }
    
    return $versionPaths[$WindowsVersion]
}

#endregion

#region Main Execution
try {
    # Initialize configuration and logging
    Initialize-WorkflowConfiguration -ConfigPath $ConfigPath
    Initialize-WorkflowLogging -ScriptName "Build-GoldenImage"
    
    $config = Get-WorkflowConfig
    
    # Set effective parameters - use version-specific box name unless explicitly overridden
    $versionPaths = Get-VersionSpecificPaths -WindowsVersion $WindowsVersion -PackerDir (Join-Path $PSScriptRoot "..\packer")
    $script:effectiveBoxName = if ($BoxName) { $BoxName } else { $versionPaths.BoxName }
    $script:effectiveDaysBeforeRebuild = if ($DaysBeforeRebuild) { $DaysBeforeRebuild } else { $config.golden_image.rebuild_interval_days }
    
    # Find ISO path - check for existing custom ISO first
    $packerStorageDir = "E:\packer"
    $existingCustomIsoPath = Join-Path $packerStorageDir $versionPaths.CustomIsoName
    
    if ($PSBoundParameters.ContainsKey('IsoPath')) {
        # User provided ISO path - validate and use it
        if ($null -eq $IsoPath -or $IsoPath -isnot [string] -or [string]::IsNullOrWhiteSpace($IsoPath)) {
            throw "You must provide a valid string path for -IsoPath. Example: -IsoPath 'F:\\Install\\Microsoft\\Windows Server\\WinServer_2025.iso'"
        }
        $script:effectiveIsoPath = ConvertTo-AbsolutePath -Path $IsoPath
        Write-Information "Using provided ISO path: $($script:effectiveIsoPath)" -InformationAction Continue
    }
    elseif (Test-Path $existingCustomIsoPath) {
        # Custom ISO already exists for this version - use it directly
        $script:effectiveIsoPath = $null  # Not needed since we'll use custom ISO
        Write-Information "Found existing custom ISO for Windows Server $WindowsVersion - no original ISO needed" -InformationAction Continue
        Write-Information "Custom ISO: $existingCustomIsoPath" -InformationAction Continue
    }
    else {
        # No custom ISO exists and no ISO provided - try to find one or fail
        Write-Information "No custom ISO found for Windows Server $WindowsVersion, searching for original ISO..." -InformationAction Continue
        $foundIso = Find-WindowsServerIso
        if ($foundIso -is [string] -and -not [string]::IsNullOrWhiteSpace($foundIso)) {
            $script:effectiveIsoPath = $foundIso
            Write-Information "Auto-detected ISO: $($script:effectiveIsoPath)" -InformationAction Continue
        }
        elseif ($foundIso -is [array]) {
            # Defensive: If Find-WindowsServerIso ever returns an array, pick the first valid string
            $firstString = $foundIso | Where-Object { $_ -is [string] -and -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1
            if ($firstString) {
                $script:effectiveIsoPath = $firstString
                Write-Information "Auto-detected ISO: $($script:effectiveIsoPath)" -InformationAction Continue
            }
            else {
                throw "No custom ISO found for Windows Server $WindowsVersion and no original ISO available. Please either:`n1. Specify -IsoPath with the original Windows Server $WindowsVersion ISO`n2. Or place the original ISO in a default location"
            }
        }
        else {
            throw "No custom ISO found for Windows Server $WindowsVersion and no original ISO available. Please either:`n1. Specify -IsoPath with the original Windows Server $WindowsVersion ISO`n2. Or place the original ISO in a default location"
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
        'CreateIso' {
            Invoke-CustomIsoCreation
            exit 0
        }
        'CheckImages' {
            Write-Host "Checking Windows image indexes in ISO..." -ForegroundColor Yellow
            $images = Get-WindowsImageInfo -IsoPath $IsoPath
            if ($images) {
                Write-Host "`nImage check completed successfully." -ForegroundColor Green
                exit 0
            } else {
                Write-Host "`nImage check failed." -ForegroundColor Red
                exit 1
            }
        }
        'Build' {
            if ($Interactive) {
                $action = Show-InteractiveMenu
                switch ($action) {
                    "build" { Invoke-GoldenImageBuild }
                    "check" { Invoke-BuildCheck }
                    "createiso" { Invoke-CustomIsoCreation }
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