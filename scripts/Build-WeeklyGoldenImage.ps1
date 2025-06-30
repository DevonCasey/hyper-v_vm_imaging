<#
.SYNOPSIS
    Weekly Golden Image Build Script for Windows Server 2022

.DESCRIPTION
    Automates the creation of Windows Server 2022 golden images using Packer and Vagrant.
    Includes automatic ISO preparation with unattended installation configuration.

.PARAMETER BoxName
    Name of the Vagrant box to create (default: windows-server-2022-golden)

.PARAMETER IsoPath
    Path to the Windows Server 2022 ISO file

.PARAMETER ConfigPath
    Path to configuration file (JSON format)

.PARAMETER Force
    Force rebuild even if the image is recent

.PARAMETER ScheduleWeekly
    Create a Windows scheduled task for weekly builds

.PARAMETER CheckOnly
    Only check if rebuild is needed (returns exit code)

.PARAMETER DaysBeforeRebuild
    Number of days before forcing a rebuild (default: 7)

.EXAMPLE
    .\Build-WeeklyGoldenImage.ps1
    Build with default settings

.EXAMPLE
    .\Build-WeeklyGoldenImage.ps1 -Force
    Force rebuild

.EXAMPLE
    .\Build-WeeklyGoldenImage.ps1 -ConfigPath ".\config.json"
    Use external configuration file
#>

[CmdletBinding(DefaultParameterSetName = 'Build')]
param(
    [Parameter(ParameterSetName = 'Build')]
    [Parameter(ParameterSetName = 'Check')]
    [string]$BoxName = "windows-server-2022-golden",
    
    [Parameter(ParameterSetName = 'Build')]
    [ValidateScript({
            if (Test-Path $_ -PathType Leaf) { $true }
            else { throw "ISO file not found: $_" }
        })]
    [string]$IsoPath = "F:\Install\Microsoft\Windows Server\WinServer_2022.iso",
    
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
    [int]$DaysBeforeRebuild = 7
)

# Script configuration with defaults
$script:Config = @{
    LogDirectory        = "C:\logs"
    TempDirectory       = $env:TEMP
    MaxLogAgeDays       = 30
    BuildTimeoutMinutes = 240
    RetryAttempts       = 3
    OscdimgPath         = $null
}

# Script-level variables
$script:LogPath = $null
$script:TranscriptStarted = $false

#region Logging Functions
function Initialize-Logging {
    [CmdletBinding()]
    param()
    
    try {
        if (-not (Test-Path $script:Config.LogDirectory)) {
            $null = New-Item -ItemType Directory -Path $script:Config.LogDirectory -Force
        }
        
        $timestamp = Get-Date -Format 'yyyy-MM-dd'
        $scriptName = [System.IO.Path]::GetFileNameWithoutExtension($MyInvocation.ScriptName)
        $script:LogPath = Join-Path $script:Config.LogDirectory "${scriptName}_${timestamp}.log"
        
        Start-Transcript -Path $script:LogPath -Force
        $script:TranscriptStarted = $true
        
        Write-Information "Logging initialized: $script:LogPath" -InformationAction Continue
        
        # Clean old logs
        Get-ChildItem $script:Config.LogDirectory -Filter "*.log" -ErrorAction SilentlyContinue | 
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$script:Config.MaxLogAgeDays) } |
        Remove-Item -Force -ErrorAction SilentlyContinue
    }
    catch {
        Write-Warning "Failed to initialize logging: $($_.Exception.Message)"
    }
}

function Stop-Logging {
    [CmdletBinding()]
    param()
    
    if ($script:TranscriptStarted) {
        try {
            Stop-Transcript
            $script:TranscriptStarted = $false
        }
        catch {
            Write-Warning "Failed to stop transcript: $($_.Exception.Message)"
        }
    }
}
#endregion

#region Configuration Functions
function Import-Configuration {
    [CmdletBinding()]
    param([string]$Path)

    if (-not $Path -or -not (Test-Path $Path)) {
        Write-Verbose "No configuration file specified or found, using defaults"
        return
    }
    
    try {
        $configData = Get-Content $Path -Raw | ConvertFrom-Json
        
        # Merge with default configuration
        foreach ($property in $configData.PSObject.Properties) {
            $script:Config[$property.Name] = $property.Value
        }
        
        Write-Information "Configuration loaded from: $Path" -InformationAction Continue
    }
    catch {
        Write-Warning "Failed to load configuration file: $($_.Exception.Message)"
    }
}
#endregion

#region Prerequisites Functions
function Test-Prerequisites {
    [CmdletBinding()]
    param()
    
    $missing = @()
    
    # Check for required tools
    $requiredTools = @(
        @{ Name = 'packer'; Command = 'packer version' },
        @{ Name = 'vagrant'; Command = 'vagrant --version' }
    )
    
    foreach ($tool in $requiredTools) {
        try {
            $null = Invoke-Expression $tool.Command 2>$null
            Write-Verbose "$($tool.Name) found"
        }
        catch {
            $missing += $tool.Name
        }
    }
    
    # Find oscdimg.exe
    $oscdimgPaths = @(
        "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe",
        "${env:ProgramFiles}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe"
    )
    
    $oscdimgFound = $false
    foreach ($path in $oscdimgPaths) {
        if (Test-Path $path) {
            $script:Config.OscdimgPath = $path
            $oscdimgDir = Split-Path $path -Parent
            
            if ($env:PATH -notlike "*$oscdimgDir*") {
                $env:PATH += ";$oscdimgDir"
            }
            
            $oscdimgFound = $true
            Write-Verbose "oscdimg.exe found at: $path"
            break
        }
    }
    
    if (-not $oscdimgFound) {
        $missing += 'oscdimg.exe (Windows ADK)'
    }
    
    if ($missing.Count -gt 0) {
        throw "Missing required tools: $($missing -join ', ')"
    }
    
    Write-Information "All prerequisites validated successfully" -InformationAction Continue
}

