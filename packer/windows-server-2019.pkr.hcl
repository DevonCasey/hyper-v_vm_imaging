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
  description = "URL or path to Windows Server 2019 ISO"
  default     = "F:\\Install\\Microsoft\\Windows Server\\WinServer_2019.iso"
}

variable "VirtualMachineName" {
  type    = string
  default = "windows-server-2019"
}

variable "OutputDirectory" {
  type    = string
  default = "E:\\packer\\output-hyperv-iso-2019"
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

variable "vlan_id" {
  type        = number
  description = "VLAN ID to assign to the VM network adapter"
  default     = 31
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
  default = 64512  # 63 GB for OS drive
}

variable "enable_secure_boot" {
  type        = bool
  description = "Enable Secure Boot for the VM"
  default     = false
}

variable "enable_tpm" {
  type        = bool
  description = "Enable TPM (Trusted Platform Module) for the VM"
  default     = false
}

source "hyperv-iso" "windows-server-2019" {
  vm_name          = var.VirtualMachineName
  iso_url          = var.iso_url
  iso_checksum     = "none"  # TODO: Add proper checksum validation
  output_directory = var.OutputDirectory
  
  # VM resources - Generation 2 (UEFI)
  cpus       = var.cpus
  memory     = var.memory
  disk_size  = var.disk_size
  generation = 2
  
  # Hyper-V specific settings
  switch_name                      = var.switch_name
  vlan_id                         = var.vlan_id

  enable_secure_boot               = var.enable_secure_boot
  enable_virtualization_extensions = false
  enable_tpm                       = var.enable_tpm
  guest_additions_mode             = "disable"
  enable_mac_spoofing              = false
  enable_dynamic_memory            = false
  
  # Boot settings - Give more time for autounattend.xml to complete
  boot_wait = "10s"
  boot_command = [
    # Just press enter and wait for autounattend.xml to take over
    "<enter><wait180s>"  # Increased wait time for WinRM setup
  ]
  
  # Communication settings - Extended timeouts for Windows 2019
  communicator     = "winrm"
  winrm_username   = var.WinRMUsername
  winrm_password   = var.WinRMPassword
  winrm_timeout    = "180m" # Extended timeout for Windows updates and initial setup
  winrm_port       = 5985
  winrm_use_ssl    = false
  winrm_insecure   = true
  winrm_use_ntlm   = false
  
  # Host IP detection - workaround for Hyper-V API deprecation warnings
  winrm_host       = ""     # Let Packer auto-detect the IP
  host_port_min    = 2222   # Start port range for host forwarding
  host_port_max    = 4444   # End port range for host forwarding
  
  # Shutdown command
  shutdown_command = "shutdown /s /t 10 /f /d p:4:1 /c \"Packer Shutdown\""
  shutdown_timeout = "15m"
}

build {
  name = "windows-server-2019"
  sources = ["source.hyperv-iso.windows-server-2019"]
  
  # Wait for system to be fully ready and test WinRM connectivity
  provisioner "powershell" {
    inline = [
      "Write-Host 'WinRM Connection Established Successfully!' -ForegroundColor Green",
      "Write-Host '===========================================' -ForegroundColor Yellow",
      "Write-Host 'System Information:' -ForegroundColor Yellow",
      "Write-Host \"Computer: $env:COMPUTERNAME\"",
      "Write-Host \"User: $env:USERNAME\"",
      "Write-Host \"PowerShell Version: $($PSVersionTable.PSVersion)\"",
      "",
      "Write-Host 'Network Configuration:' -ForegroundColor Yellow",
      "$ip = (Get-NetIPAddress -AddressFamily IPv4 -InterfaceAlias '*Ethernet*' | Where-Object {$_.IPAddress -notlike '169.254.*' -and $_.IPAddress -ne '127.0.0.1'} | Select-Object -First 1).IPAddress",
      "Write-Host \"Primary IP Address: $ip\"",
      "Get-NetConnectionProfile | Format-Table Name, NetworkCategory, InterfaceAlias",
      "",
      "Write-Host 'WinRM Service Status:' -ForegroundColor Yellow",
      "Get-Service WinRM | Format-Table Status, StartType, Name",
      "Write-Host 'WinRM Listeners:' -ForegroundColor Yellow",
      "winrm enumerate winrm/config/listener",
      "",
      "Write-Host 'Testing WinRM connectivity...' -ForegroundColor Yellow",
      "try { Test-WSMan -ComputerName localhost; Write-Host 'WinRM Self-Test: PASSED' -ForegroundColor Green } catch { Write-Host 'WinRM Self-Test: FAILED' -ForegroundColor Red; $_ }",
      "",
      "Write-Host 'Firewall Status:' -ForegroundColor Yellow",
      "netsh advfirewall show allprofiles state",
      "Write-Host 'Port 5985 Status:' -ForegroundColor Yellow",
      "netstat -an | findstr :5985",
      "",
      "Write-Host 'Waiting additional time for system stability...' -ForegroundColor Cyan",
      "Start-Sleep -Seconds 30",
      "Write-Host 'System ready for provisioning.' -ForegroundColor Green"
    ]
    timeout = "10m"
  }
  
  # Basic system configuration
  provisioner "powershell" {
    scripts = [
      "scripts/01-configure-windows.ps1",
      "scripts/02-install-updates.ps1"
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
  }
  
  # Create Vagrant-specific configuration
  provisioner "powershell" {
    inline = [
      "Set-ItemProperty -Path 'HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\System' -Name 'LocalAccountTokenFilterPolicy' -Value 1 -Type DWord",
      "Set-ItemProperty -Path 'HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\System' -Name 'EnableLUA' -Value 0 -Type DWord",
      "New-ItemProperty -Path 'HKLM:\\SOFTWARE\\Microsoft\\ServerManager' -Name 'DoNotOpenServerManagerAtLogon' -Value 1 -PropertyType DWord -Force",
      "Write-Host 'Vagrant configuration completed'",
    ]
  }
}
