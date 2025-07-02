<#
.SYNOPSIS
    Enhanced setup script for Vagrant + Packer on Hyper-V for Windows Server environments

.DESCRIPTION
    Configures the complete environment for building Windows Server VMs with enhanced error handling,
    validation, and user experience improvements.

.PARAMETER SkipReboot
    Skip automatic reboot prompts

.PARAMETER ConfigureNetworking
    Automatically configure Hyper-V networking

.PARAMETER Force
    Force reinstallation of components

.PARAMETER Interactive
    Enable interactive mode with prompts

.PARAMETER ConfigPath
    Path to custom configuration file

.EXAMPLE
    .\Initialize-HyperVEnvironment.ps1 -Interactive
    Run in interactive mode with prompts

.EXAMPLE
    .\Initialize-HyperVEnvironment.ps1 -ConfigureNetworking -Force
    Force setup with automatic networking configuration

.NOTES
    Version: 2.0.0
    Author: Devon Casey
    Email: me@devoncasey.com
    GitHub: https://github.com/DevonCasey
    Created: July 1, 2025
    Requires: Administrator privileges, Windows 10/Server 2016+
#>

[CmdletBinding()]
param(
    [switch]$SkipReboot,
    [switch]$ConfigureNetworking,
    [switch]$Force,
    [switch]$Interactive,
    [string]$ConfigPath
)

#region Module Imports
# Import core functions if available
$coreModulePath = Join-Path $PSScriptRoot "core\Common.psm1"
if (Test-Path $coreModulePath) {
    Import-Module $coreModulePath
    $useEnhancedLogging = $true
}
else {
    Write-Warning "Core module not found. Using basic logging."
    $useEnhancedLogging = $false
}
#endregion

#region Enhanced Logging (fallback if core module not available)
if (-not $useEnhancedLogging) {
    function Write-WorkflowProgress {
        param(
            [string]$Activity,
            [string]$Status = "Processing...",
            [int]$PercentComplete = -1
        )
        if ($PercentComplete -ge 0) {
            Write-Progress -Activity $Activity -Status $Status -PercentComplete $PercentComplete
        }
        else {
            Write-Progress -Activity $Activity -Status $Status
        }
        Write-Host "$Activity - $Status" -ForegroundColor Cyan
    }
}
#endregion

#region Interactive Functions
function Show-WelcomeScreen {
    <#
    .SYNOPSIS
        Shows welcome screen and system information
    #>
    [CmdletBinding()]
    param()
    
    Clear-Host
    Write-Host ("=" * 80) -ForegroundColor Green
    Write-Host "   Hyper-V VM Imaging Workflow Setup v2.0" -ForegroundColor Green
    Write-Host ("=" * 80) -ForegroundColor Green
    Write-Host ""
    Write-Host "This script will configure your system for building Windows Server VMs using:" -ForegroundColor White
    Write-Host "  • HashiCorp Packer (for VM image creation)" -ForegroundColor Gray
    Write-Host "  • HashiCorp Vagrant (for VM deployment)" -ForegroundColor Gray
    Write-Host "  • Microsoft Hyper-V (virtualization platform)" -ForegroundColor Gray
    Write-Host "  • Windows ADK (for ISO creation tools)" -ForegroundColor Gray
    Write-Host ""
    
    # Show current system info
    $os = Get-CimInstance Win32_OperatingSystem
    $computer = Get-CimInstance Win32_ComputerSystem
    
    Write-Host "Current System:" -ForegroundColor Yellow
    Write-Host "  Computer: $($computer.Name)" -ForegroundColor White
    Write-Host "  OS: $($os.Caption)" -ForegroundColor White
    Write-Host "  Version: $($os.Version)" -ForegroundColor White
    Write-Host "  Memory: $([math]::Round($computer.TotalPhysicalMemory / 1GB, 1)) GB" -ForegroundColor White
    Write-Host ""
    
    if ($Interactive) {
        $continue = Read-Host "Continue with setup? (Y/n)"
        if ($continue -eq 'n' -or $continue -eq 'N') {
            Write-Host "Setup cancelled by user." -ForegroundColor Yellow
            exit 0
        }
    }
}

function Show-SetupMenu {
    <#
    .SYNOPSIS
        Shows interactive setup menu
    #>
    [CmdletBinding()]
    param()
    
    do {
        Clear-Host
        Write-Host ("=" * 80) -ForegroundColor Cyan
        Write-Host "   Setup Options" -ForegroundColor Cyan
        Write-Host ("=" * 80) -ForegroundColor Cyan
        Write-Host ""
        
        Write-Host "Setup Tasks:" -ForegroundColor Yellow
        Write-Host "  1. Check Prerequisites" -ForegroundColor White
        Write-Host "  2. Install Required Software" -ForegroundColor White
        Write-Host "  3. Configure Hyper-V" -ForegroundColor White
        Write-Host "  4. Configure Networking" -ForegroundColor White
        Write-Host "  5. Verify Installation" -ForegroundColor White
        Write-Host "  6. Complete Setup (All Tasks)" -ForegroundColor Green
        Write-Host "  Q. Quit" -ForegroundColor White
        Write-Host ""
        
        $choice = Read-Host "Select an option (1-6, Q)"
        
        switch ($choice.ToUpper()) {
            "1" { Test-SetupPrerequisites; Read-Host "Press Enter to continue" }
            "2" { Install-RequiredSoftware; Read-Host "Press Enter to continue" }
            "3" { Enable-HyperVFeatures; Read-Host "Press Enter to continue" }
            "4" { Configure-HyperVNetworking; Read-Host "Press Enter to continue" }
            "5" { Test-InstallationComplete; Read-Host "Press Enter to continue" }
            "6" { 
                Invoke-CompleteSetup
                Read-Host "Setup complete! Press Enter to exit"
                return
            }
            "Q" { 
                Write-Host "Exiting setup..." -ForegroundColor Yellow
                return
            }
            default { 
                Write-Host "Invalid selection. Please choose 1-6 or Q." -ForegroundColor Red
                Start-Sleep -Seconds 2
            }
        }
    } while ($true)
}
#endregion