#region ISO Functions (Updated with Null Checking)
function Test-IsoFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )
    
    Write-Information "Validating ISO file: $Path" -InformationAction Continue
    
    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "ISO path is null or empty"
    }
    
    if (-not (Test-Path $Path)) {
        throw "ISO file not found at: $Path"
    }
    
    try {
        # Verify it's a valid ISO by attempting to mount it
        $mountResult = Mount-DiskImage -ImagePath $Path -PassThru -ErrorAction Stop
        $volume = $mountResult | Get-Volume -ErrorAction Stop
        $null = Dismount-DiskImage -ImagePath $Path -ErrorAction Stop
        
        Write-Information "ISO validated successfully: $Path" -InformationAction Continue
        return $true
    }
    catch {
        throw "Invalid or corrupted ISO file: $($_.Exception.Message)"
    }
}
#endregion

#region Main Functions (Updated with Better Error Handling)
function Invoke-GoldenImageBuild {
    [CmdletBinding()]
    param()
    
    try {
        Write-Host "=== Weekly Golden Image Build Process ===" -ForegroundColor Green
        Write-Host "Building Windows Server 2022 golden image..." -ForegroundColor Yellow
        
        # Debug: Show all script-level variables
        Write-Host "`n=== Debug Information ===" -ForegroundColor Cyan
        Write-Host "BoxName: '$BoxName'" -ForegroundColor Gray
        Write-Host "IsoPath: '$IsoPath'" -ForegroundColor Gray
        Write-Host "PSScriptRoot: '$PSScriptRoot'" -ForegroundColor Gray
        Write-Host "Current Location: '$(Get-Location)'" -ForegroundColor Gray
        
        # Validate required variables are not null
        if ([string]::IsNullOrWhiteSpace($BoxName)) {
            throw "BoxName parameter is null or empty"
        }
        
        if ([string]::IsNullOrWhiteSpace($IsoPath)) {
            throw "IsoPath parameter is null or empty. Please specify the path to Windows Server 2022 ISO file."
        }
        
        Write-Host "Box Name: $BoxName"
        Write-Host "ISO Path: $IsoPath"
        Write-Host "Started: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        
        $buildStartTime = Get-Date
        
        # Get absolute paths for all project directories
        if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) {
            throw "PSScriptRoot is null - cannot determine project structure"
        }
        
        $projectRoot = Split-Path $PSScriptRoot -Parent
        $packerDir = Join-Path $projectRoot "packer"
        $scriptsDir = Join-Path $projectRoot "scripts"
        $vagrantDir = Join-Path $projectRoot "vagrant"
        $boxesDir = Join-Path $projectRoot "boxes"
        
        Write-Information "Project root: $projectRoot" -InformationAction Continue
        Write-Information "Packer directory: $packerDir" -InformationAction Continue
        
        # Validate project structure
        if (-not (Test-Path $projectRoot)) {
            throw "Project root directory not found: $projectRoot"
        }
        if (-not (Test-Path $packerDir)) {
            throw "Packer directory not found: $packerDir"
        }
        
        # Test prerequisites
        Test-Prerequisites
        
        # Validate and convert to absolute path for ISO
        Write-Information "Converting ISO path to absolute..." -InformationAction Continue
        if ([string]::IsNullOrWhiteSpace($IsoPath)) {
            throw "IsoPath is null or empty"
        }
        
        $absoluteIsoPath = if ([System.IO.Path]::IsPathRooted($IsoPath)) { 
            $IsoPath 
        }
        else { 
            $resolvedPath = Join-Path $PWD $IsoPath
            Write-Information "Resolved relative path '$IsoPath' to '$resolvedPath'" -InformationAction Continue
            $resolvedPath
        }
        
        Write-Information "Using absolute ISO path: $absoluteIsoPath" -InformationAction Continue
        
        # Validate the ISO file exists and is valid
        if ([string]::IsNullOrWhiteSpace($absoluteIsoPath)) {
            throw "Absolute ISO path is null or empty after resolution"
        }
        
        Test-IsoFile -Path $absoluteIsoPath
        
        # Check if rebuild is needed
        if (-not $Force) {
            $needsRebuild = Test-BoxAge -BoxName $BoxName -MaxAgeDays $DaysBeforeRebuild
            if (-not $needsRebuild) {
                Write-Host "Golden image is still fresh. Use -Force to rebuild anyway." -ForegroundColor Green
                return
            }
        }
        
        # Prepare absolute paths for all files
        $unattendXmlPath = Join-Path $packerDir "autounattend.xml"
        $packerConfigPath = Join-Path $packerDir "windows-server-2022.pkr.hcl"
        $customIsoPath = Join-Path $packerDir "custom_windows_server_2022.iso"
        
        Write-Information "Unattend XML path: $unattendXmlPath" -InformationAction Continue
        Write-Information "Packer config path: $packerConfigPath" -InformationAction Continue
        Write-Information "Custom ISO path: $customIsoPath" -InformationAction Continue
        
        # Validate required files exist
        if (-not (Test-Path $unattendXmlPath)) {
            throw "Unattend XML file not found: $unattendXmlPath"
        }
        if (-not (Test-Path $packerConfigPath)) {
            throw "Packer configuration file not found: $packerConfigPath"
        }
        
        # Create boxes directory if it doesn't exist
        if (-not (Test-Path $boxesDir)) {
            Write-Information "Creating boxes directory: $boxesDir" -InformationAction Continue
            $null = New-Item -ItemType Directory -Path $boxesDir -Force
        }
        
        # Remove existing custom ISO
        if (Test-Path $customIsoPath) {
            Write-Information "Removing existing custom ISO: $customIsoPath" -InformationAction Continue
            Remove-Item $customIsoPath -Force
        }
        
        # Create custom ISO with autounattend.xml embedded
        Write-Information "Creating custom Windows ISO with embedded autounattend.xml..." -InformationAction Continue
        New-CustomIso -SourceIsoPath $absoluteIsoPath -OutputIsoPath $customIsoPath -UnattendXmlPath $unattendXmlPath
        
        # Execute Packer build with absolute paths
        Write-Information "Starting Packer build..." -InformationAction Continue
        $null = Invoke-PackerBuild -CustomIsoPath $customIsoPath -PackerConfigPath $packerConfigPath -PackerWorkingDir $packerDir
        
        # Package as Vagrant box
        Write-Information "Packaging as Vagrant box..." -InformationAction Continue
        $boxScriptPath = Join-Path $scriptsDir "New-VagrantBox.ps1"
        $packerOutputDir = Join-Path $packerDir "output-hyperv-iso"
        
        if ($Force) {
            try {
                & vagrant box remove $BoxName --provider hyperv --force 2>$null
                Write-Information "Removed existing box: $BoxName" -InformationAction Continue
            }
            catch {
                Write-Verbose "No existing box to remove"
            }
        }
        
        if (Test-Path $boxScriptPath) {
            $boxArgs = @{
                BoxName               = $BoxName
                PackerOutputDirectory = $packerOutputDir
                VagrantBoxDirectory   = $boxesDir
            }
            
            & $boxScriptPath @boxArgs
        }
        else {
            Write-Warning "Box packaging script not found: $boxScriptPath"
        }
        
        # Clean up temporary files
        Write-Information "Cleaning up temporary files..." -InformationAction Continue
        if (Test-Path $customIsoPath) {
            Remove-Item $customIsoPath -Force -ErrorAction SilentlyContinue
        }
        
        # Final summary
        $totalDuration = (Get-Date) - $buildStartTime
        $nextBuildDate = (Get-Date).AddDays($DaysBeforeRebuild)
        
        Write-Host "`n=== Golden Image Build Complete ===" -ForegroundColor Green
        Write-Host "Total time: $($totalDuration.ToString('hh\:mm\:ss'))"
        Write-Host "Box name: $BoxName"
        Write-Host "Built on: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        Write-Host "Next build needed after: $($nextBuildDate.ToString('yyyy-MM-dd'))"
        
        # Display deployment instructions with absolute paths
        Write-Host "`nYou can now deploy VMs using:" -ForegroundColor Yellow
        $environments = @("barebones", "fileserver", "dev-box", "domain-controller", "iis-server")
        foreach ($env in $environments) {
            $envPath = Join-Path $vagrantDir $env
            Write-Host "  Set-Location '$envPath'; vagrant up --provider=hyperv" -ForegroundColor White
        }
        
        # Check for running VMs
        $runningVMs = Get-RunningVagrantVMs -VagrantBaseDir $vagrantDir
        if ($runningVMs.Count -gt 0) {
            Write-Host "`nWARNING: The following VMs are running with the old golden image:" -ForegroundColor Yellow
            $runningVMs | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
            Write-Host "Consider recreating them to use the new golden image:" -ForegroundColor Yellow
            $runningVMs | ForEach-Object {
                $envPath = Join-Path $vagrantDir $_
                Write-Host "  Set-Location '$envPath'; vagrant destroy -f; vagrant up --provider=hyperv" -ForegroundColor White
            }
        }
        else {
            Write-Host "No running VMs detected - all future VMs will use the new golden image" -ForegroundColor Green
        }
    }
    catch {
        Write-Error "Golden image build failed: $($_.Exception.Message)"
        Write-Host "`n=== Error Debug Information ===" -ForegroundColor Red
        Write-Host "Error Type: $($_.Exception.GetType().FullName)" -ForegroundColor Gray
        Write-Host "Error Message: $($_.Exception.Message)" -ForegroundColor Gray
        Write-Host "Stack Trace: $($_.ScriptStackTrace)" -ForegroundColor Gray
        throw
    }
}
#endregion

