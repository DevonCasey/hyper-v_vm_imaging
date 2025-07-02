<#
.SYNOPSIS
    Core common functions for Hyper-V VM Imaging Workflow

.DESCRIPTION
    Provides centralized configuration management, logging, validation, and utility functions
    for the Hyper-V VM imaging workflow system.

.NOTES
    Version: 1.0.0
    Author: Devon Casey
    Email: me@devoncasey.com
    GitHub: https://github.com/DevonCasey
    Created: July 1, 2025
#>

#region Module Variables
$script:Config = $null
$script:LogPath = $null
$script:TranscriptStarted = $false
$script:ProjectRoot = $null
#endregion

#region Configuration Management
function Initialize-WorkflowConfiguration {
    <#
    .SYNOPSIS
        Loads and validates workflow configuration
    
    .PARAMETER ConfigPath
        Path to custom configuration file
        
    .PARAMETER ProjectRoot
        Root directory of the project
    #>
    [CmdletBinding()]
    param(
        [string]$ConfigPath,
        [string]$ProjectRoot
    )
    
    try {
        # Determine project root
        if (-not $ProjectRoot) {
            $script:ProjectRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        }
        else {
            $script:ProjectRoot = $ProjectRoot
        }
        
        # Load default configuration
        $defaultConfigPath = Join-Path $script:ProjectRoot "config\default.json"
        if (-not (Test-Path $defaultConfigPath)) {
            throw "Default configuration file not found: $defaultConfigPath"
        }
        
        $script:Config = Get-Content $defaultConfigPath -Raw | ConvertFrom-Json
        Write-Verbose "Loaded default configuration from: $defaultConfigPath"
        
        # Load custom configuration if provided
        if ($ConfigPath -and (Test-Path $ConfigPath)) {
            $customConfig = Get-Content $ConfigPath -Raw | ConvertFrom-Json
            $script:Config = Merge-Configuration -Default $script:Config -Custom $customConfig
            Write-Verbose "Merged custom configuration from: $ConfigPath"
        }
        
        # Expand environment variables in paths
        Expand-ConfigurationPaths
        
        # Validate configuration
        Test-ConfigurationValid
        
        Write-Information "Configuration initialized successfully" -InformationAction Continue
        return $script:Config
    }
    catch {
        Write-Error "Failed to initialize configuration: $($_.Exception.Message)"
        throw
    }
}

function Merge-Configuration {
    <#
    .SYNOPSIS
        Recursively merges custom configuration with default configuration
    #>
    [CmdletBinding()]
    param(
        [psobject]$Default,
        [psobject]$Custom
    )
    
    $merged = $Default.PSObject.Copy()
    
    foreach ($property in $Custom.PSObject.Properties) {
        if ($merged.PSObject.Properties.Name -contains $property.Name) {
            if ($property.Value -is [psobject] -and $merged.($property.Name) -is [psobject]) {
                $merged.($property.Name) = Merge-Configuration -Default $merged.($property.Name) -Custom $property.Value
            }
            else {
                $merged.($property.Name) = $property.Value
            }
        }
        else {
            $merged | Add-Member -NotePropertyName $property.Name -NotePropertyValue $property.Value
        }
    }
    
    return $merged
}

function Expand-ConfigurationPaths {
    <#
    .SYNOPSIS
        Expands environment variables in configuration paths
    #>
    [CmdletBinding()]
    param()
    
    # Expand paths in packer configuration
    if ($script:Config.packer.oscdimg_path) {
        $script:Config.packer.oscdimg_path = [Environment]::ExpandEnvironmentVariables($script:Config.packer.oscdimg_path)
    }
    
    # Expand other paths as needed
    $script:Config.global.log_directory = [Environment]::ExpandEnvironmentVariables($script:Config.global.log_directory)
    $script:Config.global.temp_directory = [Environment]::ExpandEnvironmentVariables($script:Config.global.temp_directory)
}