#region Prerequisite Functions
function Test-SetupPrerequisites {
    <#
    .SYNOPSIS
        Tests system prerequisites for setup
    #>
    [CmdletBinding()]
    param()
    
    Write-Host ("=" * 60) -ForegroundColor Yellow
    Write-Host "Checking Prerequisites..." -ForegroundColor Yellow
    Write-Host ("=" * 60) -ForegroundColor Yellow
    
    $issues = @()
    
    # Check if running as Administrator
    Write-WorkflowProgress -Activity "Prerequisites Check" -Status "Checking administrator privileges..." -PercentComplete 10
    if (-not (Test-IsElevated)) {
        $issues += "Script must be run as Administrator"
    }
    else {
        Write-Host "✓ Running as Administrator" -ForegroundColor Green
    }

    # Check Windows version
    Write-WorkflowProgress -Activity "Prerequisites Check" -Status "Checking Windows version..." -PercentComplete 20
    $os = Get-CimInstance Win32_OperatingSystem
    $version = [Version]$os.Version

    if ($version.Major -lt 10) {
        $issues += "Windows 10 or Windows Server 2016+ required"
    }
    else {
        Write-Host "✓ Windows version supported ($($os.Caption))" -ForegroundColor Green
    }

    # Check available memory
    Write-WorkflowProgress -Activity "Prerequisites Check" -Status "Checking system resources..." -PercentComplete 30
    $computer = Get-CimInstance Win32_ComputerSystem
    $memoryGB = [math]::Round($computer.TotalPhysicalMemory / 1GB, 1)

    if ($memoryGB -lt 8) {
        $issues += "At least 8GB RAM recommended (found: $memoryGB GB)"
    }
    else {
        Write-Host ("✓ Sufficient memory available ({0} GB)" -f $memoryGB) -ForegroundColor Green
    }

    # Check Hyper-V compatibility
    Write-WorkflowProgress -Activity "Prerequisites Check" -Status "Checking Hyper-V compatibility..." -PercentComplete 40
    try {
        $hyperVInfo = Get-ComputerInfo -Property HyperV*
        if ($hyperVInfo.HyperVRequirementVirtualizationFirmwareEnabled -eq $false) {
            $issues += "Virtualization must be enabled in BIOS/UEFI"
        }
        else {
            Write-Host "✓ Hardware virtualization supported" -ForegroundColor Green
        }
    }
    catch {
        Write-Warning "Could not check Hyper-V compatibility"
    }

    # Check disk space
    Write-WorkflowProgress -Activity "Prerequisites Check" -Status "Checking disk space..." -PercentComplete 50
    $systemDrive = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='C:'"
    $freeSpaceGB = [math]::Round($systemDrive.FreeSpace / 1GB, 1)

    if ($freeSpaceGB -lt 50) {
        $issues += "At least 50GB free disk space recommended (found: $freeSpaceGB GB)"
    }
    else {
        Write-Host ("✓ Sufficient disk space available ({0} GB free)" -f $freeSpaceGB) -ForegroundColor Green
    }

    # Check internet connectivity
    Write-WorkflowProgress -Activity "Prerequisites Check" -Status "Checking internet connectivity..." -PercentComplete 60
    try {
        $connection = Test-NetConnection -ComputerName "www.microsoft.com" -Port 443 -InformationLevel Quiet
        if ($connection) {
            Write-Host "✓ Internet connectivity available" -ForegroundColor Green
        }
        else {
            $issues += "Internet connectivity required for downloads"
        }
    }
    catch {
        $issues += "Internet connectivity required for downloads"
    }

    Write-Progress -Activity "Prerequisites Check" -Completed

    # Display results
    if ($issues.Count -eq 0) {
        Write-Host "`n✓ All prerequisites met!" -ForegroundColor Green
        return $true
    }
    else {
        Write-Host "`n✗ Issues found:" -ForegroundColor Red
        $issues | ForEach-Object { Write-Host "  ✗ $_" -ForegroundColor Red }

        if ($Interactive) {
            $continue = Read-Host "`nContinue anyway? (y/N)"
            return ($continue -eq 'y' -or $continue -eq 'Y')
        }
        return $false
    }
}

