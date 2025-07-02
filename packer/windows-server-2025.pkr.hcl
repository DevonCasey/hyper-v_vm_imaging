packer {
  required_plugins {
    hyperv = {
      version = ">= 1.0.0"
      source  = "github.com/hashicorp/hyperv"
    }
  }
}

variable "iso_url" {
  type        = string
  description = "URL or path to Windows Server 2025 ISO"
  default     = "F:\\Install\\Microsoft\\Windows Server\\WinServer_2025.iso"
}

variable "VirtualMachineName" {
  type    = string
  default = "windows-server-2025"
}

variable "OutputDirectory" {
  type    = string
  default = "E:\\packer\\output-hyperv-iso"
}

variable "WinRMUsername" {
  type    = string
  default = "vagrant"
}

variable "WinRMPassword" {
  type    = string
  default = "vagrant"
}

variable "switch_name" {
  type    = string
  default = "Virtual Switch VLAN Trunk"
}

variable "cpus" {
  type    = number
  default = 4
}

variable "memory" {
  type    = number
  default = 4096
}

variable "disk_size" {
  type    = number
  default = 65536
}

variable "enable_secure_boot" {
  type        = bool
  description = "Enable Secure Boot for the VM"
  default     = true
}

variable "enable_tpm" {
  type        = bool
  description = "Enable TPM (Trusted Platform Module) for the VM"
  default     = true
}

source "hyperv-iso" "windows-server-2025" {
  vm_name          = var.VirtualMachineName
  iso_url          = var.iso_url
  iso_checksum     = "none" # TODO: Add proper checksum validation
  output_directory = var.OutputDirectory

  # VM resources - Generation 2 (UEFI)
  cpus       = var.cpus
  memory     = var.memory
  disk_size  = var.disk_size
  generation = 2

  # Hyper-V specific settings - Minimal for troubleshooting
  switch_name                      = var.switch_name
  enable_secure_boot               = false  # Disabled for troubleshooting
  enable_virtualization_extensions = false
  enable_tpm                       = false  # Disabled for troubleshooting
  guest_additions_mode             = "disable"
  enable_mac_spoofing              = false
  enable_dynamic_memory            = false

  # Boot settings - Let Windows handle everything automatically
  boot_wait = "1s"
  boot_command = [
    # No input - let autounattend.xml handle everything
    "<wait120s>"
  ]

  # Communication settings
  communicator   = "winrm"
  winrm_username = var.WinRMUsername
  winrm_password = var.WinRMPassword
  winrm_timeout  = "120m" # Increased timeout for Windows updates and restarts
  winrm_port     = 5985
  winrm_use_ssl  = false
  winrm_insecure = true
  winrm_use_ntlm = false

  # Shutdown command
  shutdown_command = "shutdown /s /t 10 /f /d p:4:1 /c \"Packer Shutdown\""
  shutdown_timeout = "15m"
}

build {
  name    = "windows-server-2025"
  sources = ["source.hyperv-iso.windows-server-2025"]

  # Wait for system to be fully ready
  provisioner "powershell" {
    inline = [
      "Write-Host 'Waiting for system to be fully ready...' -ForegroundColor Yellow",
      "Start-Sleep -Seconds 30", # Shorter wait for initial check
      "Write-Host 'Testing basic connectivity...' -ForegroundColor Yellow",
      "Test-NetConnection -ComputerName localhost -Port 5985 -InformationLevel Quiet",
      "Write-Host 'System ready, continuing with provisioning...' -ForegroundColor Green"
    ]
    timeout = "15m"
  }

  # Basic system configuration using external scripts
  provisioner "powershell" {
    scripts = [
      "scripts/01-configure-winrm.ps1",
      "scripts/02-install-chocolatey.ps1",
      "scripts/03-install-tools.ps1",
      "scripts/04-configure-windows.ps1",
      "scripts/05-install-updates.ps1"
    ]
    valid_exit_codes = [0, 1, 2, 3010]
    timeout = "120m" # Increased timeout for Windows updates
  }
  
  # Final cleanup and preparation
  provisioner "powershell" {
    scripts = [
      "scripts/99-cleanup.ps1"
    ]
    valid_exit_codes = [0, 1, 2]
    timeout = "30m"
  }

  # Create Vagrant-specific configuration
  provisioner "powershell" {
    inline = [
      "# Configure for Vagrant",
      "Set-ItemProperty -Path 'HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\System' -Name 'LocalAccountTokenFilterPolicy' -Value 1 -Type DWord",
      "Set-ItemProperty -Path 'HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\System' -Name 'EnableLUA' -Value 0 -Type DWord",
      "Write-Host 'Vagrant configuration completed'"
    ]
  }
}