function Test-ConfigurationValid {
    <#
    .SYNOPSIS
        Validates the loaded configuration
    #>
    [CmdletBinding()]
    param()
    
    $errors = @()
    
    # Validate required sections
    $requiredSections = @('global', 'packer', 'golden_image', 'vagrant', 'environments')
    foreach ($section in $requiredSections) {
        if (-not $script:Config.$section) {
            $errors += "Missing required configuration section: $section"
        }
    }
    
    # Validate memory settings
    foreach ($env in $script:Config.environments.PSObject.Properties) {
        $envConfig = $env.Value
        if ($envConfig.memory -lt $script:Config.validation.min_memory -or 
            $envConfig.memory -gt $script:Config.validation.max_memory) {
            $errors += "Invalid memory setting for environment '$($env.Name)': $($envConfig.memory)MB"
        }
    }
    
    if ($errors.Count -gt 0) {
        throw "Configuration validation failed:`n" + ($errors -join "`n")
    }
}

function Get-WorkflowConfig {
    <#
    .SYNOPSIS
        Returns the current workflow configuration
    #>
    [CmdletBinding()]
    param()
    
    if (-not $script:Config) {
        throw "Configuration not initialized. Call Initialize-WorkflowConfiguration first."
    }
    
    return $script:Config
}
#endregion

#region Logging Functions
function Initialize-WorkflowLogging {
    <#
    .SYNOPSIS
        Initializes logging for workflow operations
        
    .PARAMETER LogDirectory
        Directory for log files
        
    .PARAMETER ScriptName
        Name of the calling script
    #>
    [CmdletBinding()]
    param(
        [string]$LogDirectory,
        [string]$ScriptName
    )
    
    try {
        $config = Get-WorkflowConfig
        
        if (-not $LogDirectory) {
            $LogDirectory = $config.global.log_directory
        }
        
        if (-not (Test-Path $LogDirectory)) {
            $null = New-Item -ItemType Directory -Path $LogDirectory -Force
        }
        
        $timestamp = Get-Date -Format 'yyyy-MM-dd'
        if (-not $ScriptName) {
            $ScriptName = "workflow"
        }
        
        $script:LogPath = Join-Path $LogDirectory "${ScriptName}_${timestamp}.log"
        
        Start-Transcript -Path $script:LogPath -Force
        $script:TranscriptStarted = $true
        
        Write-Information "Logging initialized: $script:LogPath" -InformationAction Continue
        
        # Clean old logs
        $maxAge = $config.global.max_log_age_days
        Get-ChildItem $LogDirectory -Filter "*.log" -ErrorAction SilentlyContinue | 
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$maxAge) } |
        Remove-Item -Force -ErrorAction SilentlyContinue
        
    }
    catch {
        Write-Warning "Failed to initialize logging: $($_.Exception.Message)"
    }
}

function Stop-WorkflowLogging {
    <#
    .SYNOPSIS
        Stops workflow logging
    #>
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

function Write-WorkflowProgress {
    <#
    .SYNOPSIS
        Writes progress information with consistent formatting
        
    .PARAMETER Activity
        The current activity
        
    .PARAMETER Status
        Current status
        
    .PARAMETER PercentComplete
        Percentage complete (0-100)
        
    .PARAMETER Id
        Progress record ID
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Activity,
        
        [string]$Status = "Processing...",
        
        [ValidateRange(0, 100)]
        [int]$PercentComplete = -1,
        
        [int]$Id = 1
    )
    
    $progressParams = @{
        Activity = $Activity
        Status   = $Status
        Id       = $Id
    }
    
    if ($PercentComplete -ge 0) {
        $progressParams.PercentComplete = $PercentComplete
    }
    
    Write-Progress @progressParams
    Write-Information "$Activity - $Status" -InformationAction Continue
}
#endregion