function Test-IsElevated {
    <#
    .SYNOPSIS
        Tests if running with elevated privileges (fallback if core module not available)
    #>
    [CmdletBinding()]
    param()
    
    if (Get-Command Test-IsElevated -ErrorAction SilentlyContinue) {
        return Test-IsElevated
    }
    
    $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($currentUser)
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}
#endregion

#region Software Installation Functions
function Install-RequiredSoftware {
    <#
    .SYNOPSIS
        Installs required software packages
    #>
    [CmdletBinding()]
    param()
    
    Write-Host "`n" + ("=" * 60) -ForegroundColor Yellow
    Write-Host "Installing Required Software..." -ForegroundColor Yellow
    Write-Host ("=" * 60) -ForegroundColor Yellow
    
    # Install Chocolatey
    Write-WorkflowProgress -Activity "Software Installation" -Status "Installing Chocolatey package manager..." -PercentComplete 10
    Install-Chocolatey
    
    # Refresh environment variables
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("PATH", "User")
    
    # Install Packer and Vagrant
    Write-WorkflowProgress -Activity "Software Installation" -Status "Installing Packer and Vagrant..." -PercentComplete 30
    Install-HashiCorpTools
    
    # Install Vagrant plugins
    Write-WorkflowProgress -Activity "Software Installation" -Status "Installing Vagrant plugins..." -PercentComplete 50
    Install-VagrantPlugins
    
    # Install Windows ADK
    Write-WorkflowProgress -Activity "Software Installation" -Status "Installing Windows ADK..." -PercentComplete 70
    Install-WindowsADK
    
    Write-Progress -Activity "Software Installation" -Completed
    Write-Host "✓ Software installation completed!" -ForegroundColor Green
}

function Install-Chocolatey {
    <#
    .SYNOPSIS
        Installs Chocolatey package manager
    #>
    [CmdletBinding()]
    param()
    
    if (Get-Command choco -ErrorAction SilentlyContinue) {
        Write-Host "✓ Chocolatey already installed" -ForegroundColor Green
        return
    }
    
    try {
        Write-Host "Installing Chocolatey package manager..." -ForegroundColor Yellow
        Set-ExecutionPolicy Bypass -Scope Process -Force
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
        Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
        
        # Verify installation
        if (Get-Command choco -ErrorAction SilentlyContinue) {
            Write-Host "✓ Chocolatey installed successfully" -ForegroundColor Green
        }
        else {
            throw "Chocolatey installation verification failed"
        }
    }
    catch {
        Write-Error "Failed to install Chocolatey: $($_.Exception.Message)"
        throw
    }
}

function Install-HashiCorpTools {
    <#
    .SYNOPSIS
        Installs Packer and Vagrant
    #>
    [CmdletBinding()]
    param()
    
    $tools = @(
        @{ Name = "Packer"; Package = "packer"; Command = "packer version" },
        @{ Name = "Vagrant"; Package = "vagrant"; Command = "vagrant --version" }
    )
    
    foreach ($tool in $tools) {
        try {
            # Check if already installed
            if (-not $Force) {
                try {
                    $version = Invoke-Expression $tool.Command 2>$null
                    Write-Host "✓ $($tool.Name) already installed: $version" -ForegroundColor Green
                    continue
                }
                catch {
                    # Not installed, continue with installation
                }
            }
            
            Write-Host "Installing $($tool.Name)..." -ForegroundColor Yellow
            $result = choco install $tool.Package -y --no-progress
            
            if ($LASTEXITCODE -eq 0) {
                # Refresh PATH and verify
                $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine")
                $version = Invoke-Expression $tool.Command 2>$null
                Write-Host "✓ $($tool.Name) installed successfully: $version" -ForegroundColor Green
            }
            else {
                throw "Chocolatey installation failed with exit code: $LASTEXITCODE"
            }
        }
        catch {
            Write-Error "Failed to install $($tool.Name): $($_.Exception.Message)"
            throw
        }
    }
}

function Install-VagrantPlugins {
    <#
    .SYNOPSIS
        Installs required Vagrant plugins
    #>
    [CmdletBinding()]
    param()
    
    $plugins = @("vagrant-reload", "vagrant-winrm")
    
    foreach ($plugin in $plugins) {
        try {
            # Check if already installed
            $installedPlugins = & vagrant plugin list 2>$null
            if ($installedPlugins -match $plugin) {
                Write-Host "✓ Vagrant plugin '$plugin' already installed" -ForegroundColor Green
                continue
            }
            
            Write-Host "Installing Vagrant plugin: $plugin..." -ForegroundColor Yellow
            & vagrant plugin install $plugin
            
            if ($LASTEXITCODE -eq 0) {
                Write-Host "✓ Vagrant plugin '$plugin' installed successfully" -ForegroundColor Green
            }
            else {
                throw "Plugin installation failed with exit code: $LASTEXITCODE"
            }
        }
        catch {
            Write-Warning "Failed to install Vagrant plugin '$plugin': $($_.Exception.Message)"
        }
    }
}

