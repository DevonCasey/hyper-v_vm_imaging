# Hyper-V VM Imaging Workflow

[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-blue.svg)](https://github.com/PowerShell/PowerShell)
[![Vagrant](https://img.shields.io/badge/Vagrant-2.3%2B-blue.svg)](https://www.vagrantup.com/)
[![Packer](https://img.shields.io/badge/Packer-1.9%2B-blue.svg)](https://www.packer.io/)
[![Windows Server](https://img.shields.io/badge/Windows%20Server-2025-blue.svg)](https://www.microsoft.com/en-us/windows-server)

A streamlined workflow for creating Windows Server 2025 VMs with comprehensive error handling, interactive configuration, and enterprise-grade features.

## 🎯 Quick Start

### 1. **One-Command Setup**

```powershell
# Run as Administrator - This sets up everything!
.\scripts\Initialize-HyperVEnvironment.ps1 -Interactive
```

### 2. **Build Your First Golden Image**

```powershell
.\scripts\Build-WeeklyGoldenImage.ps1 -Interactive
```

### 3. **Deploy Your First VM**

```powershell
cd vagrant\barebones
vagrant up --provider=hyperv
```

## 📋 Prerequisites

### System Requirements

- **OS**: Windows 10 Pro/Enterprise or Windows Server 2016+
- **Memory**: 8GB+ RAM (16GB recommended)
- **Storage**: 50GB+ free disk space
- **CPU**: Intel VT-x or AMD-V with Hyper-V support
- **Network**: Internet connection for downloads

### Required Software

The setup script will install these automatically:

- HashiCorp Packer 1.9+
- HashiCorp Vagrant 2.3+
- Chocolatey Package Manager
- Windows Assessment and Deployment Kit (ADK)
- PowerShell 5.1+ (built-in on Windows 10+)

## 🔧 Configuration Management

### Configuration Files

The system uses centralized JSON configuration:

```
config/
├── default.json          # Main configuration
├── environments.json     # VM environment definitions (optional)
└── user-overrides.json   # User customizations (optional)
```

### Key Configuration Options

```json
{
  "golden_image": {
    "box_name": "windows-server-2025-golden",
    "rebuild_interval_days": 7
  },
  "environments": {
    "barebones": {
      "memory": 2048,
      "cpus": 2,
      "default_drive_size": 25
    },
    "dev-box": {
      "memory": 8192,
      "cpus": 4,
      "default_drive_size": 50
    }
  }
}
```

## 🏗️ Project Structure (v2.0)

```
├── config/                    # 🆕 Centralized configuration
│   ├── default.json          #     Main configuration file
│   └── validation.schema.json #     Configuration validation
├── scripts/
│   ├── core/                 # 🆕 Core functionality modules
│   │   ├── Common.ps1        #     Common functions and utilities
│   │   ├── Build.ps1         #     Build-specific functions
│   │   └── VagrantBox.ps1    #     Vagrant box management
│   ├── Build-WeeklyGoldenImage.ps1 # 🔄 Enhanced build script
│   ├── Initialize-HyperVEnvironment.ps1 # 🔄 Enhanced setup script
│   └── utils/                # 🆕 Utility scripts
├── packer/
│   ├── windows-server-2025.pkr.hcl # 🔄 Updated Packer config
│   ├── autounattend.xml       #     Unattended installation
│   └── scripts/               #     Provisioning scripts
├── vagrant/
│   ├── shared/               # 🆕 Shared Vagrant components
│   │   └── common.rb         #     Common Ruby functions
│   ├── barebones/            # 🔄 Enhanced environments
│   ├── fileserver/
│   ├── dev-box/
│   ├── domain-controller/
│   └── iis-server/
└── docs/                     # 🆕 Enhanced documentation
    ├── troubleshooting.md
    ├── advanced-usage.md
    └── api-reference.md
```

## 🎮 Interactive Mode

### Setup Wizard

```powershell
.\scripts\Initialize-HyperVEnvironment.ps1 -Interactive
```

Features:

- ✨ **Welcome Screen**: System information and prerequisites check
- 🔧 **Component Selection**: Choose what to install/configure
- 🌐 **Network Configuration**: Guided Hyper-V networking setup
- ✅ **Validation**: Comprehensive system validation
- 📊 **Progress Tracking**: Real-time progress indicators

### Build Wizard

```powershell
.\scripts\Build-WeeklyGoldenImage.ps1 -Interactive
```

Features:

- 🎯 **Configuration Menu**: Customize build settings
- 📈 **Build Status**: Real-time build progress and ETA
- 🔍 **System Information**: Detailed environment status
- ⚙️ **Settings Management**: Save and load custom configurations

## 🏢 Available VM Environments

| Environment           | Description             | Memory | CPUs | Use Case                         |
| --------------------- | ----------------------- | ------ | ---- | -------------------------------- |
| **barebones**         | Minimal Windows Server  | 2GB    | 2    | Testing, minimal deployments     |
| **fileserver**        | File & Storage Server   | 4GB    | 4    | File sharing, storage management |
| **dev-box**           | Development Environment | 8GB    | 4    | Software development             |
| **domain-controller** | Active Directory        | 4GB    | 4    | Domain services, authentication  |
| **iis-server**        | Web Server              | 4GB    | 4    | Web hosting, applications        |

### Deployment Examples

```powershell
# Interactive deployment with custom configuration
cd vagrant\dev-box
set VAGRANT_INTERACTIVE=true
vagrant up --provider=hyperv

# Quick deployment with defaults
cd vagrant\fileserver
vagrant up --provider=hyperv

# Check VM status
vagrant status
vagrant rdp  # Connect via RDP
```

## 🔄 Golden Image Management

### Automatic Weekly Builds

```powershell
# Set up automatic weekly builds
.\scripts\Build-WeeklyGoldenImage.ps1 -ScheduleWeekly
```

### Manual Build Options

```powershell
# Check if rebuild is needed
.\scripts\Build-WeeklyGoldenImage.ps1 -CheckOnly

# Force rebuild regardless of age
.\scripts\Build-WeeklyGoldenImage.ps1 -Force

# Build with custom configuration
.\scripts\Build-WeeklyGoldenImage.ps1 -ConfigPath ".\my-config.json"
```

### Build Status Monitoring

```powershell
# View current golden image status
.\scripts\Build-WeeklyGoldenImage.ps1 -CheckOnly

# Output example:
# Golden Image Status:
# Box: windows-server-2025-golden
# Age: 3 days
# Last Modified: 2025-06-27 14:30:15
# Rebuild Needed: No
```

## 🔧 Advanced Configuration

### Custom VM Configuration

```ruby
# In your environment's Vagrantfile
vm_config = {
  name: "my-custom-server",
  memory: 6144,
  cpus: 3,
  drive_size: 75,
  fixed_size: true
}
```

### Environment Variables

```powershell
# Enable interactive mode
$env:VAGRANT_INTERACTIVE = "true"

# Custom configuration path
$env:HYPERV_CONFIG_PATH = "C:\my-configs\hyperv.json"

# Debug mode
$env:PACKER_LOG = "1"
```

### Network Configuration Options

```powershell
# External switch (production)
.\scripts\Initialize-HyperVEnvironment.ps1 -ConfigureNetworking

# Internal switch with NAT (testing)
# Selected automatically during interactive setup
```

## 🚨 Troubleshooting

### Common Issues and Solutions

#### "Golden image box not found"

```powershell
# Solution: Build the golden image first
.\scripts\Build-WeeklyGoldenImage.ps1 -Force
```

#### "Hyper-V Administrators group" error

```powershell
# Solution: Add user to group and reboot
net localgroup "Hyper-V Administrators" %USERNAME% /add
# Then reboot or log out/in
```

#### "oscdimg.exe not found"

```powershell
# Solution: Reinstall Windows ADK
.\scripts\Initialize-HyperVEnvironment.ps1 -Force
```

#### VM fails to start

```powershell
# Check Hyper-V virtual switch
Get-VMSwitch
# Recreate if needed
.\scripts\Initialize-HyperVEnvironment.ps1 -ConfigureNetworking -Force
```

### Debug Mode

```powershell
# Enable verbose logging
$VerbosePreference = "Continue"
.\scripts\Build-WeeklyGoldenImage.ps1 -Verbose

# Enable Packer debug logging
$env:PACKER_LOG = "1"
$env:PACKER_LOG_PATH = "C:\logs\packer-debug.log"
```

## 📊 Monitoring and Maintenance

### Health Checks

```powershell
# System health check
.\scripts\Test-SystemHealth.ps1

# VM environment validation
.\scripts\Test-VMEnvironments.ps1

# Golden image validation
.\scripts\Test-GoldenImage.ps1
```

### Maintenance Tasks

```powershell
# Clean up old VMs
.\scripts\Cleanup-OldVMs.ps1

# Update Vagrant boxes
vagrant box outdated --global
vagrant box update --box windows-server-2025-golden

# Clean Packer cache
.\scripts\Cleanup-PackerCache.ps1
```

### Security Best Practices

```powershell
# Change default credentials (in config/default.json)
{
  "vagrant": {
    "default_credentials": {
      "username": "vmadmin",
      "password": "SecurePassword123!"
    }
  }
}

# Enable additional firewall rules only as needed
# Configure VLAN isolation for sensitive environments
```

## 🎯 Performance Optimization

### Resource Allocation

```json
{
  "environments": {
    "high-performance": {
      "memory": 16384,
      "cpus": 8,
      "enable_enhanced_session_mode": true,
      "linked_clone": false
    }
  }
}
```

## 🤝 Development Setup

```powershell
# Clone the repository
git clone <repository-url>
cd hyperv-vm-workflow

# Install development dependencies
.\scripts\Install-DevDependencies.ps1

# Run tests
.\scripts\Test-AllComponents.ps1
```

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

---