#region Validation Functions
function Test-Prerequisites {
    <#
    .SYNOPSIS
        Tests for required tools and dependencies
        
    .PARAMETER IncludeOptional
        Also test for optional tools
    #>
    [CmdletBinding()]
    param(
        [switch]$IncludeOptional
    )
    
    Write-WorkflowProgress -Activity "Validating Prerequisites" -Status "Checking required tools..."
    
    $missing = @()
    $config = Get-WorkflowConfig
    
    # Required tools
    $requiredTools = @(
        @{ Name = 'packer'; Command = 'packer version'; Description = 'HashiCorp Packer' },
        @{ Name = 'vagrant'; Command = 'vagrant --version'; Description = 'HashiCorp Vagrant' }
    )
    
    foreach ($tool in $requiredTools) {
        try {
            $null = Invoke-Expression $tool.Command 2>$null
            Write-Verbose "$($tool.Description) found"
        }
        catch {
            $missing += $tool.Description
        }
    }
    
    # Find oscdimg.exe
    $oscdimgPath = Find-OscdimgPath
    if (-not $oscdimgPath) {
        $missing += 'oscdimg.exe (Windows ADK Deployment Tools)'
    }
    
    # Optional tools
    if ($IncludeOptional) {
        $optionalTools = @(
            @{ Name = 'choco'; Command = 'choco --version'; Description = 'Chocolatey Package Manager' },
            @{ Name = 'git'; Command = 'git --version'; Description = 'Git Version Control' }
        )
        
        foreach ($tool in $optionalTools) {
            try {
                $null = Invoke-Expression $tool.Command 2>$null
                Write-Verbose "$($tool.Description) found (optional)"
            }
            catch {
                Write-Verbose "$($tool.Description) not found (optional)"
            }
        }
    }
    
    if ($missing.Count -gt 0) {
        throw "Missing required tools: $($missing -join ', '). Please install these tools before continuing."
    }
    
    Write-Information "All prerequisites validated successfully" -InformationAction Continue
}

function Find-OscdimgPath {
    <#
    .SYNOPSIS
        Finds the oscdimg.exe executable
    #>
    [CmdletBinding()]
    param()
    
    $config = Get-WorkflowConfig
    $oscdimgPaths = $config.packer.oscdimg_path
    
    foreach ($path in $oscdimgPaths) {
        if (Test-Path $path) {
            $oscdimgDir = Split-Path $path -Parent
            
            # Add to PATH if not already there
            if ($env:PATH -notlike "*$oscdimgDir*") {
                $env:PATH += ";$oscdimgDir"
            }
            
            Write-Verbose "oscdimg.exe found at: $path"
            return $path
        }
    }
    
    return $null
}

function Test-HyperVEnvironment {
    <#
    .SYNOPSIS
        Validates Hyper-V environment and permissions
    #>
    [CmdletBinding()]
    param()
    
    Write-WorkflowProgress -Activity "Validating Environment" -Status "Checking Hyper-V..."
    
    # Check if Hyper-V is enabled
    $hyperVFeature = (Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V | Where-Object { $_.State -eq 'Enabled' })
    if (-not $hyperVFeature) {
        throw "Hyper-V is not enabled. Please enable Hyper-V before continuing."
    }
    
    # Check if user is in Hyper-V Administrators group
    $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($currentUser)
    $isAdmin = $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    
    if (-not $isAdmin) {
        Write-Warning "Not running as Administrator. Some operations may require elevated privileges."
    }
    
    # Check for virtual switch
    $config = Get-WorkflowConfig
    $switchName = $config.global.default_switch
    $virtualSwitch = Get-VMSwitch -Name $switchName -ErrorAction SilentlyContinue
    
    if (-not $virtualSwitch) {
        Write-Warning "Virtual switch '$switchName' not found. You may need to create it manually."
    }
    else {
        Write-Verbose "Virtual switch '$switchName' found ($($virtualSwitch.SwitchType))"
    }
    
    Write-Information "Hyper-V environment validation completed" -InformationAction Continue
}

function Test-IsoFile {
    <#
    .SYNOPSIS
        Validates an ISO file
        
    .PARAMETER Path
        Path to the ISO file
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )
    
    Write-WorkflowProgress -Activity "Validating ISO" -Status "Checking file: $Path"
    
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

function Find-WindowsServerIso {
    <#
    .SYNOPSIS
        Finds a Windows Server ISO file
    #>
    [CmdletBinding()]
    param()

    $config = Get-WorkflowConfig
    $isoPaths = $config.packer.default_iso_paths

    foreach ($path in $isoPaths) {
        if (Test-Path $path) {
            try {
                Test-IsoFile -Path $path
                Write-Information "Found valid Windows Server ISO: $path" -InformationAction Continue
                return $path
            }
            catch {
                Write-Verbose "ISO at $path is not valid: $($_.Exception.Message)"
            }
        }
    }
    return $null
}
#endregion

