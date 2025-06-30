# Setup script for Vagrant + Packer on Hyper-V for Windows Server environments
# Run this script as Administrator

param(
    [switch]$SkipReboot,
    [switch]$ConfigureNetworking
)

# TODO
# Add installation/check for windows-sdk-10-version-2004

Write-Host ("=" * 60) 

Write-Host "Setting up Vagrant + Packer environment..." -ForegroundColor Green

# Check if running as Administrator
if (-NOT ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Host "This script requires Administrator privileges." -ForegroundColor Yellow
    Write-Host "Attempting to restart as Administrator..." -ForegroundColor Yellow
    
    # Build the argument list to pass the same parameters
    $ArgumentList = @()
    if ($SkipReboot) { $ArgumentList += "-SkipReboot" }
    if ($ConfigureNetworking) { $ArgumentList += "-ConfigureNetworking" }
    
    # Create the argument string
    $ArgumentString = if ($ArgumentList.Count -gt 0) { 
        "-File `"$PSCommandPath`" " + ($ArgumentList -join " ")
    }
    else { 
        "-File `"$PSCommandPath`""
    }
    
    try {
        # Start new PowerShell process as Administrator with same parameters
        Start-Process PowerShell -Verb RunAs -ArgumentList $ArgumentString -Wait
        exit 0
    }
    catch {
        Write-Error "Failed to restart as Administrator. Please manually run PowerShell as Administrator and try again."
        Write-Host "Command to run: PowerShell $ArgumentString" -ForegroundColor Yellow
        exit 1
    }
}

Write-Host ("=" * 60) 
Write-Host "Checking Hyper-V Administrator permissions..." -ForegroundColor Yellow
Write-Host ("=" * 60) 

# Check if user is in Hyper-V Administrators group
$CurrentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$IsInHyperVAdmins = $false

