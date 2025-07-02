# Packer vs Vagrant: Separation of Concerns

This document explains the architectural changes made to properly separate concerns between Packer (base image creation) and Vagrant (environment provisioning).

## Architecture Overview

### Packer's Role: Base Image Creation
Packer should focus on creating a clean, stable, updated base image that serves as a foundation for all environments.

**Packer is responsible for:**
- Operating system installation and configuration
- Windows updates and patches
- Essential system configuration (WinRM, power settings, timezone)
- Basic security hardening appropriate for a base image
- Creating a stable, reproducible base image

**Packer should NOT:**
- Install development tools or applications
- Configure environment-specific settings
- Install package managers like Chocolatey
- Make changes that are specific to particular use cases

### Vagrant's Role: Environment Provisioning
Vagrant should handle the provisioning of specific environments on top of the clean base image.

**Vagrant is responsible for:**
- Installing development tools and applications
- Configuring development environment settings
- Installing package managers (Chocolatey, etc.)
- Setting up project-specific configurations
- Creating data drives and storage configurations
- Installing programming languages, IDEs, and utilities

## Implementation

### Packer Configuration Changes

The Packer build now only includes essential scripts:

1. **01-configure-windows.ps1** - Basic WinRM configuration for connectivity
2. **02-install-updates.ps1** - Essential system settings for base image
4. **98-validate-build.ps1** - Validate the base image
5. **99-cleanup.ps1** - Clean up the base image

**Removed from Packer:**
- Chocolatey installation
- Tool installation
- Development environment configuration
- Application-specific settings

### Vagrant Provisioning Scripts

New modular provisioning scripts in `vagrant/shared/scripts/`:

1. **install-chocolatey.ps1** - Install Chocolatey package manager
2. **install-common-tools.ps1** - Install common utilities (parameterized)
3. **configure-dev-environment.ps1** - Development-specific configuration

### Benefits of This Approach

1. **Faster Base Image Creation**: Packer builds are faster and more reliable
2. **Flexible Environments**: Different Vagrant boxes can have different tool sets
3. **Easier Maintenance**: Tool updates happen in Vagrant, not base image rebuilds
4. **Better Separation**: Clear distinction between infrastructure and application layers
5. **Reusable Base Images**: One base image can serve multiple environment types

## Migration Guide

### For Existing Environments

1. **Update Packer configurations** to remove tool installation scripts
2. **Move tool installation** to Vagrant provisioning scripts
3. **Use shared scripts** for common provisioning tasks
4. **Rebuild base images** with the new minimal configuration

### For New Environments

1. **Start with the clean base image** created by Packer
2. **Use shared provisioning scripts** for common tools
3. **Add environment-specific provisioning** as needed
4. **Keep tools and applications in Vagrant**, not Packer

## Example Workflow

1. **Create Base Image** (Packer):
   ```bash
   packer build windows-server-2019.pkr.hcl
   ```

2. **Provision Development Environment** (Vagrant):
   ```bash
   cd vagrant/dev-box
   vagrant up
   ```

3. **Update Tools** (Vagrant only):
   - Modify Vagrant provisioning scripts
   - Run `vagrant provision` to update existing VMs
   - No need to rebuild the base image

## Best Practices

### Packer Best Practices
- Keep the base image minimal and stable
- Only include updates and configuration needed by ALL environments
- Avoid installing software that might become outdated
- Focus on system-level configuration, not application-level

### Vagrant Best Practices
- Use shared scripts for common tools across environments
- Parameterize scripts to make them reusable
- Group related installations together in logical provisioning blocks
- Handle installation failures gracefully
- Document environment-specific requirements

## Directory Structure

```
packer/
├── scripts/
│   ├── 01-configure-winrm.ps1          # Essential WinRM setup
│   ├── 02-configure-base-system.ps1    # Basic system configuration
│   ├── 05-install-updates.ps1          # Windows updates
│   ├── 98-validate-build.ps1           # Validation
│   └── 99-cleanup.ps1                  # Cleanup
└── windows-server-2019.pkr.hcl         # Minimal Packer configuration

vagrant/
├── shared/
│   └── scripts/
│       ├── install-chocolatey.ps1      # Chocolatey installation
│       ├── install-common-tools.ps1    # Common tools (parameterized)
│       └── configure-dev-environment.ps1 # Dev environment settings
├── dev-box/
│   └── Vagrantfile                     # Development environment
├── domain-controller/
│   └── Vagrantfile                     # Domain controller environment
└── iis-server/
    └── Vagrantfile                     # IIS server environment
```

This architecture provides a cleaner separation of concerns and makes the system more maintainable and flexible.