#region Utility Functions
function Invoke-WithRetry {
    <#
    .SYNOPSIS
        Executes a script block with retry logic
        
    .PARAMETER ScriptBlock
        The script block to execute
        
    .PARAMETER MaxAttempts
        Maximum number of attempts
        
    .PARAMETER DelaySeconds
        Delay between attempts in seconds
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [scriptblock]$ScriptBlock,
        
        [int]$MaxAttempts = 3,
        
        [int]$DelaySeconds = 5
    )
    
    $attempt = 1
    
    while ($attempt -le $MaxAttempts) {
        try {
            return & $ScriptBlock
        }
        catch {
            if ($attempt -eq $MaxAttempts) {
                throw "Failed after $MaxAttempts attempts: $($_.Exception.Message)"
            }
            
            Write-Warning "Attempt $attempt failed: $($_.Exception.Message). Retrying in $DelaySeconds seconds..."
            Start-Sleep -Seconds $DelaySeconds
            $attempt++
        }
    }
}

function Get-SafeVMName {
    <#
    .SYNOPSIS
        Sanitizes a VM name for file system compatibility
        
    .PARAMETER Name
        The proposed VM name
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )
    
    # Remove invalid characters for file names
    $safeName = $Name -replace '[<>:"/\\|?*]', '_'
    
    # Ensure it's not too long
    if ($safeName.Length -gt 50) {
        $safeName = $safeName.Substring(0, 50)
    }
    
    # Ensure it doesn't end with a period or space
    $safeName = $safeName.TrimEnd('. ')
    
    return $safeName
}

function ConvertTo-AbsolutePath {
    <#
    .SYNOPSIS
        Converts a relative path to an absolute path
        
    .PARAMETER Path
        The path to convert
        
    .PARAMETER BasePath
        Base path for relative paths (defaults to current location)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        
        [string]$BasePath = $PWD
    )
    
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $Path
    }
    else {
        return Join-Path $BasePath $Path
    }
}

function Test-IsElevated {
    <#
    .SYNOPSIS
        Tests if the current session is running with elevated privileges
    #>
    [CmdletBinding()]
    param()
    
    $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($currentUser)
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}
#endregion

#region Password Generation
function New-RandomSecurePassword {
    <#
    .SYNOPSIS
        A wrapper function for pgen for secure password generation.
        Provides kinder output and customizable word count and delimiters.
    
    .DESCRIPTION
        Creates a cryptographically secure random passphrase using pgen.exe.
        Generates random words with customizable delimiters for high entropy.
        Requires pgen.exe to be available in the system PATH.
        
    .PARAMETER WordCount
        Number of words to generate (default: 6)
        
    .PARAMETER Delimiter
        Delimiter to use between words (default: "-")
        
    .EXAMPLE
        $password = New-RandomSecurePassword
        
    .EXAMPLE
        $password = New-RandomSecurePassword -WordCount 8 -Delimiter "_"
        
    .EXAMPLE
        $password = New-RandomSecurePassword -WordCount 4 -Delimiter ""
    #>
    [CmdletBinding()]
    param(
        [int]$WordCount = 6,
        [string]$Delimiter = "-"
    )
    
    try {
        # Check if pgen.exe is available
        $pgenPath = Get-Command "pgen.exe" -ErrorAction SilentlyContinue
        if (-not $pgenPath) {
            throw "pgen.exe not found in PATH. Please install pgen.exe to generate secure passwords."
        }
        
        Write-Verbose "Using pgen.exe for secure password generation"
        
        # Generate words with specified delimiter to create a strong passphrase
        $pgenArgs = @("-n", $WordCount.ToString())
        if ($Delimiter) {
            $pgenArgs += @("-d", $Delimiter)
        }
        
        # Execute pgen.exe
        $pgenProcess = Start-Process -FilePath "pgen.exe" -ArgumentList $pgenArgs -PassThru -WindowStyle Hidden -Wait
        
        try {
            $pgenProcess.WaitForExit()
            if ($pgenProcess.ExitCode -ne 0) {
                throw "pgen.exe failed with exit code: $($pgenProcess.ExitCode)"
            }
        }
        finally {
            if ($pgenProcess) {
                $pgenProcess.Dispose()
                $pgenProcess = $null
            }
        }
        
        # Get the password from clipboard
        try {
            $password = Get-Clipboard -ErrorAction Stop
            if ([string]::IsNullOrWhiteSpace($password)) {
                throw "No password found in clipboard after pgen.exe execution"
            }
            
            # If clipboard contains multiple lines, take the first non-empty one
            if ($password -is [array]) {
                $password = ($password | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1)
            }
            
            $password = $password.ToString().Trim()
            
            if ([string]::IsNullOrWhiteSpace($password)) {
                throw "pgen.exe returned empty or whitespace-only result in clipboard"
            }
        }
        catch {
            throw "Failed to retrieve password from clipboard: $($_.Exception.Message)"
        }
        
        Write-Verbose "Generated password using pgen.exe: $($password.Length) characters"
        
        return ConvertTo-SecureString -String $password -AsPlainText -Force
    }
    catch {
        Write-Error "Failed to generate secure password: $($_.Exception.Message)"
        throw
    }
}