try {
    $HyperVAdminsGroup = [ADSI]"WinNT://./Hyper-V Administrators,group"
    $Members = $HyperVAdminsGroup.Members() | ForEach-Object { $_.GetType().InvokeMember("Name", "GetProperty", $null, $_, $null) }
    $IsInHyperVAdmins = $Members -contains $CurrentUser.Split('\')[-1]
}
catch {
    Write-Warning "Could not check Hyper-V Administrators group membership"
}

if (-not $IsInHyperVAdmins) {
    Write-Host "Adding current user to Hyper-V Administrators group..." -ForegroundColor Yellow
    try {
        $Username = $CurrentUser.Split('\')[-1]
        net localgroup "Hyper-V Administrators" $Username /add
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Successfully added $Username to Hyper-V Administrators group!" -ForegroundColor Green
            Write-Host "You will need to log out and log back in (or reboot) for the change to take effect." -ForegroundColor Yellow
            $RequiresLogoff = $true
        }
        else {
            Write-Warning "Failed to add user to Hyper-V Administrators group. You may need to add manually."
        }
    }
    catch {
        Write-Warning "Failed to add user to Hyper-V Administrators group: $($_.Exception.Message)"
        Write-Host "Please manually add your user account to the 'Hyper-V Administrators' group:" -ForegroundColor Yellow
        Write-Host "  1. Open Computer Management" -ForegroundColor Gray
        Write-Host "  2. Navigate to Local Users and Groups > Groups" -ForegroundColor Gray
        Write-Host "  3. Double-click 'Hyper-V Administrators'" -ForegroundColor Gray
        Write-Host "  4. Click 'Add' and add your user account" -ForegroundColor Gray
        Write-Host "  5. Log out and log back in (or reboot)" -ForegroundColor Gray
    }
}
else {
    Write-Host "User is already in Hyper-V Administrators group." -ForegroundColor Green
}

Write-Host ("=" * 60) 

# Install Chocolatey if not present
if (!(Get-Command choco -ErrorAction SilentlyContinue)) {
    Write-Host "Installing Chocolatey..." -ForegroundColor Yellow
    Set-ExecutionPolicy Bypass -Scope Process -Force
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
    Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
}

Write-Host ("=" * 60) 

# Install required software
Write-Host "Installing Packer and Vagrant..." -ForegroundColor Yellow
choco install packer vagrant -y

Write-Host ("=" * 60) 

# Install Vagrant plugins for Windows
Write-Host "Installing Vagrant plugins..." -ForegroundColor Yellow
vagrant plugin install vagrant-reload
vagrant plugin install vagrant-winrm

Write-Host ("=" * 60) 


# Enable Hyper-V features
Write-Host "Enabling Hyper-V features..." -ForegroundColor Yellow
$HyperVFeatures = @(
    "Microsoft-Hyper-V-All",
    "Microsoft-Hyper-V",
    "Microsoft-Hyper-V-Tools-All",
    "Microsoft-Hyper-V-Management-PowerShell",
    "Microsoft-Hyper-V-Hypervisor",
    "Microsoft-Hyper-V-Services",
    "Microsoft-Hyper-V-Management-Clients"
)

foreach ($Feature in $HyperVFeatures) {
    try {
        Enable-WindowsOptionalFeature -Online -FeatureName $Feature -All -NoRestart
        Write-Host "Enabled $Feature" -ForegroundColor Green
    }
    catch {
        Write-Warning "Could not enable $Feature - it may already be enabled or not available"
    }
}

Write-Host ("=" * 60) 


# Configure Hyper-V networking if requested
if ($ConfigureNetworking) {
    Write-Host "Configuring Hyper-V networking..." -ForegroundColor Yellow
    
    # Look for NIC Team first
    $NicTeam = Get-NetAdapter | Where-Object { $_.InterfaceDescription -like "*Team*" -or $_.Name -like "*Team*" } | Select-Object -First 1
    
    if (!$NicTeam) {
        # If no team found, look for any physical adapter
        $PhysicalAdapter = Get-NetAdapter | Where-Object { $_.PhysicalMediaType -eq "802.3" -and $_.Status -eq "Up" } | Select-Object -First 1
        if ($PhysicalAdapter) {
            Write-Host "No NIC Team found, using physical adapter: $($PhysicalAdapter.Name)" -ForegroundColor Yellow
            $AdapterToUse = $PhysicalAdapter.Name
        }
        else {
            Write-Warning "No suitable network adapter found. Creating internal switch instead."
            $AdapterToUse = $null
        }
    }
    else {
        Write-Host "Found NIC Team: $($NicTeam.Name)" -ForegroundColor Green
        $AdapterToUse = $NicTeam.Name
    }
    
    # Check if Virtual Switch VLAN Trunk already exists
    if (!(Get-VMSwitch -Name "Virtual Switch VLAN Trunk" -ErrorAction SilentlyContinue)) {
        if ($AdapterToUse) {
            # Create external switch attached to NIC Team or physical adapter
            New-VMSwitch -Name "Virtual Switch VLAN Trunk" -NetAdapterName $AdapterToUse -AllowManagementOS $true
            Write-Host "Created Virtual Switch VLAN Trunk attached to: $AdapterToUse" -ForegroundColor Green
        }
        else {
            # Fallback to internal switch
            New-VMSwitch -Name "Virtual Switch VLAN Trunk" -SwitchType Internal
            Write-Host "Created Virtual Switch VLAN Trunk (Internal)" -ForegroundColor Yellow
        }
    }
    else {
        Write-Host "Virtual Switch VLAN Trunk already exists" -ForegroundColor Yellow
        # Check what type of switch it is
        $ExistingSwitch = Get-VMSwitch -Name "Virtual Switch VLAN Trunk"
        Write-Host "Existing switch type: $($ExistingSwitch.SwitchType)" 
        if ($ExistingSwitch.NetAdapterInterfaceDescription) {
            Write-Host "Attached to: $($ExistingSwitch.NetAdapterInterfaceDescription)" 
        }
    }
    
    # Configure networking based on switch type
    $VirtualSwitch = Get-VMSwitch -Name "Virtual Switch VLAN Trunk" -ErrorAction SilentlyContinue
    if ($VirtualSwitch) {
        if ($VirtualSwitch.SwitchType -eq "External") {
            Write-Host "External switch detected - VMs will use DHCP from your network" -ForegroundColor Green
            Write-Host "VLAN 31 will be configured on individual VMs" 
        }
        elseif ($VirtualSwitch.SwitchType -eq "Internal") {
            Write-Host "Internal switch detected - configuring host IP and NAT..." -ForegroundColor Yellow
            
            # Configure IP for internal switch (original logic)
            try {
                $NetworkAdapter = Get-NetAdapter -Name "vEthernet (Virtual Switch VLAN Trunk)" -ErrorAction SilentlyContinue
                if ($NetworkAdapter) {
                    $ExistingIPAddress = Get-NetIPAddress -InterfaceAlias "vEthernet (Virtual Switch VLAN Trunk)" -AddressFamily IPv4 -ErrorAction SilentlyContinue
                    if (!$ExistingIPAddress -or $ExistingIPAddress.IPAddress -ne "10.1.3.250") {
                        New-NetIPAddress -IPAddress 10.1.3.250 -PrefixLength 24 -InterfaceAlias "vEthernet (Virtual Switch VLAN Trunk)" -ErrorAction SilentlyContinue
                        Write-Host "Configured IP for Virtual Switch VLAN Trunk" -ForegroundColor Green
                    }
                }
            }
            catch {
                Write-Warning "Could not configure IP for Virtual Switch VLAN Trunk - this may need to be done manually"
            }
            
            # Configure NAT for internal switch
            try {
                if (!(Get-NetNat -Name "vmNAT" -ErrorAction SilentlyContinue)) {
                    New-NetNat -Name "vmNAT" -InternalIPInterfaceAddressPrefix 10.1.3.0/24
                    Write-Host "Created vmNAT" -ForegroundColor Green
                }
                else {
                    Write-Host "vmNAT already exists" -ForegroundColor Yellow
                }
            }
            catch {
                Write-Warning "Could not create NAT - this may need to be done manually"
            }
        }
    }
}

Write-Host ("=" * 60) 

# Create project directories
$ProjectRoot = Split-Path -Parent $PSScriptRoot
Write-Host "Project structure created at: $ProjectRoot" -ForegroundColor Green

# Install windows sdk deployment tools if not present
try { 
    if (!(Get-Command "WindowsSDKDeploymentTools" -ErrorAction SilentlyContinue)) {
        Write-Host "Installing Windows SDK Deployment Tools..." -ForegroundColor Yellow
        choco install windows-sdk-10.1 -y
    }
    else {
        Write-Host "Windows SDK Deployment Tools already installed." -ForegroundColor Green
    } 
}
catch {
    Write-Warning "Failed to install Windows SDK Deployment Tools: $($_.Exception.Message)"
}

Write-Host "`nSetup complete!" -ForegroundColor Green
Write-Host "`nNext steps:" 
Write-Host "1. Restart your computer if Hyper-V was just enabled" -ForegroundColor White
Write-Host "2. Test with: cd vagrant\simple && vagrant up" -ForegroundColor White
Write-Host "3. Build custom Windows Server image: cd packer && packer build windows-server-2025.pkr.hcl" -ForegroundColor White

# Check if a reboot/logoff is needed
$NeedsRestart = $false
if ((Get-Variable -Name RequiresLogoff -ErrorAction SilentlyContinue) -and $RequiresLogoff) {
    Write-Host "`nIMPORTANT: You were added to the Hyper-V Administrators group." -ForegroundColor Yellow
    Write-Host "You must log out and log back in (or reboot) for Packer to work properly." -ForegroundColor Yellow
    $NeedsRestart = $true
}

if (!$SkipReboot) {
    if ($NeedsRestart) {
        $RebootChoice = Read-Host "`nA reboot/logoff is REQUIRED for group membership changes. Reboot now? (Y/n)"
        if ($RebootChoice -ne 'n' -and $RebootChoice -ne 'N') {
            Write-Host "Rebooting..." -ForegroundColor Yellow
            Restart-Computer -Force
        }
        else {
            Write-Host "Please log out and log back in before running Packer!" -ForegroundColor Red
        }
    }
    else {
        $RebootChoice = Read-Host "`nA reboot is recommended to ensure Hyper-V is properly enabled. Reboot now? (y/N)"
        if ($RebootChoice -eq 'y' -or $RebootChoice -eq 'Y') {
            Write-Host "Rebooting..." -ForegroundColor Yellow
            Restart-Computer -Force
        }
    }
}