function Install-WindowsADK {
    <#
    .SYNOPSIS
        Installs Windows Assessment and Deployment Kit
    #>
    [CmdletBinding()]
    param()
    
    # Check if oscdimg.exe is already available
    $oscdimgPaths = @(
        "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe",
        "${env:ProgramFiles}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe"
    )
    
    $oscdimgFound = $false
    foreach ($path in $oscdimgPaths) {
        if (Test-Path $path) {
            Write-Host "✓ Windows ADK (oscdimg.exe) already available at: $path" -ForegroundColor Green
            $oscdimgFound = $true
            break
        }
    }
    
    if ($oscdimgFound -and -not $Force) {
        return
    }
    
    try {
        Write-Host "Installing Windows Assessment and Deployment Kit..." -ForegroundColor Yellow
        
        # Try multiple installation methods
        $installed = $false
        
        # Method 1: Try Chocolatey packages
        $adkPackages = @("windows-adk", "windows-adk-winpe")
        foreach ($package in $adkPackages) {
            try {
                Write-Host "Attempting to install $package via Chocolatey..." -ForegroundColor Gray
                choco install $package -y --no-progress --ignore-checksums
                if ($LASTEXITCODE -eq 0) {
                    $installed = $true
                }
            }
            catch {
                Write-Verbose "Chocolatey installation of $package failed: $($_.Exception.Message)"
            }
        }
        
        # Method 2: Download and install manually if Chocolatey failed
        if (-not $installed) {
            Write-Host "Chocolatey installation failed, attempting manual download..." -ForegroundColor Yellow
            Install-WindowsADKManual
            $installed = $true
        }
        
        # Verify installation
        $oscdimgFound = $false
        foreach ($path in $oscdimgPaths) {
            if (Test-Path $path) {
                Write-Host "✓ Windows ADK installed successfully: $path" -ForegroundColor Green
                $oscdimgFound = $true
                break
            }
        }
        
        if (-not $oscdimgFound) {
            throw "oscdimg.exe not found after installation"
        }
        
    }
    catch {
        Write-Warning "Windows ADK installation encountered issues: $($_.Exception.Message)"
        Write-Host "You may need to install Windows ADK manually from:" -ForegroundColor Yellow
        Write-Host "https://docs.microsoft.com/en-us/windows-hardware/get-started/adk-install" -ForegroundColor Gray
    }
}