function New-CustomAutounattendXml {
    <#
    .SYNOPSIS
        Creates a customized autounattend.xml file with specified passwords
    
    .DESCRIPTION
        Takes a template autounattend.xml file and replaces password placeholders
        with actual secure passwords for automated Windows installation.
        
    .PARAMETER TemplateXmlPath
        Path to the template autounattend.xml file
        
    .PARAMETER OutputXmlPath
        Path where the customized autounattend.xml will be saved
        
    .PARAMETER AdminPasswordSecure
        SecureString containing the Administrator password
        
    .PARAMETER VagrantPasswordSecure
        SecureString containing the vagrant user password
        
    .PARAMETER WindowsVersion
        Windows version (2019 or 2025) for version-specific customizations
        
    .EXAMPLE
        New-CustomAutounattendXml -TemplateXmlPath "C:\template.xml" -OutputXmlPath "C:\custom.xml" -AdminPasswordSecure $adminPwd -VagrantPasswordSecure $vagrantPwd -WindowsVersion "2019"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$TemplateXmlPath,
        
        [Parameter(Mandatory)]
        [string]$OutputXmlPath,
        
        [Parameter(Mandatory)]
        [SecureString]$AdminPasswordSecure,
        
        [Parameter(Mandatory)]
        [SecureString]$VagrantPasswordSecure,
        
        [Parameter(Mandatory)]
        [ValidateSet('2019', '2025')]
        [string]$WindowsVersion
    )
    
    try {
        # Validate template file exists
        if (-not (Test-Path $TemplateXmlPath)) {
            throw "Template autounattend.xml file not found: $TemplateXmlPath"
        }
        
        # Convert SecureStrings to plain text (temporarily, for XML embedding)
        $adminPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($AdminPasswordSecure))
        $vagrantPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($VagrantPasswordSecure))
        
        try {
            # Read template content
            $xmlContent = Get-Content $TemplateXmlPath -Raw
            
            # Replace password placeholders
            $xmlContent = $xmlContent -replace '\{\{ADMIN_PASSWORD\}\}', $adminPassword
            $xmlContent = $xmlContent -replace '\{\{VAGRANT_PASSWORD\}\}', $vagrantPassword
            
            # Write customized content
            $xmlContent | Set-Content -Path $OutputXmlPath -Encoding UTF8
            
            Write-Information "Created customized autounattend.xml: $OutputXmlPath" -InformationAction Continue
        }
        finally {
            # Clear password variables immediately
            if ($adminPassword) {
                $adminPassword = $null
            }
            if ($vagrantPassword) {
                $vagrantPassword = $null
            }
        }
    }
    catch {
        Write-Error "Failed to create custom autounattend.xml: $($_.Exception.Message)"
        throw
    }
}

