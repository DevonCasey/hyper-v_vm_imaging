<#
.SYNOPSIS
    Enhanced Weekly Golden Image Build Script for Windows Server

.DESCRIPTION
    Automates the creation of Windows Server golden images using Packer and Vagrant.
    Enhanced with improved error handling, progress reporting, and modular design.
    
    Security Features:
    - Generates fresh random passwords for each build using pgen.exe
    - Creates secure credential files only after successful builds
    - Automatically cleans up custom ISOs containing embedded passwords
    - Ensures each VM build has unique Administrator and vagrant passwords

.PARAMETER BoxName
    Name of the Vagrant box to create (uses config default if not specified)

.PARAMETER IsoPath
    Path to the original Windows Server ISO file. If provided, will create a custom ISO even if one already exists for the specified WindowsVersion.

.PARAMETER WindowsVersion
    Windows Server version to build (2019 or 2025). Default: 2019. Used to locate existing custom ISOs or determine which version to auto-detect.

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
    Create only the custom Windows Server ISO with autounattend.xml and exit

.PARAMETER CheckImageIndexes
    Check and display available Windows image indexes in the specified ISO file and exit

.EXAMPLE
    .\Build-GoldenImage.ps1
    Build with default settings (Windows Server 2019)

.EXAMPLE
    .\Build-GoldenImage.ps1 -Force -Interactive
    Force rebuild with interactive prompts

.EXAMPLE
    .\Build-GoldenImage.ps1 -CreateIsoOnly -IsoPath "C:\ISOs\WinServer_2019.iso"
    Create only the custom ISO with autounattend.xml from the specified original ISO

.EXAMPLE
    .\Build-GoldenImage.ps1 -CheckImageIndexes -IsoPath "C:\ISOs\WinServer_2019.iso"
    Check and display available Windows image indexes in the ISO

.EXAMPLE
    .\Build-GoldenImage.ps1 -WindowsVersion 2025
    Build Windows Server 2025 (use existing custom ISO if available, otherwise auto-detect original ISO)

.EXAMPLE
    .\Build-GoldenImage.ps1 -WindowsVersion 2019 -IsoPath "F:\Install\Microsoft\Windows Server\WinServer_2019.iso"
    Build Windows Server 2019 and create custom ISO from the specified original ISO (even if custom ISO already exists)

.EXAMPLE
    .\Build-GoldenImage.ps1 -CreateIsoOnly -WindowsVersion 2025 -IsoPath "F:\Install\Microsoft\Windows Server\WinServer_2025.iso"
    Create only the custom Windows Server 2025 ISO

.EXAMPLE
    .\Build-GoldenImage.ps1 -ConfigPath ".\custom-config.json"
    Use custom configuration file

.EXAMPLE
    .\Build-GoldenImage.ps1 -CheckOnly
    Check if rebuild is needed without building

.NOTES
    Version: 2.1.1
    Author: Devon Casey
    Email: me@devoncasey.com
    GitHub: https://github.com/DevonCasey
    Created: July 1, 2025
    Updated: July 2, 2025 - Enhanced security with fresh passwords per build
    Requires: PowerShell 5.1+, Packer, Vagrant, Hyper-V, Windows ADK
    
    Password Lifecycle:
    1. Fresh random passwords are generated at the start of each build
    2. Passwords are embedded into a temporary autounattend.xml
    3. A custom ISO is created with the embedded autounattend.xml
    4. Packer uses the custom ISO to build the VM with these passwords
    5. After successful build, passwords are saved to a credential file
    6. Custom ISO and temporary files are cleaned up for security
    7. Each build creates a VM with completely unique passwords
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
    [Parameter(ParameterSetName = 'Check')]
    [ValidateSet('2019', '2025')]
    [string]$WindowsVersion = '2019',  # Fixed: Consistent default
    
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

#region Module Imports and Validation
# Import core functions
$coreModulePath = Join-Path $PSScriptRoot "core\Common.psm1"
if (Test-Path $coreModulePath) {
    Import-Module $coreModulePath
}
else {
    throw "Core module not found: $coreModulePath. Please ensure the project structure is intact."
}

# Validate required functions are available
$requiredFunctions = @(
    'Test-Prerequisites', 'Test-HyperVEnvironment', 'Find-WindowsServerIso',
    'Find-OscdimgPath', 'Get-SafeVMName', 'Get-WorkflowConfig',
    'Initialize-WorkflowConfiguration', 'Initialize-WorkflowLogging',
    'Stop-WorkflowLogging', 'Write-WorkflowProgress', 'ConvertTo-AbsolutePath',
    'Test-IsoFile', 'Get-VersionSpecificPaths', 'New-RandomSecurePassword',
    'New-CustomAutounattendXml', 'Save-BuildCredentials'
)

foreach ($func in $requiredFunctions) {
    if (-not (Get-Command $func -ErrorAction SilentlyContinue)) {
        throw "Required function '$func' not found. Please check the Common.psm1 module is complete and properly imported."
    }
}
#endregion

#region Script Variables
$script:effectiveBoxName = $null
$script:effectiveIsoPath = $null
$script:effectiveDaysBeforeRebuild = $null
$script:createCustomIso = $false
$script:forceRebuild = $false  # Fixed: Use script-scoped variable
$script:storageRoot = $null  # Will be determined dynamically
$script:generatedVagrantPassword = $null  # Store generated password for box creation
#endregion