function Install-WindowsADKManual {
    <#
    .SYNOPSIS
        Manually downloads and installs Windows ADK
    #>
    [CmdletBinding()]
    param()
    
    $tempDir = Join-Path $env:TEMP "WindowsADK"
    if (-not (Test-Path $tempDir)) {
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    }
    
    try {
        # Download ADK installer
        $adkUrl = "https://download.microsoft.com/download/6/A/E/6AEA92B0-A412-4622-983E-5B305D2EBE56/adk/adksetup.exe"
        $installerPath = Join-Path $tempDir "adksetup.exe"
        
        Write-Host "Downloading Windows ADK installer..." -ForegroundColor Yellow
        Invoke-WebRequest -Uri $adkUrl -OutFile $installerPath -UseBasicParsing
        
        # Install ADK with only Deployment Tools
        Write-Host "Installing Windows ADK Deployment Tools..." -ForegroundColor Yellow
        $installArgs = @(
            "/quiet",
            "/features", "OptionId.DeploymentTools"
        )
        
        $process = Start-Process -FilePath $installerPath -ArgumentList $installArgs -Wait -PassThru
        
        if ($process.ExitCode -eq 0) {
            Write-Host "✓ Windows ADK installed successfully" -ForegroundColor Green
        }
        else {
            throw "ADK installation failed with exit code: $($process.ExitCode)"
        }
        
    }
    finally {
        # Clean up
        if (Test-Path $tempDir) {
            Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
#endregion

#region Hyper-V Configuration Functions
function Enable-HyperVFeatures {
    <#
    .SYNOPSIS
        Enables Hyper-V features and checks prerequisites
    #>
    [CmdletBinding()]
    param()
    
    Write-Host "`n" + ("=" * 60) -ForegroundColor Yellow
    Write-Host "Configuring Hyper-V..." -ForegroundColor Yellow
    Write-Host ("=" * 60) -ForegroundColor Yellow
    
    # Check if Hyper-V is already enabled
    Write-WorkflowProgress -Activity "Hyper-V Configuration" -Status "Checking current Hyper-V status..." -PercentComplete 10
    $hyperVFeature = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -ErrorAction SilentlyContinue
    
    if ($hyperVFeature -and $hyperVFeature.State -eq 'Enabled') {
        Write-Host "✓ Hyper-V is already enabled" -ForegroundColor Green
    }
    else {
        # Enable Hyper-V features
        Write-WorkflowProgress -Activity "Hyper-V Configuration" -Status "Enabling Hyper-V features..." -PercentComplete 30
        
        $hyperVFeatures = @(
            "Microsoft-Hyper-V-All",
            "Microsoft-Hyper-V",
            "Microsoft-Hyper-V-Tools-All",
            "Microsoft-Hyper-V-Management-PowerShell",
            "Microsoft-Hyper-V-Hypervisor",
            "Microsoft-Hyper-V-Services",
            "Microsoft-Hyper-V-Management-Clients"
        )
        
        $rebootRequired = $false
        foreach ($feature in $hyperVFeatures) {
            try {
                Write-Host "Enabling $feature..." -ForegroundColor Gray
                $result = Enable-WindowsOptionalFeature -Online -FeatureName $feature -All -NoRestart
                if ($result.RestartNeeded) {
                    $rebootRequired = $true
                }
                Write-Host "✓ Enabled $feature" -ForegroundColor Green
            }
            catch {
                Write-Warning "Could not enable $feature - it may already be enabled or not available: $($_.Exception.Message)"
            }
        }
        
        if ($rebootRequired) {
            Write-Host "⚠ A reboot is required to complete Hyper-V installation" -ForegroundColor Yellow
        }
    }
    
    # Check Hyper-V Administrators group membership
    Write-WorkflowProgress -Activity "Hyper-V Configuration" -Status "Checking Hyper-V Administrators group..." -PercentComplete 60
    Test-HyperVAdministrators
    
    Write-Progress -Activity "Hyper-V Configuration" -Completed
    Write-Host "✓ Hyper-V configuration completed!" -ForegroundColor Green
}

function Test-HyperVAdministrators {
    <#
    .SYNOPSIS
        Checks and configures Hyper-V Administrators group membership
    #>
    [CmdletBinding()]
    param()
    
    $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $username = $currentUser.Split('\')[-1]
    
    try {
        # Check if user is in Hyper-V Administrators group
        $hyperVAdminsGroup = [ADSI]"WinNT://./Hyper-V Administrators,group"
        $members = $hyperVAdminsGroup.Members() | ForEach-Object { 
            $_.GetType().InvokeMember("Name", "GetProperty", $null, $_, $null) 
        }
        
        $isInHyperVAdmins = $members -contains $username
        
        if ($isInHyperVAdmins) {
            Write-Host "✓ User '$username' is already in Hyper-V Administrators group" -ForegroundColor Green
        }
        else {
            Write-Host "Adding user '$username' to Hyper-V Administrators group..." -ForegroundColor Yellow
            
            try {
                net localgroup "Hyper-V Administrators" $username /add
                if ($LASTEXITCODE -eq 0) {
                    Write-Host "✓ Successfully added '$username' to Hyper-V Administrators group" -ForegroundColor Green
                    Write-Host "⚠ You will need to log out and log back in (or reboot) for the change to take effect" -ForegroundColor Yellow
                    $script:requiresLogoff = $true
                }
                else {
                    throw "Failed to add user to group (exit code: $LASTEXITCODE)"
                }
            }
            catch {
                Write-Warning "Failed to add user to Hyper-V Administrators group: $($_.Exception.Message)"
                Write-Host "Please manually add your user account to the 'Hyper-V Administrators' group:" -ForegroundColor Yellow
                Write-Host "  1. Open Computer Management (compmgmt.msc)" -ForegroundColor Gray
                Write-Host "  2. Navigate to Local Users and Groups > Groups" -ForegroundColor Gray
                Write-Host "  3. Double-click 'Hyper-V Administrators'" -ForegroundColor Gray
                Write-Host "  4. Click 'Add' and add your user account" -ForegroundColor Gray
                Write-Host "  5. Log out and log back in (or reboot)" -ForegroundColor Gray
            }
        }
    }
    catch {
        Write-Warning "Could not check Hyper-V Administrators group membership: $($_.Exception.Message)"
    }
}
#endregion

#region Networking Configuration Functions
function Set-HyperVNetworking {
    <#
    .SYNOPSIS
        Configures Hyper-V networking with enhanced options
    #>
    [CmdletBinding()]
    param()
    
    Write-Host "`n" + ("=" * 60) -ForegroundColor Yellow
    Write-Host "Configuring Hyper-V Networking..." -ForegroundColor Yellow
    Write-Host ("=" * 60) -ForegroundColor Yellow
    
    $switchName = "Virtual Switch VLAN Trunk"
    
    # Check if virtual switch already exists
    $existingSwitch = Get-VMSwitch -Name $switchName -ErrorAction SilentlyContinue
    if ($existingSwitch) {
        Write-Host "✓ Virtual switch '$switchName' already exists ($($existingSwitch.SwitchType))" -ForegroundColor Green

        if ($existingSwitch.NetAdapterInterfaceDescription) {
            Write-Host "  Attached to: $($existingSwitch.NetAdapterInterfaceDescription)" -ForegroundColor Gray
        }

        if (-not $Force) {
            return
        }
        else {
            Write-Host "Force flag specified, reconfiguring switch..." -ForegroundColor Yellow
        }
    }
    
    if ($Interactive) {
        Show-NetworkingMenu -SwitchName $switchName
    }
    else {
        New-HyperVSwitch -SwitchName $switchName -AutoDetect
    }
    
    Write-Host "✓ Hyper-V networking configuration completed!" -ForegroundColor Green
}

function Show-NetworkingMenu {
    <#
    .SYNOPSIS
        Shows interactive networking configuration menu
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SwitchName
    )
    
    Write-Host "`nNetworking Configuration Options:" -ForegroundColor Yellow
    Write-Host "  1. External Switch (recommended for production)" -ForegroundColor White
    Write-Host "  2. Internal Switch with NAT (for isolated testing)" -ForegroundColor White
    Write-Host "  3. Auto-detect best option" -ForegroundColor White
    Write-Host "  4. Skip networking configuration" -ForegroundColor White
    Write-Host ""
    
    do {
        $choice = Read-Host "Select networking option (1-4)"
        
        switch ($choice) {
            "1" {
                New-HyperVSwitch -SwitchName $SwitchName -Type External
                return
            }
            "2" {
                New-HyperVSwitch -SwitchName $SwitchName -Type Internal
                return
            }
            "3" {
                New-HyperVSwitch -SwitchName $SwitchName -AutoDetect
                return
            }
            "4" {
                Write-Host "Networking configuration skipped" -ForegroundColor Yellow
                return
            }
            default {
                Write-Host "Invalid selection. Please choose 1-4." -ForegroundColor Red
            }
        }
    } while ($true)
}

function New-HyperVSwitch {
    <#
    .SYNOPSIS
        Creates a new Hyper-V virtual switch with the specified configuration
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SwitchName,
        
        [ValidateSet("External", "Internal")]
        [string]$Type,
        
        [switch]$AutoDetect
    )
    
    try {
        if ($AutoDetect) {
            # Auto-detect best adapter
            $adapter = Get-BestNetworkAdapter
            if ($adapter) {
                $Type = "External"
                Write-Host "Auto-detected network adapter: $($adapter.Name)" -ForegroundColor Green
            }
            else {
                $Type = "Internal"
                Write-Host "No suitable network adapter found, using internal switch" -ForegroundColor Yellow
            }
        }
        
        # Remove existing switch if it exists
        $existingSwitch = Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue
        if ($existingSwitch) {
            Write-Host "Removing existing virtual switch..." -ForegroundColor Yellow
            Remove-VMSwitch -Name $SwitchName -Force
        }
        
        if ($Type -eq "External") {
            New-ExternalVMSwitch -SwitchName $SwitchName
        }
        else {
            New-InternalVMSwitch -SwitchName $SwitchName
        }
        
    }
    catch {
        Write-Error "Failed to create virtual switch: $($_.Exception.Message)"
        throw
    }
}

function Get-BestNetworkAdapter {
    <#
    .SYNOPSIS
        Finds the best network adapter for external switch
    #>
    [CmdletBinding()]
    param()
    
    # Look for NIC Team first (preferred)
    $nicTeam = Get-NetAdapter | Where-Object { 
        $_.InterfaceDescription -like "*Team*" -or $_.Name -like "*Team*" 
    } | Where-Object Status -eq "Up" | Select-Object -First 1
    
    if ($nicTeam) {
        Write-Host "Found NIC Team: $($nicTeam.Name)" -ForegroundColor Green
        return $nicTeam
    }
    
    # Look for physical Ethernet adapter
    $ethernetAdapter = Get-NetAdapter | Where-Object { 
        $_.PhysicalMediaType -eq "802.3" -and 
        $_.Status -eq "Up" -and
        $_.Name -notlike "*Bluetooth*" -and
        $_.Name -notlike "*Wi-Fi*" -and
        $_.Name -notlike "*Wireless*"
    } | Sort-Object LinkSpeed -Descending | Select-Object -First 1
    
    if ($ethernetAdapter) {
        Write-Host "Found Ethernet adapter: $($ethernetAdapter.Name)" -ForegroundColor Green
        return $ethernetAdapter
    }
    
    Write-Host "No suitable network adapter found" -ForegroundColor Yellow
    return $null
}

function New-ExternalVMSwitch {
    <#
    .SYNOPSIS
        Creates an external VM switch
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SwitchName
    )
    
    $adapter = Get-BestNetworkAdapter
    if (-not $adapter) {
        throw "No suitable network adapter found for external switch"
    }
    
    Write-Host "Creating external virtual switch attached to: $($adapter.Name)" -ForegroundColor Yellow
    New-VMSwitch -Name $SwitchName -NetAdapterName $adapter.Name -AllowManagementOS $true
    
    Write-Host "✓ External virtual switch created successfully" -ForegroundColor Green
    Write-Host "  VMs will use DHCP from your network" -ForegroundColor Gray
    Write-Host "  VLAN 31 will be configured on individual VMs" -ForegroundColor Gray
}

function New-InternalVMSwitch {
    <#
    .SYNOPSIS
        Creates an internal VM switch with NAT
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SwitchName
    )
    
    Write-Host "Creating internal virtual switch..." -ForegroundColor Yellow
    New-VMSwitch -Name $SwitchName -SwitchType Internal
    
    # Configure IP and NAT for internal switch
    try {
        Start-Sleep -Seconds 5  # Wait for switch to be ready
        
        $networkAdapter = Get-NetAdapter -Name "vEthernet ($SwitchName)" -ErrorAction SilentlyContinue
        if ($networkAdapter) {
            # Configure IP address
            $existingIP = Get-NetIPAddress -InterfaceAlias "vEthernet ($SwitchName)" -AddressFamily IPv4 -ErrorAction SilentlyContinue
            if (-not $existingIP -or $existingIP.IPAddress -ne "10.1.3.250") {
                Write-Host "Configuring IP address for internal switch..." -ForegroundColor Yellow
                New-NetIPAddress -IPAddress "10.1.3.250" -PrefixLength 24 -InterfaceAlias "vEthernet ($SwitchName)" -ErrorAction SilentlyContinue
            }
            
            # Configure NAT
            if (-not (Get-NetNat -Name "vmNAT" -ErrorAction SilentlyContinue)) {
                Write-Host "Creating NAT for internal switch..." -ForegroundColor Yellow
                New-NetNat -Name "vmNAT" -InternalIPInterfaceAddressPrefix "10.1.3.0/24"
            }
            
            Write-Host "✓ Internal virtual switch created successfully" -ForegroundColor Green
            Write-Host "  IP Range: 10.1.3.0/24" -ForegroundColor Gray
            Write-Host "  Gateway: 10.1.3.250" -ForegroundColor Gray
        }
    }
    catch {
        Write-Warning "Could not configure IP/NAT for internal switch: $($_.Exception.Message)"
        Write-Host "You may need to configure this manually" -ForegroundColor Yellow
    }
}
#endregion