#region ISO Functions
function New-UnattendedISO {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$AutounattendPath,
        
        [Parameter(Mandatory)]
        [string]$OutputIsoPath,
        
        [Parameter()]
        [string]$ScriptsPath
    )
    
    $workingDir = Join-Path $script:Config.TempDirectory "unattend_iso_$(Get-Random)"
    
    try {
        Write-Information "Creating unattended installation ISO..." -InformationAction Continue
        
        # Create working directory
        $null = New-Item -ItemType Directory -Path $workingDir -Force
        
        # Copy autounattend.xml to root of working directory
        Copy-Item $AutounattendPath (Join-Path $workingDir "autounattend.xml") -Force
        Write-Information "Added autounattend.xml to ISO" -InformationAction Continue
        
        # Copy PowerShell scripts if they exist
        if ($ScriptsPath -and (Test-Path $ScriptsPath)) {
            $scriptsDestination = Join-Path $workingDir "scripts"
            $null = New-Item -ItemType Directory -Path $scriptsDestination -Force
            Copy-Item "$ScriptsPath\*" $scriptsDestination -Recurse -Force
            Write-Information "Added scripts directory to ISO" -InformationAction Continue
        }
        
        # Create a simple ISO without boot requirements (it's just a data disc)
        $oscdimgArgs = @(
            '-n', # No optimization
            '-o', # Optimize storage by encoding duplicate files only once
            '-m', # Ignore maximum size limit
            "-l`"UNATTEND`"", # Volume label
            $workingDir, # Source directory
            $OutputIsoPath           # Output ISO path
        )
        
        Write-Information "Building unattended ISO with oscdimg..." -InformationAction Continue
        Write-Verbose "oscdimg command: $($script:Config.OscdimgPath) $($oscdimgArgs -join ' ')"
        
        & $script:Config.OscdimgPath @oscdimgArgs
        
        if ($LASTEXITCODE -ne 0) {
            throw "oscdimg failed with exit code: $LASTEXITCODE"
        }
        
        if (-not (Test-Path $OutputIsoPath)) {
            throw "Output ISO was not created: $OutputIsoPath"
        }
        
        # Verify the ISO was created properly
        try {
            $verifyMount = Mount-DiskImage -ImagePath $OutputIsoPath -PassThru -ErrorAction Stop
            $verifyDrive = ($verifyMount | Get-Volume).DriveLetter + ":"
            $autounattendExists = Test-Path "$verifyDrive\autounattend.xml"
            $null = Dismount-DiskImage -ImagePath $OutputIsoPath -ErrorAction Stop
            
            if (-not $autounattendExists) {
                throw "autounattend.xml not found in created ISO"
            }
            
            Write-Information "Unattended ISO created and verified successfully: $OutputIsoPath" -InformationAction Continue
        }
        catch {
            throw "Failed to verify created ISO: $($_.Exception.Message)"
        }
    }
    finally {
        if (Test-Path $workingDir) {
            Remove-Item $workingDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function New-CustomIso {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$SourceIsoPath,
        
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$OutputIsoPath,
        
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$UnattendXmlPath
    )
    
    Write-Information "New-CustomIso called with parameters:" -InformationAction Continue
    Write-Information "  SourceIsoPath: $SourceIsoPath" -InformationAction Continue
    Write-Information "  OutputIsoPath: $OutputIsoPath" -InformationAction Continue
    Write-Information "  UnattendXmlPath: $UnattendXmlPath" -InformationAction Continue
    
    # Validate parameters
    if ([string]::IsNullOrWhiteSpace($SourceIsoPath)) {
        throw "SourceIsoPath parameter is null or empty"
    }
    if ([string]::IsNullOrWhiteSpace($OutputIsoPath)) {
        throw "OutputIsoPath parameter is null or empty"
    }
    if ([string]::IsNullOrWhiteSpace($UnattendXmlPath)) {
        throw "UnattendXmlPath parameter is null or empty"
    }
    
    # Convert to absolute paths
    $absoluteSourceIsoPath = if ([System.IO.Path]::IsPathRooted($SourceIsoPath)) { 
        $SourceIsoPath 
    }
    else { 
        Join-Path $PWD $SourceIsoPath
    }
    
    $absoluteOutputIsoPath = if ([System.IO.Path]::IsPathRooted($OutputIsoPath)) { 
        $OutputIsoPath 
    }
    else { 
        Join-Path $PWD $OutputIsoPath
    }
    
    $absoluteUnattendXmlPath = if ([System.IO.Path]::IsPathRooted($UnattendXmlPath)) { 
        $UnattendXmlPath 
    }
    else { 
        Join-Path $PWD $UnattendXmlPath
    }
    
    Write-Information "Resolved absolute paths:" -InformationAction Continue
    Write-Information "  Source ISO: $absoluteSourceIsoPath" -InformationAction Continue
    Write-Information "  Output ISO: $absoluteOutputIsoPath" -InformationAction Continue
    Write-Information "  Unattend XML: $absoluteUnattendXmlPath" -InformationAction Continue
    
    # Set up working directory
    $tempBase = if ($script:Config.TempDirectory) { $script:Config.TempDirectory } else { $env:TEMP }
    $workingDir = Join-Path $tempBase "winiso_$(Get-Random)"
    Write-Information "Working directory: $workingDir" -InformationAction Continue
    
    try {
        Write-Information "Creating custom Windows ISO with embedded autounattend.xml" -InformationAction Continue
        
        # Create working directory
        New-Item -ItemType Directory -Path $workingDir -Force | Out-Null
        Write-Information "Created working directory" -InformationAction Continue
        
        # Validate source files exist
        if (-not (Test-Path $absoluteSourceIsoPath)) {
            throw "Source ISO not found: $absoluteSourceIsoPath"
        }
        if (-not (Test-Path $absoluteUnattendXmlPath)) {
            throw "Unattend XML not found: $absoluteUnattendXmlPath"
        }
        
        # Mount and copy source ISO
        Write-Information "Mounting source ISO" -InformationAction Continue
        $mount = Mount-DiskImage -ImagePath $absoluteSourceIsoPath -PassThru -ErrorAction Stop
        $driveLetter = ($mount | Get-Volume).DriveLetter + ":"
        $volumeLabel = (Get-Volume -DriveLetter $driveLetter.TrimEnd(':')).FileSystemLabel
        
        if (-not $volumeLabel) { 
            $volumeLabel = "CCSEVAL_X64FRE_EN-US_DV9" 
        }
        
        Write-Information "Copying ISO contents from $driveLetter" -InformationAction Continue
        Copy-Item "$driveLetter\*" $workingDir -Recurse -Force
        Dismount-DiskImage -ImagePath $absoluteSourceIsoPath | Out-Null
        Write-Information "ISO contents copied successfully" -InformationAction Continue

        # Add autounattend.xml to the ROOT of the ISO
        $autounattendDestination = Join-Path $workingDir "autounattend.xml"
        Write-Information "Copying autounattend.xml to ISO root" -InformationAction Continue
        Copy-Item $absoluteUnattendXmlPath $autounattendDestination -Force
        
        # Verify it was copied
        if (Test-Path $autounattendDestination) {
            Write-Information "Successfully added autounattend.xml to ISO root" -InformationAction Continue
        }
        else {
            throw "Failed to copy autounattend.xml to ISO root"
        }

        # Try to copy scripts directory
        $scriptsSource = $null
        if ($PSScriptRoot) {
            $projectRoot = Split-Path $PSScriptRoot -Parent
            $scriptsSource = Join-Path $projectRoot "packer\scripts"
        }
        
        if (-not $scriptsSource -or -not (Test-Path $scriptsSource)) {
            $scriptsSource = Join-Path $PWD "packer\scripts"
        }
        
        if (Test-Path $scriptsSource) {
            $scriptsDestination = Join-Path $workingDir "scripts"
            New-Item -ItemType Directory -Path $scriptsDestination -Force | Out-Null
            Copy-Item "$scriptsSource\*" $scriptsDestination -Recurse -Force
            Write-Information "Added scripts directory to ISO" -InformationAction Continue
        }
        else {
            Write-Information "No scripts directory found, skipping" -InformationAction Continue
        }

        # Create bootable ISO
        Write-Information "Building bootable ISO with oscdimg" -InformationAction Continue
        $etfsboot = Join-Path $workingDir 'boot\etfsboot.com'
        $efiSys = Join-Path $workingDir 'efi\microsoft\boot\efisys.bin'
        
        # Validate oscdimg
        if (-not $script:Config.OscdimgPath -or -not (Test-Path $script:Config.OscdimgPath)) {
            throw "oscdimg.exe not found or not configured"
        }
        
        $oscdimgArgs = @('-m', '-o', '-u2', '-udfver102', "-l$volumeLabel")
        
        # Configure boot options
        if ((Test-Path $etfsboot) -and (Test-Path $efiSys)) {
            Write-Information "Using dual boot (BIOS + UEFI)" -InformationAction Continue
            $bootdata = "2#p0,e,b$etfsboot#pEF,e,b$efiSys"
            $oscdimgArgs += "-bootdata:$bootdata"
        }
        elseif (Test-Path $etfsboot) {
            Write-Information "Using BIOS boot only" -InformationAction Continue
            $oscdimgArgs += "-b$etfsboot"
        }
        elseif (Test-Path $efiSys) {
            Write-Information "Using UEFI boot only" -InformationAction Continue
            $oscdimgArgs += @('-efi', $efiSys)
        }
        else {
            throw "No boot files found in ISO"
        }
        
        $oscdimgArgs += @($workingDir, $absoluteOutputIsoPath)
        
        Write-Information "Running oscdimg" -InformationAction Continue
        & $script:Config.OscdimgPath @oscdimgArgs
        
        if ($LASTEXITCODE -ne 0) {
            throw "oscdimg failed with exit code: $LASTEXITCODE"
        }
        
        if (-not (Test-Path $absoluteOutputIsoPath)) {
            throw "Output ISO was not created: $absoluteOutputIsoPath"
        }
        
        # Verify the custom ISO
        Write-Information "Verifying custom ISO contents" -InformationAction Continue
        $verifyMount = Mount-DiskImage -ImagePath $absoluteOutputIsoPath -PassThru
        $verifyDrive = ($verifyMount | Get-Volume).DriveLetter + ":"
        $autounattendExists = Test-Path "$verifyDrive\autounattend.xml"
        
        if ($autounattendExists) {
            Write-Information "Verified autounattend.xml in custom ISO root" -InformationAction Continue
        }
        else {
            Write-Warning "autounattend.xml NOT found in custom ISO root"
        }
        
        # List contents for debugging
        $contents = Get-ChildItem $verifyDrive
        Write-Information "Custom ISO root contents: $($contents.Name -join ', ')" -InformationAction Continue
        
        Dismount-DiskImage -ImagePath $absoluteOutputIsoPath | Out-Null
        
        if (-not $autounattendExists) {
            throw "autounattend.xml not found in custom ISO root after verification"
        }
        
        $isoSize = (Get-Item $absoluteOutputIsoPath).Length / 1GB
        $isoSizeGB = [math]::Round($isoSize, 2)
        Write-Information "Custom bootable ISO created successfully: $absoluteOutputIsoPath (Size: $isoSizeGB GB)" -InformationAction Continue
        
    }
    finally {
        if (Test-Path $workingDir) {
            Write-Information "Cleaning up working directory: $workingDir" -InformationAction Continue
            Remove-Item $workingDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
#endregion

#region Box Management Functions
function Test-BoxAge {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$BoxName,
        
        [Parameter(Mandatory)]
        [int]$MaxAgeDays
    )
    
    try {
        $boxInfo = & vagrant box list 2>$null | Where-Object { $_ -like "*$BoxName*" }
        if (-not $boxInfo) {
            Write-Information "Box '$BoxName' not found - rebuild needed" -InformationAction Continue
            return $true
        }
        
        # Check box directory timestamp
        $boxPath = Join-Path $env:USERPROFILE ".vagrant.d\boxes"
        $boxDirs = Get-ChildItem $boxPath -Directory -ErrorAction SilentlyContinue | 
        Where-Object { $_.Name -like "*$BoxName*" }
        
        if ($boxDirs) {
            $latestBox = $boxDirs | Sort-Object LastWriteTime -Descending | Select-Object -First 1
            $ageInDays = ((Get-Date) - $latestBox.LastWriteTime).Days
            
            Write-Information "Box age: $ageInDays days (threshold: $MaxAgeDays days)" -InformationAction Continue
            
            return $ageInDays -ge $MaxAgeDays
        }
        
        return $true
    }
    catch {
        Write-Warning "Could not determine box age: $($_.Exception.Message)"
        return $true
    }
}

function Get-RunningVagrantVMs {
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$VagrantBaseDir
    )
    
    if (-not $VagrantBaseDir) {
        $projectRoot = Split-Path $PSScriptRoot -Parent
        $VagrantBaseDir = Join-Path $projectRoot "vagrant"
    }
    
    # Ensure absolute path
    $absoluteVagrantBaseDir = if ([System.IO.Path]::IsPathRooted($VagrantBaseDir)) { 
        $VagrantBaseDir 
    }
    else { 
        Join-Path $PWD $VagrantBaseDir 
    }
    
    Write-Information "Checking for running VMs in: $absoluteVagrantBaseDir" -InformationAction Continue
    
    $environments = @("barebones", "fileserver", "dev-box", "domain-controller", "iis-server")
    $runningVMs = @()
    $originalLocation = Get-Location
    
    try {
        foreach ($env in $environments) {
            $envPath = Join-Path $absoluteVagrantBaseDir $env
            Write-Information "Checking environment: $envPath" -InformationAction Continue
            
            if (Test-Path $envPath) {
                try {
                    Set-Location $envPath
                    Write-Information "Changed to: $(Get-Location)" -InformationAction Continue
                    
                    $status = & vagrant status 2>$null
                    Write-Information "Vagrant status for ${env}: $($status -join '; ')" -InformationAction Continue
                    
                    if ($status -and ($status -match "running")) {
                        $runningVMs += $env
                        Write-Information "Found running VM: $env" -InformationAction Continue
                    }
                }
                catch {
                    Write-Warning "Could not check status for environment: $env - $($_.Exception.Message)"
                }
            }
            else {
                Write-Information "Environment directory not found: $envPath" -InformationAction Continue
            }
        }
    }
    finally {
        Set-Location $originalLocation
    }
    
    Write-Information "Running VMs found: $($runningVMs -join ', ')" -InformationAction Continue
    return $runningVMs
}
#endregion

#region Scheduled Task Functions
function New-WeeklyScheduledTask {
    [CmdletBinding()]
    param([string]$ScriptPath)
    
    $taskName = "Build-WeeklyGoldenImage"
    $taskDescription = "Weekly Windows Server 2022 Golden Image Build"
    
    try {
        # Remove existing task
        $existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if ($existingTask) {
            $null = Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        }
        
        # Create new task
        $action = New-ScheduledTaskAction -Execute "PowerShell.exe" -Argument "-ExecutionPolicy Bypass -File `"$ScriptPath`""
        $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At 2:00AM
        $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes $script:Config.BuildTimeoutMinutes) -RestartCount $script:Config.RetryAttempts
        $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Highest
        
        $null = Register-ScheduledTask -TaskName $taskName -Description $taskDescription -Action $action -Trigger $trigger -Settings $settings -Principal $principal
        
        Write-Information "Scheduled task '$taskName' created successfully" -InformationAction Continue
        Write-Host "Task will run every Sunday at 2:00 AM" -ForegroundColor Green
    }
    catch {
        throw "Failed to create scheduled task: $($_.Exception.Message)"
    }
}
#endregion