function Save-BuildCredentials {
    <#
    .SYNOPSIS
        Saves build credentials to a secure JSON file
    
    .DESCRIPTION
        Creates a JSON file containing the generated passwords and build information.
        This file should be secured or deleted after the passwords are noted.
        
    .PARAMETER AdminPasswordSecure
        SecureString containing the Administrator password
        
    .PARAMETER VagrantPasswordSecure
        SecureString containing the vagrant user password
        
    .PARAMETER OutputPath
        Path where the credentials JSON file will be saved
        
    .PARAMETER WindowsVersion
        Windows version for the build
        
    .EXAMPLE
        Save-BuildCredentials -AdminPasswordSecure $adminPwd -VagrantPasswordSecure $vagrantPwd -OutputPath "C:\credentials.json" -WindowsVersion "2019"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [SecureString]$AdminPasswordSecure,
        
        [Parameter(Mandatory)]
        [SecureString]$VagrantPasswordSecure,
        
        [Parameter(Mandatory)]
        [string]$OutputPath,
        
        [Parameter(Mandatory)]
        [string]$WindowsVersion
    )
    
    try {
        # Convert SecureStrings to plain text for JSON
        $adminPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($AdminPasswordSecure))
        $vagrantPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($VagrantPasswordSecure))
        
        try {
            # Create credentials object
            $credentials = @{
                CreatedDate = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                Notes = @(
                    "This file contains sensitive credentials for the Windows Server golden image.",
                    "Store this file securely and delete it after noting the credentials.",
                    "Both accounts have local administrator privileges.",
                    "The vagrant account is used for automated management via Vagrant.",
                    "Passwords are randomly generated using pgen.exe and meet complexity requirements."
                )
                Credentials = @{
                    Vagrant = @{
                        Username = "vagrant"
                        Password = $vagrantPassword
                        Description = "Vagrant user account"
                    }
                    Administrator = @{
                        Username = "Administrator"
                        Password = $adminPassword
                        Description = "Built-in Administrator account"
                    }
                }
                ComputerName = "WIN-TEMP-VM"
                WindowsVersion = $WindowsVersion
            }
            
            # Convert to JSON and save
            $credentials | ConvertTo-Json -Depth 3 | Set-Content -Path $OutputPath -Encoding UTF8
            
            Write-Information "Build credentials saved to: $OutputPath" -InformationAction Continue
        }
        finally {
            # Clear password variables immediately
            if ($adminPassword) {
                $adminPassword = $null
            }
            if ($vagrantPassword) {
                $vagrantPassword = $null
            }
        }
    }
    catch {
        Write-Error "Failed to save build credentials: $($_.Exception.Message)"
        throw
    }
}
#endregion

function Get-VersionSpecificPaths {
    <#
    .SYNOPSIS
        Gets version-specific file paths for Windows Server builds
    
    .DESCRIPTION
        Returns a hashtable containing all the version-specific paths needed for
        building a Windows Server golden image with Packer.
        
    .PARAMETER WindowsVersion
        Windows Server version (2019 or 2025)
        
    .PARAMETER PackerDir
        Base packer directory path
        
    .PARAMETER StorageRoot
        Storage root directory (optional, defaults to E:\vm_images)
        
    .EXAMPLE
        $paths = Get-VersionSpecificPaths -WindowsVersion "2019" -PackerDir "C:\packer"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('2019', '2025')]
        [string]$WindowsVersion,
        
        [Parameter(Mandatory)]
        [string]$PackerDir,
        
        [string]$StorageRoot = "E:\vm_images"
    )
    
    $paths = @{
        WindowsVersion = $WindowsVersion
        BoxName = "windows-server-$WindowsVersion"
        CustomIsoName = "custom_windows_server_$WindowsVersion.iso"
        AutoUnattend = Join-Path $PackerDir "autounattend-$WindowsVersion.xml"
        PackerConfig = Join-Path $PackerDir "windows-server-$WindowsVersion.pkr.hcl"
        OutputDir = Join-Path $StorageRoot "packer\output-hyperv-iso-$WindowsVersion"
        CredentialsFile = "windows-server-$WindowsVersion-credentials.json"
    }
    
    return $paths
}

#region Export Functions
# Export functions that should be available to other modules
if ($MyInvocation.MyCommand.Module) {
    Export-ModuleMember -Function @(
        'Initialize-WorkflowConfiguration',
        'Get-WorkflowConfig',
        'Initialize-WorkflowLogging',
        'Stop-WorkflowLogging',
        'Write-WorkflowProgress',
        'Test-Prerequisites',
        'Test-HyperVEnvironment',
        'Test-IsoFile',
        'Find-WindowsServerIso',
        'Find-OscdimgPath',
        'Invoke-WithRetry',
        'Get-SafeVMName',
        'ConvertTo-AbsolutePath',
        'Test-IsElevated',
        'Get-VersionSpecificPaths',
        'New-RandomSecurePassword',
        'New-CustomAutounattendXml',
        'Save-BuildCredentials'
    )
}
#endregion