#region Validation Functions
function Test-InstallationComplete {
    <#
    .SYNOPSIS
        Validates that the installation is complete and working
    #>
    [CmdletBinding()]
    param()
    
    Write-Host "`n" + ("=" * 60) -ForegroundColor Yellow
    Write-Host "Validating Installation..." -ForegroundColor Yellow
    Write-Host ("=" * 60) -ForegroundColor Yellow
    
    $allGood = $true
    
    # Test Packer
    Write-WorkflowProgress -Activity "Installation Validation" -Status "Testing Packer..." -PercentComplete 20
    try {
        $packerVersion = & packer version 2>$null
        Write-Host "✓ Packer: $packerVersion" -ForegroundColor Green
    }
    catch {
        Write-Host "✗ Packer: Not working" -ForegroundColor Red
        $allGood = $false
    }
    
    # Test Vagrant
    Write-WorkflowProgress -Activity "Installation Validation" -Status "Testing Vagrant..." -PercentComplete 40
    try {
        $vagrantVersion = & vagrant --version 2>$null
        Write-Host "✓ Vagrant: $vagrantVersion" -ForegroundColor Green
    }
    catch {
        Write-Host "✗ Vagrant: Not working" -ForegroundColor Red
        $allGood = $false
    }
    
    # Test Hyper-V
    Write-WorkflowProgress -Activity "Installation Validation" -Status "Testing Hyper-V..." -PercentComplete 60
    try {
        $hyperVFeature = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All
        if ($hyperVFeature.State -eq 'Enabled') {
            Write-Host "✓ Hyper-V: Enabled" -ForegroundColor Green
        }
        else {
            Write-Host "✗ Hyper-V: Not enabled" -ForegroundColor Red
            $allGood = $false
        }
    }
    catch {
        Write-Host "✗ Hyper-V: Error checking status" -ForegroundColor Red
        $allGood = $false
    }
    
    # Test oscdimg
    Write-WorkflowProgress -Activity "Installation Validation" -Status "Testing Windows ADK..." -PercentComplete 80
    $oscdimgPaths = @(
        "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe",
        "${env:ProgramFiles}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe"
    )
    
    $oscdimgFound = $false
    foreach ($path in $oscdimgPaths) {
        if (Test-Path $path) {
            Write-Host "✓ Windows ADK (oscdimg): Found" -ForegroundColor Green
            $oscdimgFound = $true
            break
        }
    }

    if (-not $oscdimgFound) {
        Write-Host "✗ Windows ADK (oscdimg): Not found" -ForegroundColor Red
        $allGood = $false
    }
    
    # Test Virtual Switch
    Write-WorkflowProgress -Activity "Installation Validation" -Status "Testing Virtual Switch..." -PercentComplete 90
    $virtualSwitch = Get-VMSwitch -Name "Virtual Switch VLAN Trunk" -ErrorAction SilentlyContinue
    if ($virtualSwitch) {
        Write-Host "✓ Virtual Switch: Found ($($virtualSwitch.SwitchType))" -ForegroundColor Green
    }
    else {
        Write-Host "⚠ Virtual Switch: Not found (can be created later)" -ForegroundColor Yellow
    }
    
    Write-Progress -Activity "Installation Validation" -Completed
    
    if ($allGood) {
        Write-Host "`n✓ All components validated successfully!" -ForegroundColor Green
        Write-Host "Your system is ready for building Windows Server VMs!" -ForegroundColor Green
    }
    else {
        Write-Host "`n⚠ Some components need attention" -ForegroundColor Red
        Write-Host "Please review the errors above and fix any issues" -ForegroundColor Yellow
    }
    
    return $allGood
}
#endregion

