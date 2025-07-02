# Golden Image Selection Demo

This example shows how the enhanced Vagrant configuration now dynamically selects golden images.

## How It Works

When you run `vagrant up`, the system will:

1. **Scan for Available Boxes**: Automatically detect installed Vagrant boxes that match golden image patterns
2. **Interactive Selection**: Present a menu of available options
3. **Smart Defaults**: Fall back to sensible defaults if no interaction is provided

## Example Session

```
> vagrant up

===============================================================
DEV-BOX Environment - Golden Image Selection
===============================================================
Choose which golden image to use for this environment:
--------------------------------------------------
1. windows-server-2019-golden [✓ Available]
2. windows-server-2025-golden [✓ Available]  
3. windows-server-2022-golden [✗ Not Found]
4. Enter custom box name
--------------------------------------------------
Select golden image (1-4, default: 1): 2

Selected: windows-server-2025-golden
===============================================================

=== Available Golden Images ===
Choose which golden image to use for this VM:
--------------------------------------------------
Enter VM name: my-dev-vm
Enter data drive name: Development
Enter size for D: drive (GB): 100
Fixed size drive? (y/n, default n): n

Bringing machine 'default' up with 'hyperv' provider...
```

## Benefits

- **Flexibility**: Choose different base images for different environments
- **Visibility**: See which boxes are actually available vs missing
- **Convenience**: Sensible defaults for automated deployments
- **Consistency**: Same interface across all Vagrant environments

## Management Commands

Use the new management script to handle golden images:

```powershell
# List available golden images
.\scripts\Manage-GoldenImages.ps1 -List

# Get detailed info about a specific box
.\scripts\Manage-GoldenImages.ps1 -Info -BoxName "windows-server-2019-golden"

# Clean up old boxes
.\scripts\Manage-GoldenImages.ps1 -Clean
```

## Environment Types

Each environment type can now select from available golden images:

- **dev-box**: Development environment with full tooling
- **barebones**: Minimal server environment
- **domain-controller**: Active Directory server
- **iis-server**: Web server environment
- **fileserver**: File sharing server

The same golden image can be used as a base for multiple environment types, with specific tools and configurations applied during Vagrant provisioning.
