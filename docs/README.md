# Hyper-V VM Imaging with Packer and Vagrant

This project automates the creation of Windows Server golden images using Packer and provides Vagrant environments for rapid VM deployment on Hyper-V.

## Overview

The system consists of two main components:
1. **Packer Build Process**: Creates golden images from Windows Server ISOs
2. **Vagrant Deployment**: Deploys pre-configured VMs from golden images

## Prerequisites

Before using this system, ensure you have the following installed:

- **Windows 10/11 Pro** or **Windows Server** with Hyper-V enabled
- **PowerShell 5.1+** (Windows PowerShell or PowerShell Core)
- **Packer** (latest version)
- **Vagrant** (latest version)
- **Windows ADK** (Assessment and Deployment Kit)
- **pgen.exe** (for secure password generation)

### Quick Setup

Run the initialization script to automatically install missing prerequisites:

```powershell
.\scripts\Initialize-HyperVEnvironment.ps1
```

## Building Golden Images with Packer

### Basic Usage

The main build script handles the entire golden image creation process:

```powershell
# Build Windows Server 2019 (default)
.\scripts\Build-GoldenImage.ps1

# Build Windows Server 2025
.\scripts\Build-GoldenImage.ps1 -WindowsVersion 2025

# Force rebuild even if image is recent
.\scripts\Build-GoldenImage.ps1 -Force

# Interactive mode with menus
.\scripts\Build-GoldenImage.ps1 -Interactive
```

### Advanced Options

```powershell
# Use specific ISO file
.\scripts\Build-GoldenImage.ps1 -IsoPath "F:\ISOs\WinServer_2019.iso"

# Custom box name
.\scripts\Build-GoldenImage.ps1 -BoxName "my-custom-server-2019"

# Create only the custom ISO (no VM build)
.\scripts\Build-GoldenImage.ps1 -CreateIsoOnly -IsoPath "F:\ISOs\WinServer_2019.iso"

# Check if rebuild is needed
.\scripts\Build-GoldenImage.ps1 -CheckOnly
```

### Build Process Overview

1. **Environment Validation**: Checks prerequisites 
2. **Custom ISO Creation**: Embeds `autounattend.xml` with random passwords into the Windows ISO
3. **Packer Build**: Automated VM creation and configuration (30-60 minutes)
4. **Vagrant Box Packaging**: Creates `.box` file and adds to Vagrant
5. **Cleanup**: Removes temporary files and custom ISOs for security

### Storage Locations

- **Original ISOs**: `F:\Install\Microsoft\Windows Server\` (auto-detected)
- **Golden Images**: `E:\vm_images\`
- **Vagrant Boxes**: `E:\vm_images\vagrant\`
- **Build Artifacts**: `E:\packer\`

## Using Vagrant Environments

Once you have built golden images, you can deploy VMs using the pre-configured Vagrant environments.

### Available Environments

Navigate to the `vagrant/` directory to find these pre-built environments:

```
vagrant/
├── barebones/          # Minimal Windows Server
├── dev-box/           # Development workstation
├── domain-controller/ # Active Directory domain controller
├── fileserver/        # File server with configurable storage
├── iis-server/        # Web server with IIS
└── shared/            # Common configuration files
```

### Basic Vagrant Commands

```powershell
# Navigate to desired environment
cd vagrant\barebones

# Start the VM
vagrant up

# Connect via RDP/console
vagrant rdp

# SSH/WinRM into the VM
vagrant winrm

# Stop the VM
vagrant halt

# Restart the VM
vagrant reload

# Destroy the VM
vagrant destroy

# Check VM status
vagrant status
```

### Environment-Specific Usage

#### Barebones Server
```powershell
cd vagrant\barebones
vagrant up
# Minimal Windows Server - general purpose
# Optional: Prompts to join a domain during interactive setup
```

#### Development Box
```powershell
cd vagrant\dev-box
vagrant up
# Includes development tools, Visual Studio Code, Git, etc.
```

#### Domain Controller
```powershell
cd vagrant\domain-controller
vagrant up
# Automatically promotes to domain controller
# Domain: example.local
# Default admin credentials in build output
```

#### File Server
```powershell
cd vagrant\fileserver
vagrant up
# Prompts for drive configuration (letter, size, fixed/dynamic)
# Creates [Drive]:\Shares folder automatically
# Configure SMB shares manually as needed
```

#### IIS Web Server
```powershell
cd vagrant\iis-server
vagrant up
# IIS installed and configured
# Sample website deployed
# Access via VM IP address
```

### Vagrant Box Management

```powershell
# List available boxes
vagrant box list

# Add a box manually
vagrant box add my-server-2019 E:\vm_images\vagrant\my-server-2019.box

# Remove a box
vagrant box remove my-server-2019

# Update boxes
vagrant box update
```

### Networking

By default, VMs use Hyper-V's default switch for NAT networking. To customize:

1. **Edit Vagrantfile** in the environment directory
2. **Modify network settings**:
   ```ruby
   config.vm.network "public_network", bridge: "External Switch"
   config.vm.network "private_network", ip: "192.168.1.100"
   ```

### Credentials and Access

#### Getting VM Credentials

Credentials are saved after each build:

```powershell
# View saved credentials
Get-Content E:\packer\windows-server-2019-credentials.json
```

#### Default Accounts

- **Administrator**: Random secure password (check credentials file)
- **vagrant**: Random secure password (used by Vagrant)

#### Console Access Warnings

⚠️ **During Build**: Do NOT connect to VM console during Packer build process
✅ **After Build**: Safe to connect via `vagrant rdp` or Hyper-V Manager

## Common Workflows

### 1. Weekly Golden Image Refresh

```powershell
# Build fresh golden image
.\scripts\Build-GoldenImage.ps1 -Force