#region Main Setup Functions
function Invoke-CompleteSetup {
    <#
    .SYNOPSIS
        Performs complete setup process
    #>
    [CmdletBinding()]
    param()
    
    Write-Host "`n" + ("=" * 70) -ForegroundColor Green
    Write-Host "   Starting Complete Setup Process" -ForegroundColor Green
    Write-Host ("=" * 70) -ForegroundColor Green
    
    try {
        # Prerequisites check
        if (-not (Test-SetupPrerequisites)) {
            throw "Prerequisites check failed"
        }
        
        # Install software
        Install-RequiredSoftware
        
        # Configure Hyper-V
        Enable-HyperVFeatures
        
        # Configure networking if requested
        if ($ConfigureNetworking -or $Interactive) {
            Set-HyperVNetworking
        }
        
        # Final validation
        $validationResult = Test-InstallationComplete
        
        if ($validationResult) {
            Show-SetupComplete
        }
        else {
            Write-Host "`n⚠ Setup completed with some issues. Please review the validation results." -ForegroundColor Yellow
        }
        
    }
    catch {
        Write-Host "`n✗ Setup failed: $($_.Exception.Message)" -ForegroundColor Red
        throw
    }
}

function Show-SetupComplete {
    <#
    .SYNOPSIS
        Shows setup completion message and next steps
    #>
    [CmdletBinding()]
    param()
    
    Write-Host "`n" + ("=" * 70) -ForegroundColor Green
    Write-Host "   Setup Complete!" -ForegroundColor Green
    Write-Host ("=" * 70) -ForegroundColor Green
    Write-Host ""
    Write-Host "Your Hyper-V VM imaging environment is ready!" -ForegroundColor Green
    Write-Host ""
    Write-Host "Next Steps:" -ForegroundColor Yellow
    Write-Host "  1. Download Windows Server 2025 ISO to one of these locations:" -ForegroundColor White
    Write-Host "     • F:\Install\Microsoft\Windows Server\WinServer_2025.iso" -ForegroundColor Gray
    Write-Host "     • C:\ISOs\WinServer_2025.iso" -ForegroundColor Gray
    Write-Host "     • D:\ISOs\WinServer_2025.iso" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  2. Build your first golden image:" -ForegroundColor White
    Write-Host "     .\scripts\Build-WeeklyGoldenImage.ps1 -Interactive" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  3. Deploy a VM environment:" -ForegroundColor White
    Write-Host "     cd vagrant\barebones" -ForegroundColor Gray
    Write-Host "     vagrant up --provider=hyperv" -ForegroundColor Gray
    Write-Host ""
    
    # Check if reboot is needed
    if ($script:requiresLogoff) {
        Write-Host "IMPORTANT:" -ForegroundColor Red
        Write-Host "You were added to the Hyper-V Administrators group." -ForegroundColor Yellow
        Write-Host "Please log out and log back in (or reboot) before using Packer!" -ForegroundColor Yellow
    }
    
    # Offer to reboot if needed
    if (-not $SkipReboot) {
        $rebootChoice = if ($script:requiresLogoff) {
            Read-Host "`nA reboot is REQUIRED for group membership changes. Reboot now? (Y/n)"
        }
        else {
            Read-Host "`nA reboot is recommended to ensure all features are enabled. Reboot now? (y/N)"
        }
        
        if (($script:requiresLogoff -and $rebootChoice -ne 'n' -and $rebootChoice -ne 'N') -or
            ($rebootChoice -eq 'y' -or $rebootChoice -eq 'Y')) {
            Write-Host "Rebooting in 10 seconds..." -ForegroundColor Yellow
            Start-Sleep -Seconds 10
            Restart-Computer -Force
        }
    }
}
#endregion