#region Storage Management
function Get-OptimalStoragePath {
    <#
    .SYNOPSIS
        Ensures E: drive has sufficient space and returns the storage path
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [long]$RequiredSpaceGB = 50
    )
    
    try {
        # Check that it exists and has enough space
        $eDrive = Get-CimInstance -ClassName Win32_LogicalDisk | Where-Object { 
            $_.DeviceID -eq "E:" -and 
            $_.DriveType -eq 3  # Fixed disk
        }
        
        if (-not $eDrive) {
            throw "E: drive not found. Please ensure it is connected and accessible."
        }
        
        $freeSpaceGB = [math]::Round($eDrive.FreeSpace / 1GB, 1)
        if ($freeSpaceGB -lt $RequiredSpaceGB) {
            throw "E: drive has insufficient space. Required: $RequiredSpaceGB GB, Available: $freeSpaceGB GB"
        }
        
        $storagePath = "E:\vm_images"
        Write-Information "Using E: drive for storage: $storagePath (Free: $freeSpaceGB GB)" -InformationAction Continue
        
        # Ensure the base directory exists
        if (-not (Test-Path $storagePath)) {
            New-Item -ItemType Directory -Path $storagePath -Force | Out-Null
            Write-Information "Created storage directory: $storagePath" -InformationAction Continue
        }
        
        return $storagePath
    }
    catch {
        Write-Error "Storage validation failed: $($_.Exception.Message)"
        throw
    }
}
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
    Write-Host "   Windows Server Golden Image Builder v2.1" -ForegroundColor Green
    Write-Host ("=" * 70) -ForegroundColor Green
    Write-Host ""
    
    $currentBox = Get-CurrentBoxInfo -BoxName $script:effectiveBoxName
    
    # Display current status
    Write-Host "Current Configuration:" -ForegroundColor Yellow
    Write-Host "  Box Name: $script:effectiveBoxName" -ForegroundColor White
    Write-Host "  Windows Version: $WindowsVersion" -ForegroundColor White
    Write-Host "  ISO Path: $(if ($script:effectiveIsoPath) { $script:effectiveIsoPath } else { 'Auto-detect' })" -ForegroundColor White
    Write-Host "  Storage Root: $script:storageRoot" -ForegroundColor White
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
                $script:forceRebuild = $true  # Fixed: Use script variable
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
    Write-Host "  2. ISO Path: $(if ($script:effectiveIsoPath) { $script:effectiveIsoPath } else { 'Auto-detect' })" -ForegroundColor White
    Write-Host "  3. Storage Root: $script:storageRoot" -ForegroundColor White
    Write-Host "  4. Rebuild Interval: $script:effectiveDaysBeforeRebuild days" -ForegroundColor White
    Write-Host ""
    Write-Host "  R. Reset to Defaults" -ForegroundColor White
    Write-Host "  B. Back to Main Menu" -ForegroundColor White
    Write-Host ""
    
    do {
        $choice = Read-Host "Select setting to change (1-4, R, B)"
        
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
                $newIsoPath = Read-Host "Enter new ISO path (leave empty for auto-detect)"
                if ($newIsoPath -and (Test-Path $newIsoPath)) {
                    $script:effectiveIsoPath = $newIsoPath
                    Write-Host "ISO path updated to: $script:effectiveIsoPath" -ForegroundColor Green
                }
                elseif (-not $newIsoPath) {
                    $script:effectiveIsoPath = $null
                    Write-Host "ISO path set to auto-detect" -ForegroundColor Green
                }
                elseif ($newIsoPath) {
                    Write-Host "ISO file not found: $newIsoPath" -ForegroundColor Red
                }
                break
            }
            "3" {
                $newStorageRoot = Read-Host "Enter new storage root path [$script:storageRoot]"
                if ($newStorageRoot -and (Test-Path (Split-Path $newStorageRoot -Parent))) {
                    $script:storageRoot = $newStorageRoot
                    Write-Host "Storage root updated to: $script:storageRoot" -ForegroundColor Green
                }
                elseif ($newStorageRoot) {
                    Write-Host "Parent directory not found: $newStorageRoot" -ForegroundColor Red
                }
                break
            }
            "4" {
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
                Write-Host "Invalid selection. Please choose 1-4, R, or B." -ForegroundColor Red
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
    
    $os = $null
    $computer = $null
    
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
            @{ Name = "pgen.exe"; Command = "pgen.exe --help" },
            @{ Name = "Hyper-V"; Test = {
                    try {
                        $feature = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -ErrorAction SilentlyContinue
                        return $feature.State -eq 'Enabled'
                    }
                    catch {
                        return $false
                    }
                } 
            }
        )
        
        foreach ($tool in $tools) {
            try {
                if ($tool.Command) {
                    $null = Invoke-Expression "$($tool.Command) 2>$null"
                    if ($LASTEXITCODE -eq 0) {
                        Write-Host "  ✓ $($tool.Name): Available" -ForegroundColor Green
                    }
                    else {
                        Write-Host "  ✗ $($tool.Name): Not Available" -ForegroundColor Red
                    }
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
        
        # Show storage information
        Write-Host "Storage Information:" -ForegroundColor Yellow
        Get-WmiObject -Class Win32_LogicalDisk | Where-Object { $_.DriveType -eq 3 } | ForEach-Object {
            $freeSpaceGB = [math]::Round($_.FreeSpace / 1GB, 1)
            $totalSpaceGB = [math]::Round($_.Size / 1GB, 1)
            $percentFree = [math]::Round(($_.FreeSpace / $_.Size) * 100, 1)
            $color = if ($percentFree -gt 25) { "Green" } elseif ($percentFree -gt 10) { "Yellow" } else { "Red" }
            Write-Host "  $($_.DeviceID) $freeSpaceGB GB free of $totalSpaceGB GB ($percentFree%)" -ForegroundColor $color
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
        
        # Check for running VMs that might be in build process
        Write-Host "Running VMs:" -ForegroundColor Yellow
        try {
            $runningVMs = Get-VM | Where-Object { $_.State -eq 'Running' }
            if ($runningVMs) {
                foreach ($vm in $runningVMs) {
                    Write-Host "  • $($vm.Name) - $($vm.State)" -ForegroundColor White
                    # Check if this might be a Packer build VM
                    if ($vm.Name -like "*packer*" -or $vm.Name -like "*windows-server*") {
                        Write-Host "    ⚠️  This may be a Packer build VM - do not connect to console!" -ForegroundColor Red
                    }
                }
            }
            else {
                Write-Host "  No running VMs" -ForegroundColor Gray
            }
        }
        catch {
            Write-Host "  Unable to query VMs" -ForegroundColor Red
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
    finally {
        # Clear memory
        $os = $null
        $computer = $null
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
    $versionPaths = Get-VersionSpecificPaths -WindowsVersion $WindowsVersion -PackerDir (Join-Path $PSScriptRoot "..\packer")
    
    $script:effectiveBoxName = if ($BoxName) { $BoxName } else { $versionPaths.BoxName }
    $script:effectiveDaysBeforeRebuild = if ($DaysBeforeRebuild) { $DaysBeforeRebuild } else { $config.golden_image.rebuild_interval_days }
    $script:storageRoot = Get-OptimalStoragePath
    
    # Try to find ISO
    if (-not $IsoPath) {
        $foundIso = Find-WindowsServerIso -WindowsVersion $WindowsVersion
        if ($foundIso -is [string] -and -not [string]::IsNullOrWhiteSpace($foundIso)) {
            $script:effectiveIsoPath = $foundIso
        }
        elseif ($foundIso -is [array]) {
            $firstString = $foundIso | Where-Object { $_ -is [string] -and -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1
            if ($firstString) {
                $script:effectiveIsoPath = $firstString
            }
        }
    }
    
    # Clear memory
    $config = $null
    $versionPaths = $null
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
        
    .PARAMETER SourceIsoPath
        Path to the source Windows Server ISO
        
    .PARAMETER OutputIsoPath
        Path where the custom ISO will be created
        
    .PARAMETER UnattendXmlPath
        Path to the autounattend.xml file to embed
        
    .EXAMPLE
        New-CustomIso -SourceIsoPath "C:\ISOs\WinServer_2019.iso" -OutputIsoPath "C:\ISOs\Custom_WinServer_2019.iso" -UnattendXmlPath "C:\autounattend.xml"
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
    
    # Always use E: drive for temporary files to avoid filling C: drive
    $tempBase = "E:\Temp"
    if (-not (Test-Path $tempBase)) {
        New-Item -ItemType Directory -Path $tempBase -Force | Out-Null
    }
    $workingDir = Join-Path $tempBase "winiso_$(Get-Random)"
    $mount = $null
    $verifyMount = $null
    
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
        
        # Use robocopy for more efficient copying of large ISO contents
        $robocopyArgs = @(
            "$driveLetter\",
            $workingDir,
            "/E",
            "/R:1",
            "/W:1",
            "/NP"
        )
        
        $robocopyProcess = Start-Process -FilePath "robocopy" -ArgumentList $robocopyArgs -PassThru -WindowStyle Hidden -Wait
        # Robocopy exit codes 0-7 are success
        if ($robocopyProcess.ExitCode -gt 7) {
            Write-Warning "Robocopy completed with warnings (exit code: $($robocopyProcess.ExitCode))"
        }
        
        # Dispose of process object
        if ($robocopyProcess) {
            $robocopyProcess.Dispose()
            $robocopyProcess = $null
        }
        
        # Add autounattend.xml to the ROOT of the ISO (always named autounattend.xml)
        Write-WorkflowProgress -Activity "Creating Custom ISO" -Status "Adding autounattend.xml..." -PercentComplete 60
        $autounattendDestination = Join-Path $workingDir "autounattend.xml"
        Copy-Item $UnattendXmlPath $autounattendDestination -Force
        Write-Information "Added autounattend.xml from: $UnattendXmlPath" -InformationAction Continue
        
        # Modify EFI boot files to eliminate "press any key" prompt
        Write-WorkflowProgress -Activity "Creating Custom ISO" -Status "Configuring EFI boot files..." -PercentComplete 65
        $efiBootPath = Join-Path $workingDir "efi\microsoft\boot"
        if (Test-Path $efiBootPath) {
            try {
                # Check if the no-prompt versions exist
                $efisysNoprompt = Join-Path $efiBootPath "efisys_noprompt.bin"
                $cdbootNoprompt = Join-Path $efiBootPath "cdboot_noprompt.efi"
                $efisysOriginal = Join-Path $efiBootPath "efisys.bin"
                $cdbootOriginal = Join-Path $efiBootPath "cdboot.efi"
                
                if ((Test-Path $efisysNoprompt) -and (Test-Path $cdbootNoprompt)) {
                    Write-Information "Found no-prompt EFI boot files, replacing originals..." -InformationAction Continue
                    
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
                    
                    Write-Information "EFI boot files successfully injected to ISO" -InformationAction Continue
                }
                else {
                    Write-Warning "No-prompt EFI boot files not found in source ISO."
                    Write-Information "ISO will be standard" -InformationAction Continue
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
        
        $oscdimgProcess = Start-Process -FilePath $oscdimgPath -ArgumentList $oscdimgArgs -PassThru -WindowStyle Hidden -Wait
        
        try {
            $oscdimgProcess.WaitForExit()
            $exitCode = $oscdimgProcess.ExitCode
            
            if ($exitCode -ne 0) {
                throw "oscdimg failed with exit code: $exitCode"
            }
        }
        finally {
            if ($oscdimgProcess) {
                $oscdimgProcess.Dispose()
                $oscdimgProcess = $null
            }
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
                $wimInfo = & dism /Get-WimInfo /WimFile:$wimPath 2>$null
                Write-Information "Available Windows images in ISO:" -InformationAction Continue
                $wimInfo | Where-Object { $_ -match "Index|Name" } | ForEach-Object {
                    Write-Information "  $_" -InformationAction Continue
                }
                $wimInfo = $null  # Clear memory
            }
            catch {
                Write-Verbose "Could not read WIM information: $($_.Exception.Message)"
            }
        }
        
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
        # Proper cleanup of mounted ISOs
        if ($mount) {
            try {
                Dismount-DiskImage -ImagePath $SourceIsoPath -ErrorAction SilentlyContinue | Out-Null
            }
            catch {
                Write-Verbose "Failed to dismount source ISO: $($_.Exception.Message)"
            }
        }
        
        if ($verifyMount) {
            try {
                Dismount-DiskImage -ImagePath $OutputIsoPath -ErrorAction SilentlyContinue | Out-Null
            }
            catch {
                Write-Verbose "Failed to dismount output ISO: $($_.Exception.Message)"
            }
        }
        
        if (Test-Path $workingDir) {
            Remove-Item $workingDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        
        # Clear variables to free memory
        $mount = $null
        $verifyMount = $null
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
        [string]$PackerWorkingDir,
        
        [Parameter(Mandatory)]
        [string]$OutputDirectory  # Fixed: Pass the correct output directory
    )
    
    $originalLocation = Get-Location
    $packerProcess = $null
    
    try {
        # Change to packer directory
        Set-Location $PackerWorkingDir
        
        # Clean previous build artifacts - use the correct output directory
        Write-WorkflowProgress -Activity "Packer Build" -Status "Cleaning previous artifacts..." -PercentComplete 5
        
        if (Test-Path $OutputDirectory) {
            Write-Information "Removing existing output directory: $OutputDirectory" -InformationAction Continue
            try {
                # Force close any file handles and remove directory
                Remove-Item $OutputDirectory -Recurse -Force -ErrorAction Stop
                Start-Sleep -Milliseconds 500  # Brief pause to ensure cleanup completes
            }
            catch {
                Write-Warning "Failed to remove output directory: $($_.Exception.Message)"
                # Try to remove contents individually if direct removal fails
                try {
                    Get-ChildItem $OutputDirectory -Recurse -Force | Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
                    Remove-Item $OutputDirectory -Force -ErrorAction Stop
                }
                catch {
                    throw "Cannot remove existing output directory '$OutputDirectory'. Please ensure no files are in use and try again."
                }
            }
        }
        
        # Remove any lingering VHDX files
        Get-ChildItem -Path $PackerWorkingDir -Filter "*.vhdx" -Recurse -ErrorAction SilentlyContinue | 
        ForEach-Object {
            Write-Verbose "Removing orphaned VHDX file: $($_.FullName)"
            Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
        }
        
        # Validate inputs
        @($CustomIsoPath, $PackerConfigPath) | ForEach-Object {
            if (-not (Test-Path $_)) {
                throw "Required file not found: $_"
            }
        }
        
        $buildStartTime = Get-Date
        Write-WorkflowProgress -Activity "Packer Build" -Status "Starting build..." -PercentComplete 10
                
        # Build with custom ISO
        $configFileName = Split-Path $PackerConfigPath -Leaf
        $packerArgs = @(
            'build', 
            '-var', "iso_url=$CustomIsoPath",
            '-var', "OutputDirectory=$OutputDirectory",
            '-var', "vlan_id=31",
            $configFileName
        )
        
        # Execute packer with logging
        $env:PACKER_LOG = "1"
        $packerLogPath = Join-Path $PackerWorkingDir "packer-build.log"
        $env:PACKER_LOG_PATH = $packerLogPath
        
        Write-Information "Executing: packer $($packerArgs -join ' ')" -InformationAction Continue
        
        # Use proper process handling instead of direct invocation
        $packerProcess = Start-Process -FilePath "packer" -ArgumentList $packerArgs -PassThru -WindowStyle Hidden -Wait
        
        try {
            $packerProcess.WaitForExit()
            $exitCode = $packerProcess.ExitCode
            
            if ($exitCode -ne 0) {
                $errorDetails = ""
                if (Test-Path $packerLogPath) {
                    $errorDetails = Get-Content $packerLogPath | Select-Object -Last 20 | Out-String
                }
                throw "Packer build failed with exit code: $exitCode`n$errorDetails"
            }
        }
        finally {
            if ($packerProcess) {
                $packerProcess.Dispose()
                $packerProcess = $null
            }
        }
        
        $buildDuration = (Get-Date) - $buildStartTime
        Write-Information "Packer build completed in $($buildDuration.ToString('hh\:mm\:ss'))" -InformationAction Continue
        Write-Information "✅ VM Console Access: Build complete - console access now safe (VM is powered off)" -InformationAction Continue
        
        # Verify output
        if (-not (Test-Path $OutputDirectory)) {
            throw "Packer output directory not found: $OutputDirectory"
        }
        
        $vhdxFiles = Get-ChildItem $OutputDirectory -Filter "*.vhdx" -Recurse
        if ($vhdxFiles.Count -eq 0) {
            throw "No VHDX files found in Packer output directory"
        }
        
        return $buildDuration
    }
    finally {
        Set-Location $originalLocation
        $env:PACKER_LOG = $null
        $env:PACKER_LOG_PATH = $null
        
        # Clean up process if not already done
        if ($packerProcess) {
            try {
                $packerProcess.Dispose()
            }
            catch {
                Write-Verbose "Error disposing packer process: $($_.Exception.Message)"
            }
            $packerProcess = $null
        }
    }
}

function New-VagrantBoxFromPacker {
    <#
    .SYNOPSIS
        Creates a Vagrant box from Packer output with secure password handling
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$BoxName,
        
        [Parameter(Mandatory)]
        [string]$PackerOutputDirectory,
        
        [Parameter(Mandatory)]
        [string]$VagrantBoxDirectory,
        
        [Parameter(Mandatory)]
        [SecureString]$VagrantPasswordSecure  # Fixed: Accept the actual generated password
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
    
    # Create temporary directory for box packaging on E: drive
    $tempBase = "E:\Temp"
    if (-not (Test-Path $tempBase)) {
        New-Item -ItemType Directory -Path $tempBase -Force | Out-Null
    }
    $tempDirectory = Join-Path $tempBase "vagrant-box-$BoxName-$(Get-Random)"
    
    # Convert SecureString to plain text for Vagrantfile (unavoidable)
    $vagrantPassword = $null
    
    try {
        $vagrantPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($VagrantPasswordSecure))
        
        New-Item -ItemType Directory -Path $tempDirectory -Force | Out-Null
        
        Write-WorkflowProgress -Activity "Creating Vagrant Box" -Status "Copying VHDX file..." -PercentComplete 30
        
        # Copy VHDX with safe naming
        $safeVMName = Get-SafeVMName -Name $BoxName
        $boxVhdx = Join-Path $tempDirectory "${safeVMName}_os.vhdx"
        Copy-Item $vhdxFile.FullName $boxVhdx
        
        Write-WorkflowProgress -Activity "Creating Vagrant Box" -Status "Creating box metadata..." -PercentComplete 50
        
        # Create Vagrantfile for Windows box with actual generated password using StringBuilder for efficiency
        $boxVagrantfile = [System.Text.StringBuilder]::new()
        $boxVagrantfile.AppendLine('Vagrant.configure("2") do |config|') | Out-Null
        $boxVagrantfile.AppendLine('  config.vm.guest = :windows') | Out-Null
        $boxVagrantfile.AppendLine('  config.vm.communicator = "winrm"') | Out-Null
        $boxVagrantfile.AppendLine('  config.winrm.username = "vagrant"') | Out-Null
        $boxVagrantfile.AppendLine("  config.winrm.password = `"$vagrantPassword`"") | Out-Null
        $boxVagrantfile.AppendLine('  config.winrm.transport = :ssl') | Out-Null
        $boxVagrantfile.AppendLine('  config.winrm.ssl_peer_verification = false') | Out-Null
        $boxVagrantfile.AppendLine('  config.winrm.basic_auth_only = true') | Out-Null
        $boxVagrantfile.AppendLine('  ') | Out-Null
        $boxVagrantfile.AppendLine('  config.vm.provider "hyperv" do |hv|' ) | Out-Null
        $boxVagrantfile.AppendLine('    hv.enable_virtualization_extensions = false') | Out-Null
        $boxVagrantfile.AppendLine('    hv.linked_clone = false') | Out-Null
        $boxVagrantfile.AppendLine('    hv.enable_secure_boot = false') | Out-Null
        $boxVagrantfile.AppendLine('  end') | Out-Null
        $boxVagrantfile.AppendLine('end') | Out-Null
        
        $vagrantfileContent = $boxVagrantfile.ToString()
        $boxVagrantfile = $null  # Clear StringBuilder
        
        Set-Content -Path (Join-Path $tempDirectory "Vagrantfile") -Value $vagrantfileContent
        $vagrantfileContent = $null  # Clear content variable
        
        # Create metadata.json
        $metadata = @{
            provider  = "hyperv"
            format    = "vhdx"
            vm_name   = $safeVMName
            vhdx_file = "${safeVMName}_os.vhdx"
            created_date = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            windows_version = $WindowsVersion
        } | ConvertTo-Json
        
        Set-Content -Path (Join-Path $tempDirectory "metadata.json") -Value $metadata
        
        Write-WorkflowProgress -Activity "Creating Vagrant Box" -Status "Packaging box file..." -PercentComplete 70
        
        # Package the box
        $boxFile = Join-Path $VagrantBoxDirectory "$BoxName.box"
        Set-Location $tempDirectory
        
        # Use tar if available, otherwise PowerShell compression
        if (Get-Command tar -ErrorAction SilentlyContinue) {
            $tarProcess = Start-Process -FilePath "tar" -ArgumentList @('-czf', $boxFile, '*') -PassThru -WindowStyle Hidden -Wait
            try {
                $tarProcess.WaitForExit()
                if ($tarProcess.ExitCode -ne 0) {
                    throw "tar command failed with exit code: $($tarProcess.ExitCode)"
                }
            }
            finally {
                if ($tarProcess) {
                    $tarProcess.Dispose()
                    $tarProcess = $null
                }
            }
        }
        else {
            Compress-Archive -Path "$tempDirectory\*" -DestinationPath "$boxFile.zip"
            Move-Item "$boxFile.zip" $boxFile
        }
        
        Write-WorkflowProgress -Activity "Creating Vagrant Box" -Status "Adding box to Vagrant..." -PercentComplete 90
        
        # Add box to Vagrant
        $vagrantProcess = Start-Process -FilePath "vagrant" -ArgumentList @('box', 'add', $BoxName, $boxFile, '--force') -PassThru -WindowStyle Hidden -Wait
        
        try {
            $vagrantProcess.WaitForExit()
            if ($vagrantProcess.ExitCode -ne 0) {
                throw "vagrant box add failed with exit code: $($vagrantProcess.ExitCode)"
            }
        }
        finally {
            if ($vagrantProcess) {
                $vagrantProcess.Dispose()
                $vagrantProcess = $null
            }
        }
        
        Write-WorkflowProgress -Activity "Creating Vagrant Box" -Status "Complete" -PercentComplete 100
        Write-Information "Box '$BoxName' created and added to Vagrant successfully" -InformationAction Continue
        Write-Information "Box uses the generated secure password for the vagrant user" -InformationAction Continue
        
    }
    finally {
        Set-Location $PSScriptRoot
        
        # Clear password variable and force garbage collection
        if ($vagrantPassword) {
            $vagrantPassword = $null
        }
        
        if (Test-Path $tempDirectory) {
            Remove-Item $tempDirectory -Recurse -Force -ErrorAction SilentlyContinue
        }
        
        # Clear variables
        $metadata = $null
    }
}

function Clear-PreviousRunArtifacts {
    <#
    .SYNOPSIS
        Cleans up leftover files from previous unfinished script runs
    .DESCRIPTION
        Removes temporary autounattend.xml files and other artifacts that may have been left 
        behind from interrupted or failed previous runs to ensure a clean build environment.
    #>
    [CmdletBinding()]
    param()
    
    Write-Information "Cleaning up artifacts from previous runs..." -InformationAction Continue
    
    try {
        # Get the packer directory to look for leftover temp files
        $projectRoot = Split-Path $PSScriptRoot -Parent
        $packerDir = Join-Path $projectRoot "packer"
        
        if (Test-Path $packerDir) {
            # Remove temporary autounattend.xml files (those with -temp- in the name)
            $tempAutounattendFiles = Get-ChildItem -Path $packerDir -Filter "*autounattend*temp*.xml" -ErrorAction SilentlyContinue
            foreach ($file in $tempAutounattendFiles) {
                try {
                    Remove-Item $file.FullName -Force
                    Write-Information "Removed leftover temp autounattend file: $($file.Name)" -InformationAction Continue
                }
                catch {
                    Write-Warning "Could not remove temp file $($file.FullName): $($_.Exception.Message)"
                }
            }
            
            # Also check for any autounattend files in subdirectories
            $tempAutounattendFilesRecursive = Get-ChildItem -Path $packerDir -Filter "*autounattend*temp*.xml" -Recurse -ErrorAction SilentlyContinue
            foreach ($file in $tempAutounattendFilesRecursive) {
                try {
                    Remove-Item $file.FullName -Force
                    Write-Information "Removed leftover temp autounattend file: $($file.FullName)" -InformationAction Continue
                }
                catch {
                    Write-Warning "Could not remove temp file $($file.FullName): $($_.Exception.Message)"
                }
            }
        }
        
        # Clean up temporary directories that might be left on E: drive
        $tempBase = "E:\Temp"
        if (Test-Path $tempBase) {
            # Look for directories with our naming patterns
            $leftoverDirs = @()
            $leftoverDirs += Get-ChildItem -Path $tempBase -Directory -Filter "winiso_*" -ErrorAction SilentlyContinue
            $leftoverDirs += Get-ChildItem -Path $tempBase -Directory -Filter "vagrant-box-*" -ErrorAction SilentlyContinue
            
            foreach ($dir in $leftoverDirs) {
                try {
                    # Only remove if it's older than 1 hour to avoid interfering with concurrent runs
                    if ($dir.LastWriteTime -lt (Get-Date).AddHours(-1)) {
                        Remove-Item $dir.FullName -Recurse -Force
                        Write-Information "Removed leftover temp directory: $($dir.Name)" -InformationAction Continue
                    }
                }
                catch {
                    Write-Warning "Could not remove temp directory $($dir.FullName): $($_.Exception.Message)"
                }
            }
        }
        
        # Clean up any leftover Packer output directories
        $packerOutputPaths = @(
            "E:\packer\output-hyperv-iso",
            "E:\packer\output-hyperv-iso-2019",
            "E:\packer\output-hyperv-iso-2025"
        )
        
        foreach ($outputPath in $packerOutputPaths) {
            if (Test-Path $outputPath) {
                try {
                    # Only remove if it's older than 30 minutes to avoid interfering with concurrent runs
                    $lastWrite = (Get-ChildItem $outputPath -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | Select-Object -Last 1).LastWriteTime
                    if ($null -eq $lastWrite -or $lastWrite -lt (Get-Date).AddMinutes(-30)) {
                        Remove-Item $outputPath -Recurse -Force
                        Write-Information "Removed leftover Packer output directory: $outputPath" -InformationAction Continue
                    }
                    else {
                        Write-Information "Skipping recent Packer output directory (may be in use): $outputPath" -InformationAction Continue
                    }
                }
                catch {
                    Write-Warning "Could not remove Packer output directory $outputPath" + ": $($_.Exception.Message)"
                }
            }
        }
        
        Write-Information "Artifact cleanup completed" -InformationAction Continue
    }
    catch {
        Write-Warning "Error during artifact cleanup: $($_.Exception.Message)"
        # Don't fail the entire build for cleanup issues
    }
}

function Invoke-GoldenImageBuild {
    <#
    .SYNOPSIS
        Main function to build the golden image with secure password handling
    .DESCRIPTION
        Orchestrates the complete golden image build process including secure password generation,
        custom ISO creation, Packer build execution, and Vagrant box packaging.
    #>
    [CmdletBinding()]
    param()
    
    # Secure password variables
    $adminPasswordSecure = $null
    $vagrantPasswordSecure = $null
    
    try {
        Write-Host ("=" * 70) -ForegroundColor Green
        Write-Host "Starting Golden Image Build Process" -ForegroundColor Green
        Write-Host ("=" * 70) -ForegroundColor Green
        Write-Host ""
        
        Write-Host "Configuration:" -ForegroundColor Yellow
        Write-Host "  Box Name: $script:effectiveBoxName" -ForegroundColor White
        Write-Host "  Windows Version: $WindowsVersion" -ForegroundColor White
        Write-Host "  ISO Path: $(if ($script:effectiveIsoPath) { $script:effectiveIsoPath } else { 'Auto-detect' })" -ForegroundColor White
        Write-Host "  Storage Root: $script:storageRoot" -ForegroundColor White
        Write-Host "  Force Rebuild: $(if ($script:forceRebuild -or $Force) { 'Yes' } else { 'No' })" -ForegroundColor White
        Write-Host "  Started: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor White
        Write-Host ""
        
        $buildStartTime = Get-Date
        
        # Clean up any leftover artifacts from previous runs
        Clear-PreviousRunArtifacts
        
        # Validate environment
        Write-WorkflowProgress -Activity "Golden Image Build" -Status "Validating environment..." -PercentComplete 5
        Test-Prerequisites
        Test-HyperVEnvironment
        
        # Check if rebuild is needed
        if (-not ($script:forceRebuild -or $Force)) {
            Write-WorkflowProgress -Activity "Golden Image Build" -Status "Checking if rebuild is needed..." -PercentComplete 10
            $boxInfo = Get-CurrentBoxInfo -BoxName $script:effectiveBoxName
            
            if ($boxInfo.Exists -and -not $boxInfo.NeedsRebuild) {
                Write-Host "`nGolden image is still fresh (age: $($boxInfo.AgeDays) days)." -ForegroundColor Green
                Write-Host "Use -Force to rebuild anyway." -ForegroundColor Yellow
                return
            }
            
            # Clear box info to free memory
            $boxInfo = $null
        }
        
        # Get project paths with better error handling
        $projectRoot = Split-Path $PSScriptRoot -Parent
        $packerDir = Join-Path $projectRoot "packer"
        
        if (-not (Test-Path $packerDir)) {
            throw "Packer directory not found: $packerDir. Please ensure the project structure is correct."
        }
        
        # Use dynamic storage paths
        $packerStorageDir = Join-Path $script:storageRoot "packer"
        $boxesStorageDir = Join-Path $script:storageRoot "vagrant"
        
        # Get version-specific paths
        $versionPaths = Get-VersionSpecificPaths -WindowsVersion $WindowsVersion -PackerDir $packerDir -StorageRoot $script:storageRoot
        
        # Ensure directories exist
        @($packerStorageDir, $boxesStorageDir) | ForEach-Object {
            if (-not (Test-Path $_)) {
                Write-Host "Creating directory: $_" -ForegroundColor Yellow
                $null = New-Item -ItemType Directory -Path $_ -Force
            }
        }
        
        # Prepare file paths - configs from project, outputs to storage
        $unattendXmlPath = $versionPaths.AutoUnattend
        $packerConfigPath = $versionPaths.PackerConfig
        $customIsoPath = Join-Path $packerStorageDir $versionPaths.CustomIsoName
        
        # Validate required files exist
        @($unattendXmlPath, $packerConfigPath) | ForEach-Object {
            if (-not (Test-Path $_)) {
                throw "Required file not found: $_"
            }
        }
        
        # Prepare credential file path
        $isoDir = Split-Path $customIsoPath -Parent
        $credentialsPath = Join-Path $isoDir "windows-server-$WindowsVersion-credentials.json"
        
        # ALWAYS generate new passwords for each Packer build
        Write-WorkflowProgress -Activity "Golden Image Build" -Status "Generating new secure passwords for this build..." -PercentComplete 15
        Write-Information "Generating new secure random passwords for Administrator and vagrant accounts..." -InformationAction Continue
        
        try {
            $adminPasswordSecure = New-RandomSecurePassword
            $vagrantPasswordSecure = New-RandomSecurePassword
            
            # Store for box creation
            $script:generatedVagrantPassword = $vagrantPasswordSecure
            
            Write-Information "New passwords generated securely using pgen.exe" -InformationAction Continue
        } 
        catch {
            Write-Error "Failed to generate secure passwords: $($_.Exception.Message)"
            throw
        }
        
        # Create customized autounattend.xml with NEW generated passwords
        Write-WorkflowProgress -Activity "Golden Image Build" -Status "Creating customized autounattend.xml with new passwords..." -PercentComplete 18
        
        $customAutounattendPath = $unattendXmlPath -replace '\.xml$', "-temp-$(Get-Random).xml"
        New-CustomAutounattendXml -TemplateXmlPath $unattendXmlPath -OutputXmlPath $customAutounattendPath -AdminPasswordSecure $adminPasswordSecure -VagrantPasswordSecure $vagrantPasswordSecure -WindowsVersion $WindowsVersion
        
        # Check if we need to create or update the custom ISO
        $customIsoExists = Test-Path $customIsoPath
        if ($customIsoExists -and -not $script:createCustomIso) {
            Write-WorkflowProgress -Activity "Golden Image Build" -Status "Updating existing custom ISO with fresh passwords..." -PercentComplete 20
            Write-Information "Found existing custom ISO - updating with fresh passwords for security: $customIsoPath" -InformationAction Continue
            
            # Update existing custom ISO with fresh passwords
            try {
                Update-CustomIsoPasswords -CustomIsoPath $customIsoPath -UnattendXmlPath $customAutounattendPath
                Write-Information "Successfully updated custom ISO with fresh passwords" -InformationAction Continue
                $useExistingCustomIso = $true
            }
            catch {
                Write-Warning "Failed to update existing custom ISO: $($_.Exception.Message)"
                Write-Information "Falling back to recreating custom ISO from original source" -InformationAction Continue
                
                # Remove the problematic custom ISO and recreate from scratch
                try {
                    Remove-Item $customIsoPath -Force
                }
                catch {
                    Write-Warning "Could not remove problematic custom ISO: $($_.Exception.Message)"
                }
                $useExistingCustomIso = $false
            }
        }
        elseif ($customIsoExists -and $script:createCustomIso) {
            Write-WorkflowProgress -Activity "Golden Image Build" -Status "Recreating custom ISO with fresh passwords..." -PercentComplete 20
            Write-Information "Existing custom ISO found - recreating with fresh passwords for security" -InformationAction Continue
            
            # Remove existing custom ISO to recreate with new passwords
            try {
                Remove-Item $customIsoPath -Force
                Write-Information "Removed existing custom ISO for recreation with fresh passwords" -InformationAction Continue
            }
            catch {
                Write-Warning "Could not remove existing custom ISO: $($_.Exception.Message)"
            }
            $useExistingCustomIso = $false
        }
        else {
            Write-WorkflowProgress -Activity "Golden Image Build" -Status "Creating new custom ISO with fresh passwords..." -PercentComplete 20
            Write-Information "No existing custom ISO found - creating new one with fresh passwords" -InformationAction Continue
            $useExistingCustomIso = $false
        }
        
        # Only create custom ISO if we need a new one
        if (-not $useExistingCustomIso) {
            # Ensure we have the original ISO to create custom ISO
            if ($null -eq $script:effectiveIsoPath) {
                # Try to find ISO again as a fallback
                Write-Information "No ISO path specified, attempting to auto-detect Windows Server $WindowsVersion ISO..." -InformationAction Continue
                
                $foundIso = Find-WindowsServerIso -WindowsVersion $WindowsVersion
                if ($foundIso -is [string] -and -not [string]::IsNullOrWhiteSpace($foundIso)) {
                    $script:effectiveIsoPath = $foundIso
                    Write-Information "Found original ISO: $script:effectiveIsoPath" -InformationAction Continue
                }
                elseif ($foundIso -is [array]) {
                    $firstString = $foundIso | Where-Object { $_ -is [string] -and -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1
                    if ($firstString) {
                        $script:effectiveIsoPath = $firstString
                        Write-Information "Found original ISO: $script:effectiveIsoPath" -InformationAction Continue
                    }
                }
                
                # If still no ISO found, show helpful error message
                if ($null -eq $script:effectiveIsoPath) {
                    throw "Original ISO path is required to create custom ISO. Please provide -IsoPath with the original Windows Server $WindowsVersion ISO."
                }
            }
            
            Write-WorkflowProgress -Activity "Golden Image Build" -Status "Creating custom Windows ISO with fresh passwords embedded in autounattend.xml..." -PercentComplete 22
            New-CustomIso -SourceIsoPath $script:effectiveIsoPath -OutputIsoPath $customIsoPath -UnattendXmlPath $customAutounattendPath
        }
        
        # Execute Packer build, go touch some grass while we wait
        Write-WorkflowProgress -Activity "Golden Image Build" -Status "Starting Packer build (this may take 30-60 minutes)..." -PercentComplete 30
        Write-Information "Beginning Packer build process..." -InformationAction Continue
        Write-Information "Expected duration: 30-60 minutes depending on system performance" -InformationAction Continue
        Write-Host ""
        Write-Host "⚠️  CONSOLE ACCESS WARNING:" -ForegroundColor Yellow
        Write-Host "   Do NOT connect to the VM console during the automated build process!" -ForegroundColor Red
        Write-Host "   This could interfere with autounattend.xml processing and Packer scripts." -ForegroundColor Red
        Write-Host "   Monitor progress through this script output and packer-build.log instead." -ForegroundColor Yellow
        Write-Host ""
        
        $buildDuration = Invoke-PackerBuild -CustomIsoPath $customIsoPath -PackerConfigPath $packerConfigPath -PackerWorkingDir $packerDir -OutputDirectory $versionPaths.OutputDir
        
        Write-Information "Packer build completed successfully in $($buildDuration.ToString('hh\:mm\:ss'))" -InformationAction Continue
        Write-Host ""
        Write-Host "✅ CONSOLE SAFE:" -ForegroundColor Green
        Write-Host "   Packer build completed - VM console connection is now safe" -ForegroundColor Green
        Write-Host "   (though the VM is currently powered off for packaging)" -ForegroundColor White
        Write-Host ""
        
        # Package as Vagrant box
        Write-WorkflowProgress -Activity "Golden Image Build" -Status "Packaging as Vagrant box..." -PercentComplete 85
        $packerOutputDir = $versionPaths.OutputDir
        
        # Use version-specific box name if not overridden
        $effectiveBoxName = if ($BoxName) { $BoxName } else { $versionPaths.BoxName }
        
        # Remove existing box if Force is specified
        if ($script:forceRebuild -or $Force) {
            try {
                Write-Information "Removing existing Vagrant box: $effectiveBoxName" -InformationAction Continue
                $removeProcess = Start-Process -FilePath "vagrant" -ArgumentList @('box', 'remove', $effectiveBoxName, '--provider', 'hyperv', '--force') -PassThru -WindowStyle Hidden -Wait
                try {
                    $removeProcess.WaitForExit()
                    Write-Information "Existing box removed successfully" -InformationAction Continue
                }
                finally {
                    if ($removeProcess) {
                        $removeProcess.Dispose()
                        $removeProcess = $null
                    }
                }
            }
            catch {
                Write-Verbose "No existing box to remove or removal failed: $($_.Exception.Message)"
            }
        }
        
        # Fixed: Pass the generated password to box creation
        New-VagrantBoxFromPacker -BoxName $effectiveBoxName -PackerOutputDirectory $packerOutputDir -VagrantBoxDirectory $boxesStorageDir -VagrantPasswordSecure $vagrantPasswordSecure
        
        # Save credentials to file AFTER successful build
        Write-WorkflowProgress -Activity "Golden Image Build" -Status "Saving build credentials..." -PercentComplete 90
        Save-BuildCredentials -AdminPasswordSecure $adminPasswordSecure -VagrantPasswordSecure $vagrantPasswordSecure -OutputPath $credentialsPath -WindowsVersion $WindowsVersion
        Write-Information "Build credentials saved to: $credentialsPath" -InformationAction Continue
        
        # Cleanup temporary files
        Write-WorkflowProgress -Activity "Golden Image Build" -Status "Cleaning up temporary files..." -PercentComplete 95
        
        # Clean up the custom ISO since it contains passwords
        Write-Information "Removing custom ISO with embedded passwords for security: $customIsoPath" -InformationAction Continue
        try {
            Remove-Item $customIsoPath -Force
            Write-Information "Custom ISO cleaned up successfully - will be recreated or updated on next run" -InformationAction Continue
        }
        catch {
            Write-Warning "Could not clean up custom ISO: $($_.Exception.Message)"
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
        if ($buildDuration) {
            Write-Host "  Packer build time: $($buildDuration.ToString('hh\:mm\:ss'))" -ForegroundColor White
        }
        Write-Host "  Box name: $effectiveBoxName" -ForegroundColor White
        Write-Host "  Windows version: Server $WindowsVersion" -ForegroundColor White
        Write-Host "  Built on: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor White
        Write-Host "  Next build needed after: $($nextBuildDate.ToString('yyyy-MM-dd'))" -ForegroundColor White
        Write-Host "  Storage location: $script:storageRoot" -ForegroundColor White
        Write-Host ""
        Write-Host "✅ VM Console Access:" -ForegroundColor Green
        Write-Host "   Safe to connect to VM console after starting with 'vagrant up'" -ForegroundColor Green
        Write-Host "   Check credentials in: $credentialsPath" -ForegroundColor White
        Write-Host ""
        
        # Security reminder
        Write-Host "Security Notes:" -ForegroundColor Yellow
        Write-Host "  ✓ Fresh random passwords were generated and injected for this build" -ForegroundColor White
        Write-Host "  ✓ Credentials are saved in $credentialsPath" -ForegroundColor White
        Write-Host "  ✓ Custom ISO with embedded passwords was cleaned up for security" -ForegroundColor White
        Write-Host "  ✓ Next build will efficiently update passwords without recreating entire ISO" -ForegroundColor White
        Write-Host "  ! Please secure or delete credential files after noting passwords" -ForegroundColor White
        Write-Host "  ! Each build injects fresh passwords for maximum security" -ForegroundColor White
        Write-Host ""
        
        # Show deployment options
        Show-DeploymentInstructions
        
        # Clear large variables
        $buildDuration = $null
        $versionPaths = $null
        $packerOutputDir = $null
        
    }
    catch {
        Write-Progress -Activity "Golden Image Build" -Completed
        Write-Host ("=" * 70) -ForegroundColor Red
        Write-Host "Golden Image Build Failed!" -ForegroundColor Red
        Write-Host ("=" * 70) -ForegroundColor Red
        Write-Host ""
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host ""
        Write-Host "Troubleshooting steps:" -ForegroundColor Yellow
        Write-Host "  1. Check the Packer log file for detailed error information" -ForegroundColor White
        Write-Host "  2. Ensure there is not a VM with a conflicting name." -ForegroundColor White
        Write-Host "  3. Ensure sufficient disk space at: $script:storageRoot" -ForegroundColor White
        Write-Host "  4. Verify the source ISO file exists and can be mounted" -ForegroundColor White
        Write-Host "  5. Check that the ISO contains the autounattend." -ForegroundColor White
        Write-Host ""
        throw
    }
    finally {
        # Secure cleanup of password variables
        if ($adminPasswordSecure) {
            $adminPasswordSecure.Dispose()
            $adminPasswordSecure = $null
        }
        if ($vagrantPasswordSecure) {
            $vagrantPasswordSecure.Dispose()
            $vagrantPasswordSecure = $null
        }
        if ($script:generatedVagrantPassword) {
            $script:generatedVagrantPassword.Dispose()
            $script:generatedVagrantPassword = $null
        }
        
        # Single garbage collection
        [System.GC]::Collect()
        
        Write-Verbose "Secure password cleanup completed"
    }
}

function Invoke-CustomIsoCreation {
    <#
    .SYNOPSIS
        Creates a custom Windows Server ISO with autounattend.xml as a standalone operation with secure password handling
    .DESCRIPTION
        This function creates a custom bootable ISO with embedded autounattend.xml that can be preserved
        between script runs. Uses secure password generation and handling throughout the process.
    #>
    [CmdletBinding()]
    param()
    
    
    # Secure password variables
    $adminPasswordSecure = $null
    $vagrantPasswordSecure = $null
    
    try {
        Write-Host ("=" * 70) -ForegroundColor Cyan
        Write-Host "Creating Custom Windows Server $WindowsVersion ISO" -ForegroundColor Cyan
        Write-Host ("=" * 70) -ForegroundColor Cyan
        Write-Host ""
        
        # Clean up any leftover artifacts from previous runs
        Clear-PreviousRunArtifacts
        
        # Validate ISO path
        if ($null -eq $script:effectiveIsoPath -or [string]::IsNullOrWhiteSpace($script:effectiveIsoPath)) {
            throw "Original ISO path is required for creating a custom ISO. Please specify -IsoPath with the original Windows Server $WindowsVersion ISO."
        }

        Test-IsoFile -Path $script:effectiveIsoPath
        
        # Get project paths
        $projectRoot = Split-Path $PSScriptRoot -Parent
        $packerDir = Join-Path $projectRoot "packer"
        
        # Use E: drive for storage (consistent with main build)
        $storageRoot = "E:\vm_images"
        $packerStorageDir = Join-Path $storageRoot "packer"
        
        # Get version-specific paths
        $versionPaths = Get-VersionSpecificPaths -WindowsVersion $WindowsVersion -PackerDir $packerDir
        
        # Ensure storage directory exists
        if (-not (Test-Path $packerStorageDir)) {
            Write-Host "Creating directory: $packerStorageDir" -ForegroundColor Yellow
            $null = New-Item -ItemType Directory -Path $packerStorageDir -Force
        }
        
        # Prepare file paths
        $unattendXmlPath = $versionPaths.AutoUnattend
        $customIsoPath = Join-Path $packerStorageDir $versionPaths.CustomIsoName
        
        # Validate required files exist
        if (-not (Test-Path $unattendXmlPath)) {
            throw "Required template file not found: $unattendXmlPath"
        }
        
        # Check if custom ISO already exists and offer to recreate BEFORE generating passwords
        if (Test-Path $customIsoPath) {
            Write-Host "Existing custom ISO found: $customIsoPath" -ForegroundColor Yellow
            $response = Read-Host "Do you want to recreate the iso? (y/N)"
            if ($response -notmatch '^[Yy]') {
                Write-Host "Using existing custom ISO." -ForegroundColor Green
                Write-Warning "Note: Existing ISO may not contain newly generated passwords."
                return $customIsoPath
            }
            
            Write-Host "Removing existing custom ISO..." -ForegroundColor Yellow
            Remove-Item $customIsoPath -Force
        }
        
        # Generate secure random passwords
        Write-WorkflowProgress -Activity "Custom ISO Creation" -Status "Generating secure passwords..." -PercentComplete 10
        Write-Information "Generating secure random passwords for Administrator and vagrant accounts..." -InformationAction Continue
        
        try {
            $adminPasswordSecure = New-RandomSecurePassword
            $vagrantPasswordSecure = New-RandomSecurePassword
            
            Write-Information "Passwords generated securely using pgen.exe" -InformationAction Continue
        } 
        catch {
            Write-Error "Failed to generate secure passwords: $($_.Exception.Message)"
            throw
        }
        
        # Save credentials to file
        Write-WorkflowProgress -Activity "Custom ISO Creation" -Status "Saving build credentials..." -PercentComplete 15
        $isoDir = Split-Path $customIsoPath -Parent
        $credentialsPath = Join-Path $isoDir "windows-server-$WindowsVersion-credentials.json"
        Save-BuildCredentials -AdminPasswordSecure $adminPasswordSecure -VagrantPasswordSecure $vagrantPasswordSecure -OutputPath $credentialsPath -WindowsVersion $WindowsVersion
        
        # Create customized autounattend.xml with generated passwords
        Write-WorkflowProgress -Activity "Custom ISO Creation" -Status "Creating customized autounattend.xml..." -PercentComplete 20
        
        $customAutounattendPath = $unattendXmlPath -replace '\.xml$', "-temp-$(Get-Random).xml"
        New-CustomAutounattendXml -TemplateXmlPath $unattendXmlPath -OutputXmlPath $customAutounattendPath -AdminPasswordSecure $adminPasswordSecure -VagrantPasswordSecure $vagrantPasswordSecure -WindowsVersion $WindowsVersion
        
        # Create custom ISO with autounattend.xml
        Write-Host "Creating custom Windows ISO from: $script:effectiveIsoPath" -ForegroundColor Green
        Write-Host "Output location: $customIsoPath" -ForegroundColor Green
        Write-Host ""
        
        New-CustomIso -SourceIsoPath $script:effectiveIsoPath -OutputIsoPath $customIsoPath -UnattendXmlPath $customAutounattendPath
        
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
            Write-Host "  Windows Version: Server $WindowsVersion" -ForegroundColor White
            Write-Host "  Created: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor White
            Write-Host ""
            Write-Host "Security Notes:" -ForegroundColor Yellow
            Write-Host "  • Administrator and vagrant accounts have random passwords" -ForegroundColor White
            Write-Host "  • Credentials are saved to $credentialsPath" -ForegroundColor White
            Write-Host "  • Please secure or delete credential files after use" -ForegroundColor White
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
        Write-Host ""
        Write-Host "Troubleshooting steps:" -ForegroundColor Yellow
        Write-Host "  1. Verify the source ISO file is valid and accessible" -ForegroundColor White
        Write-Host "  2. Ensure sufficient disk space on E: drive" -ForegroundColor White
        Write-Host "  3. Check that Windows ADK (oscdimg.exe) is installed" -ForegroundColor White
        Write-Host "  4. Verify pgen.exe is installed and accessible" -ForegroundColor White
        Write-Host "  5. Run as Administrator if permission issues occur" -ForegroundColor White
        throw
    }
    finally {
        # Secure cleanup of password variables
        if ($adminPasswordSecure) {
            $adminPasswordSecure.Dispose()
            $adminPasswordSecure = $null
        }
        if ($vagrantPasswordSecure) {
            $vagrantPasswordSecure.Dispose()
            $vagrantPasswordSecure = $null
        }
        
        # Force garbage collection
        [System.GC]::Collect()
        
        Write-Verbose "Secure cleanup completed"
        
        # Clear variables
        $versionPaths = $null
    }
}

function Update-CustomIsoPasswords {
    <#
    .SYNOPSIS
        Updates an existing custom ISO with fresh passwords by replacing the autounattend.xml file
    
    .DESCRIPTION
        This function efficiently updates passwords in an existing custom ISO by:
        1. Mounting the existing custom ISO
        2. Copying its contents to a temporary directory
        3. Replacing the autounattend.xml with a new one containing fresh passwords
        4. Recreating the ISO with the updated contents
        
        This approach is much faster than recreating the entire ISO from the original source.
        
    .PARAMETER CustomIsoPath
        Path to the existing custom ISO to update
        
    .PARAMETER UnattendXmlPath
        Path to the new autounattend.xml file containing fresh passwords
        
    .EXAMPLE
        Update-CustomIsoPasswords -CustomIsoPath "C:\ISOs\Custom_WinServer_2019.iso" -UnattendXmlPath "C:\autounattend-temp-123.xml"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$CustomIsoPath,
        
        [Parameter(Mandatory)]
        [string]$UnattendXmlPath
    )
    
    # Always use E: drive for temporary files to avoid filling C: drive
    $tempBase = "E:\Temp"
    if (-not (Test-Path $tempBase)) {
        New-Item -ItemType Directory -Path $tempBase -Force | Out-Null
    }
    $workingDir = Join-Path $tempBase "updateiso_$(Get-Random)"
    $mount = $null
    $tempIsoPath = "$CustomIsoPath.tmp"
    
    try {
        Write-Information "Updating custom ISO with fresh passwords: $CustomIsoPath" -InformationAction Continue
        
        New-Item -ItemType Directory -Path $workingDir -Force | Out-Null
        
        # Validate source files
        @($CustomIsoPath, $UnattendXmlPath) | ForEach-Object {
            if (-not (Test-Path $_)) {
                throw "Required file not found: $_"
            }
        }
        
        # Mount existing custom ISO
        Write-Information "Mounting existing custom ISO..." -InformationAction Continue
        $mount = Mount-DiskImage -ImagePath $CustomIsoPath -PassThru -ErrorAction Stop
        $driveLetter = ($mount | Get-Volume).DriveLetter + ":"
        $volumeLabel = (Get-Volume -DriveLetter $driveLetter.TrimEnd(':')).FileSystemLabel
        
        if (-not $volumeLabel) { 
            $volumeLabel = "CCSEVAL_X64FRE_EN-US_DV9" 
        }
        
        Write-Information "Copying existing ISO contents..." -InformationAction Continue
        
        # Use robocopy for more efficient copying of large ISO contents
        $robocopyArgs = @(
            "$driveLetter\",
            $workingDir,
            "/E",
            "/R:1",
            "/W:1",
            "/NP"
        )
        
        $robocopyProcess = Start-Process -FilePath "robocopy" -ArgumentList $robocopyArgs -PassThru -WindowStyle Hidden -Wait
        # Robocopy exit codes 0-7 are success
        if ($robocopyProcess.ExitCode -gt 7) {
            Write-Warning "Robocopy completed with warnings (exit code: $($robocopyProcess.ExitCode))"
        }
        
        # Dispose of process object
        if ($robocopyProcess) {
            $robocopyProcess.Dispose()
            $robocopyProcess = $null
        }
        
        # Replace autounattend.xml with the new one containing fresh passwords
        Write-Information "Updating autounattend.xml with fresh passwords..." -InformationAction Continue
        $autounattendDestination = Join-Path $workingDir "autounattend.xml"
        Copy-Item $UnattendXmlPath $autounattendDestination -Force
        Write-Information "Updated autounattend.xml with fresh passwords from: $UnattendXmlPath" -InformationAction Continue
        
        # Create updated ISO
        Write-Information "Building updated ISO with fresh passwords..." -InformationAction Continue
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
        
        $oscdimgArgs += @($workingDir, $tempIsoPath)
        
        $oscdimgProcess = Start-Process -FilePath $oscdimgPath -ArgumentList $oscdimgArgs -PassThru -WindowStyle Hidden -Wait
        
        try {
            $oscdimgProcess.WaitForExit()
            $exitCode = $oscdimgProcess.ExitCode
            
            if ($exitCode -ne 0) {
                throw "oscdimg failed with exit code: $exitCode"
            }
        }
        finally {
            if ($oscdimgProcess) {
                $oscdimgProcess.Dispose()
                $oscdimgProcess = $null
            }
        }
        
        # Replace the original custom ISO with the updated one
        Write-Information "Replacing original custom ISO with updated version..." -InformationAction Continue
        Move-Item $tempIsoPath $CustomIsoPath -Force
        
        Write-Information "Custom ISO successfully updated with fresh passwords: $CustomIsoPath" -InformationAction Continue
        
    }
    finally {
        # Proper cleanup of mounted ISO
        if ($mount) {
            try {
                Dismount-DiskImage -ImagePath $CustomIsoPath -ErrorAction SilentlyContinue
                Write-Information "Dismounted custom ISO" -InformationAction Continue
            }
            catch {
                Write-Warning "Could not dismount custom ISO: $($_.Exception.Message)"
            }
        }
        
        if (Test-Path $workingDir) {
            Remove-Item $workingDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        
        # Clean up temp ISO if it exists
        if (Test-Path $tempIsoPath) {
            Remove-Item $tempIsoPath -Force -ErrorAction SilentlyContinue
        }
        
        # Clear variables to free memory
        $mount = $null
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
        [string]$PackerDir,
        
        [Parameter()]
        [string]$StorageRoot
    )
    
    $versionPaths = @{
        '2019' = @{
            PackerConfig = Join-Path $PackerDir "windows-server-2019.pkr.hcl"
            AutoUnattend = Join-Path $PackerDir "autounattend-2019.xml"
            CustomIsoName = "custom_windows_server_2019.iso"
            BoxName = "windows-server-2019-golden"
            OutputDir = if ($StorageRoot) { Join-Path $StorageRoot "packer\output-hyperv-iso-2019" } else { "E:\packer\output-hyperv-iso-2019" }
        }
        '2025' = @{
            PackerConfig = Join-Path $PackerDir "windows-server-2025.pkr.hcl"
            AutoUnattend = Join-Path $PackerDir "autounattend-2025.xml"
            CustomIsoName = "custom_windows_server_2025.iso"
            BoxName = "windows-server-2025-golden"
            OutputDir = if ($StorageRoot) { Join-Path $StorageRoot "packer\output-hyperv-iso" } else { "E:\packer\output-hyperv-iso" }
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
    
    # Determine storage root
    $script:storageRoot = Get-OptimalStoragePath
    
    # Find ISO path - check for existing custom ISO first
    $packerStorageDir = Join-Path $script:storageRoot "packer"
    $existingCustomIsoPath = Join-Path $packerStorageDir $versionPaths.CustomIsoName
    
    if ($PSBoundParameters.ContainsKey('IsoPath')) {
        # User provided ISO path - validate and use it to create custom ISO
        if ($null -eq $IsoPath -or $IsoPath -isnot [string] -or [string]::IsNullOrWhiteSpace($IsoPath)) {
            throw "You must provide a valid string path for -IsoPath. Example: -IsoPath 'F:\\Install\\Microsoft\\Windows Server\\WinServer_2025.iso'"
        }
        $script:effectiveIsoPath = ConvertTo-AbsolutePath -Path $IsoPath
        Write-Information "Using provided ISO path to create custom ISO: $($script:effectiveIsoPath)" -InformationAction Continue
        
        # Force creation of custom ISO from provided path (even if one already exists)
        $script:createCustomIso = $true
    }
    elseif (Test-Path $existingCustomIsoPath) {
        # Custom ISO already exists for this version - use it directly
        $script:effectiveIsoPath = $null  # Not needed since we'll use existing custom ISO
        Write-Information "Found existing custom ISO for Windows Server $WindowsVersion - using existing custom ISO" -InformationAction Continue
        Write-Information "Custom ISO: $existingCustomIsoPath" -InformationAction Continue
        $script:createCustomIso = $false
    }
    else {
        # No custom ISO exists and no ISO provided - try to find one for this version
        Write-Information "No custom ISO found for Windows Server $WindowsVersion, searching for original ISO..." -InformationAction Continue
        $foundIso = Find-WindowsServerIso
        if ($foundIso -is [string] -and -not [string]::IsNullOrWhiteSpace($foundIso)) {
            $script:effectiveIsoPath = $foundIso
            Write-Information "Auto-detected ISO for Windows Server $WindowsVersion`: $($script:effectiveIsoPath)" -InformationAction Continue
            $script:createCustomIso = $true
        }
        elseif ($foundIso -is [array]) {
            # Defensive: If Find-WindowsServerIso ever returns an array, pick the first valid string
            $firstString = $foundIso | Where-Object { $_ -is [string] -and -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1
            if ($firstString) {
                $script:effectiveIsoPath = $firstString
                Write-Information "Auto-detected ISO for Windows Server $WindowsVersion`: $($script:effectiveIsoPath)" -InformationAction Continue
                $script:createCustomIso = $true
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
} # End of main try block

catch {
    Write-Error $_.Exception.Message
    exit 1
}

finally {
    Stop-WorkflowLogging
    
    # Clear major variables for final cleanup
    $config = $null
    $versionPaths = $null
    $foundIso = $null
    
    # Final garbage collection
    [System.GC]::Collect()
}
#endregion