#region Packer Functions
function Invoke-PackerBuild {
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
        # Ensure all paths are absolute
        $absoluteCustomIsoPath = if ([System.IO.Path]::IsPathRooted($CustomIsoPath)) { 
            $CustomIsoPath 
        }
        else { 
            Join-Path $PWD $CustomIsoPath 
        }
        
        $absolutePackerConfigPath = if ([System.IO.Path]::IsPathRooted($PackerConfigPath)) { 
            $PackerConfigPath 
        }
        else { 
            Join-Path $PWD $PackerConfigPath 
        }
        
        $absolutePackerWorkingDir = if ([System.IO.Path]::IsPathRooted($PackerWorkingDir)) { 
            $PackerWorkingDir 
        }
        else { 
            Join-Path $PWD $PackerWorkingDir 
        }
        
        Write-Information "Absolute custom ISO path: $absoluteCustomIsoPath" -InformationAction Continue
        Write-Information "Absolute packer config path: $absolutePackerConfigPath" -InformationAction Continue
        Write-Information "Absolute packer working dir: $absolutePackerWorkingDir" -InformationAction Continue
        
        # Change to packer directory
        Set-Location $absolutePackerWorkingDir
        Write-Information "Changed to packer directory: $(Get-Location)" -InformationAction Continue

        # Clean previous build artifacts
        $outputDir = Join-Path $absolutePackerWorkingDir "output-hyperv-iso"
        if (Test-Path $outputDir) {
            Write-Information "Cleaning previous build artifacts: $outputDir" -InformationAction Continue
            Remove-Item $outputDir -Recurse -Force
        }
        
        # Remove any lingering VHDX files
        Get-ChildItem -Path $absolutePackerWorkingDir -Filter "*.vhdx" -Recurse -ErrorAction SilentlyContinue | 
        ForEach-Object {
            Write-Information "Removing old VHDX: $($_.FullName)" -InformationAction Continue
            Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
        }

        # Validate that the custom ISO exists
        if (-not (Test-Path $absoluteCustomIsoPath)) {
            throw "Custom ISO not found: $absoluteCustomIsoPath"
        }
        
        if (-not (Test-Path $absolutePackerConfigPath)) {
            throw "Packer config not found: $absolutePackerConfigPath"
        }

        $buildStartTime = Get-Date
        Write-Information "Starting Packer build (estimated time: 30-60 minutes)..." -InformationAction Continue
        Write-Information "Custom ISO: $absoluteCustomIsoPath" -InformationAction Continue
        Write-Information "Packer config: $absolutePackerConfigPath" -InformationAction Continue

        # Build with absolute path to the custom ISO
        $configFileName = Split-Path $absolutePackerConfigPath -Leaf
        $packerArgs = @(
            'build', 
            '-var', "iso_url=$absoluteCustomIsoPath",
            $configFileName
        )
        
        Write-Information "Packer command: packer $($packerArgs -join ' ')" -InformationAction Continue
        Write-Information "Working directory: $(Get-Location)" -InformationAction Continue
        
        # Execute packer with detailed output
        $env:PACKER_LOG = "1"
        $packerLogPath = Join-Path $absolutePackerWorkingDir "packer-build.log"
        $env:PACKER_LOG_PATH = $packerLogPath
        
        & packer @packerArgs

        if ($LASTEXITCODE -ne 0) {
            # Try to get more details from the log
            if (Test-Path $packerLogPath) {
                Write-Information "Packer log file contents:" -InformationAction Continue
                Get-Content $packerLogPath | Select-Object -Last 50 | ForEach-Object {
                    Write-Information "LOG: $_" -InformationAction Continue
                }
            }
            throw "Packer build failed with exit code: $LASTEXITCODE"
        }

        $buildDuration = (Get-Date) - $buildStartTime
        Write-Information "Packer build completed in $($buildDuration.ToString('hh\:mm\:ss'))" -InformationAction Continue

        # Verify output was created
        if (-not (Test-Path $outputDir)) {
            throw "Packer output directory not found: $outputDir"
        }
        
        $vhdxFiles = Get-ChildItem $outputDir -Filter "*.vhdx" -Recurse
        if ($vhdxFiles.Count -eq 0) {
            throw "No VHDX files found in Packer output directory"
        }
        
        Write-Information "Build successful! Found $($vhdxFiles.Count) VHDX file(s)" -InformationAction Continue

        return $buildDuration
    }
    finally {
        Set-Location $originalLocation
        # Clean up environment variables
        $env:PACKER_LOG = $null
        $env:PACKER_LOG_PATH = $null
    }
}
#endregion