#region Script Variables
$script:requiresLogoff = $false
#endregion

#region Main Execution
try {
    # Initialize enhanced logging if available
    if ($useEnhancedLogging) {
        Initialize-WorkflowConfiguration -ConfigPath $ConfigPath
        Initialize-WorkflowLogging -ScriptName "Initialize-HyperVEnvironment"
    }
    
    # Check if running as Administrator
    if (-not (Test-IsElevated)) {
        Write-Host "This script requires Administrator privileges." -ForegroundColor Yellow
        Write-Host "Attempting to restart as Administrator..." -ForegroundColor Yellow
        
        # Build argument list
        $argumentList = @()
        if ($SkipReboot) { $argumentList += "-SkipReboot" }
        if ($ConfigureNetworking) { $argumentList += "-ConfigureNetworking" }
        if ($Force) { $argumentList += "-Force" }
        if ($Interactive) { $argumentList += "-Interactive" }
        if ($ConfigPath) { $argumentList += "-ConfigPath `"$ConfigPath`"" }
        
        $argumentString = if ($argumentList.Count -gt 0) { 
            "-File `"$PSCommandPath`" " + ($argumentList -join " ")
        }
        else { 
            "-File `"$PSCommandPath`""
        }
        
        try {
            Start-Process PowerShell -Verb RunAs -ArgumentList $argumentString -Wait
            exit 0
        }
        catch {
            Write-Error "Failed to restart as Administrator. Please manually run PowerShell as Administrator and try again."
            exit 1
        }
    }
    
    # Show welcome screen
    Show-WelcomeScreen
    
    # Execute based on mode
    if ($Interactive) {
        Show-SetupMenu
    }
    else {
        Invoke-CompleteSetup
    }
    
}
catch {
    Write-Error ("Setup failed: {0}" -f $_.Exception.Message)
    exit 1
}
finally {
    if ($useEnhancedLogging) {
        Stop-WorkflowLogging
    }
}
#endregion