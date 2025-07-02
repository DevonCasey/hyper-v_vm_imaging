# Build-GoldenImage.ps1

[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-blue.svg)](https://github.com/PowerShell/PowerShell)
[![Vagrant](https://img.shields.io/badge/Vagrant-2.3%2B-blue.svg)](https://www.vagrantup.com/)
[![Packer](https://img.shields.io/badge/Packer-1.9%2B-blue.svg)](https://www.packer.io/)
[![Windows Server](https://img.shields.io/badge/Windows%20Server-2025-blue.svg)](https://www.microsoft.com/en-us/windows-server)

A PowerShell script that automates the creation of Windows Server golden images using Packer and Vagrant.

## Quick Start

```powershell
# Basic build with Windows Server 2019
.\Build-GoldenImage.ps1

# Build with Windows Server 2025
.\Build-GoldenImage.ps1 -WindowsVersion 2025

# Force rebuild even if image is recent
.\Build-GoldenImage.ps1 -Force

# Interactive mode with menus
.\Build-GoldenImage.ps1 -Interactive
```

## What It Does

1. **Creates a custom Windows ISO** with automated installation
2. **Builds a VM** using Packer 
3. **Packages the VM** as a Vagrant box for deployment

## Main Options

| Parameter | Description | Example |
|-----------|-------------|---------|
| `-WindowsVersion` | Windows Server version (2019 or 2025) | `-WindowsVersion 2025` |
| `-Force` | Force rebuild even if image is recent | `-Force` |
| `-Interactive` | Show menus and prompts | `-Interactive` |
| `-IsoPath` | Path to original Windows Server ISO | `-IsoPath "C:\ISOs\WinServer_2025.iso"` |
| `-BoxName` | Custom name for the Vagrant box | `-BoxName "my-windows-box"` |
| `-CheckOnly` | Just check if rebuild is needed | `-CheckOnly` |
| `-CreateIsoOnly` | Create custom ISO and exit | `-CreateIsoOnly -IsoPath "C:\ISOs\WinServer.iso"` |

## Requirements

- **PowerShell 5.1+**
- **Packer** (for building VMs)
- **Vagrant** (for packaging boxes)
- **Hyper-V** (enabled and configured)
- **Windows ADK** (for ISO creation)
- **pgen.exe** (for secure password generation)
- **Windows ISO** (you know why)


## Examples

### Basic Usage
```powershell
# Build Windows Server 2019 (default)
.\Build-GoldenImage.ps1

# Build Windows Server 2025
.\Build-GoldenImage.ps1 -WindowsVersion 2025
```

### With Custom ISO
```powershell
# Use specific ISO file
.\Build-GoldenImage.ps1 -IsoPath "F:\ISOs\WinServer_2025.iso" -WindowsVersion 2025
```

### Interactive Mode
```powershell
# Get guided menus
.\Build-GoldenImage.ps1 -Interactive
```

### Check Status
```powershell
# See if rebuild is needed
.\Build-GoldenImage.ps1 -CheckOnly
```

### ISO Only
```powershell
# Just create custom ISO
.\Build-GoldenImage.ps1 -CreateIsoOnly -IsoPath "C:\ISOs\WinServer.iso" -WindowsVersion 2025
```

## Output

After a successful build, you'll get:
- **Vagrant box** ready for deployment
- **Credential file** with the passwords used

## Using the Generated Box

The script creates Vagrant boxes that work with the included Vagrantfiles in the `vagrant/` directory:

- **`vagrant/barebones/`** - Minimal Windows Server setup
- **`vagrant/dev-box/`** - Development environment with tools
- **`vagrant/domain-controller/`** - Active Directory domain controller
- **`vagrant/fileserver/`** - File server configuration
- **`vagrant/iis-server/`** - IIS web server setup

To deploy a VM:
```powershell
# Navigate to desired environment
cd ..\vagrant\dev-box

# Start the VM
vagrant up --provider=hyperv

# Connect via RDP or WinRM
vagrant rdp
```

## Troubleshooting

If the build fails:
1. Check that Hyper-V is enabled
2. Verify all required tools are installed
3. Ensure sufficient disk space on E: drive
4. Run as Administrator if needed
5. Check the Packer log files for details

## Storage

The script uses `E:\vm_images\` for output files.
Make sure you have enough space (typically 20-30 GB per build).