#region Main Functions
function Invoke-GoldenImageBuild {
    [CmdletBinding()]
    param()
    
    try {
        Write-Host "=== Weekly Golden Image Build Process ===" -ForegroundColor Green
        Write-Host "Building Windows Server 2022 golden image..." -ForegroundColor Yellow
        Write-Host "Box Name: $BoxName"
        Write-Host "ISO Path: $IsoPath"
        Write-Host "Started: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        
        $buildStartTime = Get-Date
        
        # Get absolute paths for all project directories
        $projectRoot = Split-Path $PSScriptRoot -Parent
        $packerDir = Join-Path $projectRoot "packer"
        $scriptsDir = Join-Path $projectRoot "scripts"
        $vagrantDir = Join-Path $projectRoot "vagrant"
        $boxesDir = Join-Path $projectRoot "boxes"
        
        Write-Information "Project root: $projectRoot" -InformationAction Continue
        Write-Information "Packer directory: $packerDir" -InformationAction Continue
        
        # Test prerequisites
        Test-Prerequisites
        
        # Validate main Windows ISO (ensure absolute path)
        $absoluteIsoPath = if ([System.IO.Path]::IsPathRooted($IsoPath)) { 
            $IsoPath 
        }
        else { 
            Join-Path $PWD $IsoPath 
        }
        Write-Information "Using absolute ISO path: $absoluteIsoPath" -InformationAction Continue
        Test-IsoFile -Path $absoluteIsoPath
        
        # Check if rebuild is needed
        if (-not $Force) {
            $needsRebuild = Test-BoxAge -BoxName $BoxName -MaxAgeDays $DaysBeforeRebuild
            if (-not $needsRebuild) {
                Write-Host "Golden image is still fresh. Use -Force to rebuild anyway." -ForegroundColor Green
                return
            }
        }
        
        # Prepare absolute paths for all files
        $unattendIsoPath = Join-Path $packerDir "winserver_2022_unattend.iso"
        $unattendXmlPath = Join-Path $packerDir "autounattend.xml"
        $packerConfigPath = Join-Path $packerDir "windows-server-2022.pkr.hcl"
        $customIsoPath = Join-Path $packerDir "custom_windows_server_2022.iso"
        
        Write-Information "Unattend XML path: $unattendXmlPath" -InformationAction Continue
        Write-Information "Packer config path: $packerConfigPath" -InformationAction Continue
        Write-Information "Custom ISO path: $customIsoPath" -InformationAction Continue
        
        # Validate required files exist
        if (-not (Test-Path $unattendXmlPath)) {
            throw "Unattend XML file not found: $unattendXmlPath"
        }
        if (-not (Test-Path $packerConfigPath)) {
            throw "Packer configuration file not found: $packerConfigPath"
        }
        
        # Create boxes directory if it doesn't exist
        if (-not (Test-Path $boxesDir)) {
            Write-Information "Creating boxes directory: $boxesDir" -InformationAction Continue
            $null = New-Item -ItemType Directory -Path $boxesDir -Force
        }
        
        # Remove existing custom ISO
        if (Test-Path $customIsoPath) {
            Write-Information "Removing existing custom ISO: $customIsoPath" -InformationAction Continue
            Remove-Item $customIsoPath -Force
        }

        # DEBUG
        Write-Host "`n=== DEBUG: Before New-CustomIso Call ===" -ForegroundColor Magenta

        # Check all the paths we're about to pass
        Write-Host "Variables before New-CustomIso call:" -ForegroundColor Yellow
        Write-Host "  absoluteIsoPath: '$absoluteIsoPath'" -ForegroundColor Gray
        Write-Host "  customIsoPath: '$customIsoPath'" -ForegroundColor Gray  
        Write-Host "  unattendXmlPath: '$unattendXmlPath'" -ForegroundColor Gray
        Write-Host "  PSScriptRoot: '$PSScriptRoot'" -ForegroundColor Gray
        Write-Host "  projectRoot: '$projectRoot'" -ForegroundColor Gray
        Write-Host "  packerDir: '$packerDir'" -ForegroundColor Gray

        # Test each path
        Write-Host "`nPath validation:" -ForegroundColor Yellow
        Write-Host "  absoluteIsoPath exists: $(Test-Path $absoluteIsoPath -ErrorAction SilentlyContinue)" -ForegroundColor Gray
        Write-Host "  customIsoPath parent dir exists: $(Test-Path (Split-Path $customIsoPath -Parent) -ErrorAction SilentlyContinue)" -ForegroundColor Gray
        Write-Host "  unattendXmlPath exists: $(Test-Path $unattendXmlPath -ErrorAction SilentlyContinue)" -ForegroundColor Gray

        # Check for null values
        Write-Host "`nNull checks:" -ForegroundColor Yellow
        Write-Host "  absoluteIsoPath is null: $([string]::IsNullOrWhiteSpace($absoluteIsoPath))" -ForegroundColor Gray
        Write-Host "  customIsoPath is null: $([string]::IsNullOrWhiteSpace($customIsoPath))" -ForegroundColor Gray
        Write-Host "  unattendXmlPath is null: $([string]::IsNullOrWhiteSpace($unattendXmlPath))" -ForegroundColor Gray

        Write-Host "=== END DEBUG ===" -ForegroundColor Magenta
        
        # Create custom ISO with autounattend.xml embedded
        Write-Information "Creating custom Windows ISO with embedded autounattend.xml..." -InformationAction Continue
        New-CustomIso -SourceIsoPath $absoluteIsoPath -OutputIsoPath $customIsoPath -UnattendXmlPath $unattendXmlPath
        
        # Execute Packer build with absolute paths
        Write-Information "Starting Packer build..." -InformationAction Continue
        $null = Invoke-PackerBuild -CustomIsoPath $customIsoPath -PackerConfigPath $packerConfigPath -PackerWorkingDir $packerDir
        
        # Package as Vagrant box
        Write-Information "Packaging as Vagrant box..." -InformationAction Continue
        $boxScriptPath = Join-Path $scriptsDir "New-VagrantBox.ps1"
        $packerOutputDir = Join-Path $packerDir "output-hyperv-iso"
        
        if ($Force) {
            try {
                & vagrant box remove $BoxName --provider hyperv --force 2>$null
                Write-Information "Removed existing box: $BoxName" -InformationAction Continue
            }
            catch {
                Write-Verbose "No existing box to remove"
            }
        }
        
        if (Test-Path $boxScriptPath) {
            $boxArgs = @{
                BoxName               = $BoxName
                PackerOutputDirectory = $packerOutputDir
                VagrantBoxDirectory   = $boxesDir
            }
            
            & $boxScriptPath @boxArgs
        }
        else {
            Write-Warning "Box packaging script not found: $boxScriptPath"
        }
        
        # Clean up temporary files
        Write-Information "Cleaning up temporary files..." -InformationAction Continue
        if (Test-Path $customIsoPath) {
            Remove-Item $customIsoPath -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path $unattendIsoPath) {
            Remove-Item $unattendIsoPath -Force -ErrorAction SilentlyContinue
        }
        
        # Final summary
        $totalDuration = (Get-Date) - $buildStartTime
        $nextBuildDate = (Get-Date).AddDays($DaysBeforeRebuild)
        
        Write-Host "`n=== Golden Image Build Complete ===" -ForegroundColor Green
        Write-Host "Total time: $($totalDuration.ToString('hh\:mm\:ss'))"
        Write-Host "Box name: $BoxName"
        Write-Host "Built on: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        Write-Host "Next build needed after: $($nextBuildDate.ToString('yyyy-MM-dd'))"
        
        # Display deployment instructions with absolute paths
        Write-Host "`nYou can now deploy VMs using:" -ForegroundColor Yellow
        $environments = @("barebones", "fileserver", "dev-box", "domain-controller", "iis-server")
        foreach ($env in $environments) {
            $envPath = Join-Path $vagrantDir $env
            Write-Host "  Set-Location '$envPath'; vagrant up --provider=hyperv" -ForegroundColor White
        }
        
        # Check for running VMs
        $runningVMs = Get-RunningVagrantVMs -VagrantBaseDir $vagrantDir
        if ($runningVMs.Count -gt 0) {
            Write-Host "`nWARNING: The following VMs are running with the old golden image:" -ForegroundColor Yellow
            $runningVMs | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
            Write-Host "Consider recreating them to use the new golden image:" -ForegroundColor Yellow
            $runningVMs | ForEach-Object {
                $envPath = Join-Path $vagrantDir $_
                Write-Host "  Set-Location '$envPath'; vagrant destroy -f; vagrant up --provider=hyperv" -ForegroundColor White
            }
        }
        else {
            Write-Host "No running VMs detected - all future VMs will use the new golden image" -ForegroundColor Green
        }
    }
    catch {
        Write-Error "Golden image build failed: $($_.Exception.Message)"
        throw
    }
}
#endregion

function Invoke-BuildCheck {
    [CmdletBinding()]
    param()
    
    try {
        $needsRebuild = Test-BoxAge -BoxName $BoxName -MaxAgeDays $DaysBeforeRebuild
        
        Write-Host "Box: $BoxName" -ForegroundColor Cyan
        Write-Host "Rebuild needed: $needsRebuild" -ForegroundColor $(if ($needsRebuild) { "Yellow" } else { "Green" })
        
        exit $(if ($needsRebuild) { 1 } else { 0 })
    }
    catch {
        Write-Error "Failed to check build status: $($_.Exception.Message)"
        exit 2
    }
}
#endregion

#region Main Execution
try {
    # Initialize
    Initialize-Logging
    
    if ($ConfigPath) {
        Import-Configuration -Path $ConfigPath
    }
    
    # Execute based on parameter set
    switch ($PSCmdlet.ParameterSetName) {
        'Schedule' {
            Write-Host "Setting up weekly scheduled task..." -ForegroundColor Yellow
            New-WeeklyScheduledTask -ScriptPath $PSCommandPath
            exit 0
        }
        'Check' {
            Invoke-BuildCheck
        }
        'Build' {
            Invoke-GoldenImageBuild
        }
    }
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
finally {
    Stop-Logging
}