# Deploy test environment
cd vagrant\barebones
vagrant destroy -f
vagrant up
```

### 2. Development Environment Setup

```powershell
# Build development-ready image
.\scripts\Build-GoldenImage.ps1 -BoxName "dev-server-2019"

# Deploy development box
cd vagrant\dev-box
# Edit Vagrantfile to use "dev-server-2019" box
vagrant up
```

### 3. Multi-VM Lab Environment

```powershell
# Start domain controller
cd vagrant\domain-controller
vagrant up

# Start file server (will prompt for configuration)
cd ..\fileserver  
vagrant up

# Start web server
cd ..\iis-server
vagrant up
```

### 4. File Server Configuration

```powershell
# Deploy file server
cd vagrant\fileserver
vagrant up
# Follow prompts to configure drive (letter, size, type)

# After deployment, configure SMB shares
vagrant winrm
# Inside VM:
New-SmbShare -Name "Public" -Path "E:\Shares\Public" -FullAccess "Everyone"
```

### 5. Domain-Joined Server

```powershell
# Deploy barebones server with domain join
cd vagrant\barebones
vagrant up
# When prompted:
# - Choose to join domain: y
# - Enter domain FQDN: contoso.local
# - Enter domain username: CONTOSO\admin
# - Enter domain password: (hidden input)

# Server will attempt to join domain during provisioning
# Note: VM may need restart to complete domain join
```

## Troubleshooting

### Build Issues

```powershell
# Check build logs
Get-Content packer\packer-build.log

# Validate environment
.\scripts\Build-GoldenImage.ps1 -CheckOnly

# Clean up failed builds
Remove-Item E:\packer\output-* -Recurse -Force
```

### Vagrant Issues

```powershell
# Reset Vagrant environment
vagrant destroy -f
vagrant up

# Check VM status in Hyper-V
Get-VM

# Restart Vagrant services
vagrant halt
vagrant up
```

### Storage Issues

```powershell
# Check available space
Get-WmiObject -Class Win32_LogicalDisk | Select-Object DeviceID, FreeSpace, Size

# Clean up old boxes
vagrant box prune
```

### Network Issues

```powershell
# Check Hyper-V switches
Get-VMSwitch

# Reset VM network
vagrant reload
```

## Configuration

### Build Configuration

Edit `config\default.json` to customize:

```json
{
  "golden_image": {
    "rebuild_interval_days": 7,
    "default_box_name": "windows-server-2019"
  }
}
```

### Vagrant Configuration

Each environment has its own `Vagrantfile`. Common customizations:

```ruby
# Memory and CPU
config.vm.provider "hyperv" do |hv|
  hv.memory = 4096
  hv.cpus = 2
end

# Shared folders
config.vm.synced_folder ".", "/vagrant", disabled: true
config.vm.synced_folder "data", "c:/data"

# Provisioning scripts
config.vm.provision "shell", path: "setup.ps1"
```

## Security Notes

- ✅ **Fresh passwords** generated for each build
- ✅ **Custom ISOs** cleaned up after build
- ✅ **Credentials** saved only after successful builds
- ⚠️ **Secure credential files** after use
- ⚠️ **Each build** creates unique passwords

## File Structure

```
├── scripts/
│   ├── Build-GoldenImage.ps1     # Main build script
│   ├── Initialize-HyperVEnvironment.ps1
│   └── core/Common.psm1          # Shared functions
├── packer/
│   ├── windows-server-2019.pkr.hcl
│   ├── windows-server-2025.pkr.hcl
│   ├── autounattend-2019.xml
│   ├── autounattend-2025.xml
│   └── scripts/                  # Packer provisioning scripts
├── vagrant/
│   ├── barebones/Vagrantfile
│   ├── dev-box/Vagrantfile
│   ├── domain-controller/Vagrantfile
│   ├── fileserver/Vagrantfile
│   ├── iis-server/Vagrantfile
│   └── shared/common.rb          # Shared Vagrant configuration
├── config/
│   └── default.json              # Build configuration
└── docs/
    └── README.md                 # This file
```

## Getting Help

1. **Check logs**: `packer\packer-build.log`
2. **Validate environment**: `.\scripts\Build-GoldenImage.ps1 -CheckOnly`
3. **View system info**: Use `-Interactive` mode, option 7
4. **Common issues**: See Troubleshooting section above

## Quick Start Example

```powershell
# 1. Initialize environment
.\scripts\Initialize-HyperVEnvironment.ps1

# 2. Build golden image (30-60 minutes)
.\scripts\Build-GoldenImage.ps1

# 3. Deploy a VM
cd vagrant\barebones
vagrant up

# 4. Connect to VM
vagrant rdp

# 5. Clean up when done
vagrant destroy
```

This creates a complete, automated Windows Server environment ready for development, testing, or production use.
