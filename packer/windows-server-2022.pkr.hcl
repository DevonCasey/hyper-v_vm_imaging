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
  description = "URL or path to Windows Server 2022 ISO"
  default     = "F:\\Install\\Microsoft\\Windows Server\\WinServer_2022.iso"
}

variable "VirtualMachineName" {
  type    = string
  default = "windows-server-2022"
}

variable "OutputDirectory" {
  type    = string
  default = "output-hyperv-iso"
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

source "hyperv-iso" "windows-server-2022" {
  vm_name          = var.VirtualMachineName
  iso_url          = var.iso_url
  iso_checksum     = "none"
  output_directory = var.OutputDirectory
  
  # VM resources
  cpus         = 4
  memory       = 4096
  disk_size    = 65536  # 64 GB
  generation   = 2
  
  # Hyper-V specific settings
  switch_name                       = var.switch_name
  enable_secure_boot                = false
  enable_virtualization_extensions  = false
  enable_tpm                        = false
  guest_additions_mode              = "disable"
  
  # Boot settings - since autounattend.xml is in the main ISO now
  boot_wait = "10s"
  boot_command = [
    "<spacebar><wait1s>",
    "<enter><wait10s>"
  ]
  
  # NO secondary ISO needed - autounattend.xml is in main ISO
  # secondary_iso_images = [] # Removed this line
  
  # Communication settings
  communicator     = "winrm"
  winrm_username   = var.WinRMUsername
  winrm_password   = var.WinRMPassword
  winrm_timeout    = "60m"
  winrm_port       = 5985
  winrm_use_ssl    = false
  winrm_insecure   = true
  winrm_use_ntlm   = false
  
  # Shutdown command
  shutdown_command = "shutdown /s /t 10 /f /d p:4:1 /c \"Packer Shutdown\""
  shutdown_timeout = "15m"
}

build {
  name = "windows-server-2022"
  sources = ["source.hyperv-iso.windows-server-2022"]
  
  # ENHANCED: Better initial wait and connectivity test
  provisioner "powershell" {
    inline = [
      "Write-Host 'Waiting for system to be fully ready...'",
      "Start-Sleep -Seconds 120",  # INCREASED: Longer wait for full boot
      "Write-Host 'Testing basic connectivity...'",
      "Test-NetConnection -ComputerName localhost -Port 5985",
      "Write-Host 'System ready, continuing with provisioning...'"
    ]
    timeout = "10m"
  }
  
  # Verify WinRM is working properly
  provisioner "powershell" {
    inline = [
      "Write-Host 'Testing WinRM connectivity and configuration...'",
      "Get-Service WinRM | Select-Object Status, StartType",
      "winrm get winrm/config/service",
      "Write-Host 'WinRM is operational and properly configured'"
    ]
    timeout = "5m"
  }
  
  # Install Chocolatey (useful for package management)
  provisioner "powershell" {
    inline = [
      "Write-Host 'Installing Chocolatey...'",
      "Set-ExecutionPolicy Bypass -Scope Process -Force",
      "[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072",
      "try {",
      "  iex ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))",
      "  Write-Host 'Chocolatey installed successfully'",
      "} catch {",
      "  Write-Warning \"Chocolatey installation failed: $($_.Exception.Message)\"",
      "}"
    ]
    timeout = "15m"
  }
  
  # Configure Windows Updates (more robust approach)
  provisioner "powershell" {
    inline = [
      "Write-Host 'Configuring Windows Updates...'",
      "try {",
      "  if (!(Get-Module -ListAvailable -Name PSWindowsUpdate)) {",
      "    Write-Host 'Installing PSWindowsUpdate module...'",
      "    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force",
      "    Install-Module PSWindowsUpdate -Force -Scope AllUsers",
      "  }",
      "  Import-Module PSWindowsUpdate -Force",
      "  Write-Host 'Getting available updates...'",
      "  $updates = Get-WindowsUpdate -Category 'Critical Updates','Security Updates' -AcceptAll",
      "  if ($updates) {",
      "    Write-Host \"Found $($updates.Count) critical/security updates\"",
      "    Install-WindowsUpdate -AcceptAll -AutoReboot:$false -Confirm:$false",
      "    Write-Host 'Critical updates installed'",
      "  } else {",
      "    Write-Host 'No critical updates available'",
      "  }",
      "} catch {",
      "  Write-Warning \"Windows Updates failed: $($_.Exception.Message)\"",
      "  Write-Host 'Continuing without updates...'",
      "}"
    ]
    timeout = "45m"  # INCREASED: More time for updates
  }
  
  # Install .NET Framework 4.8 (if not present)
  provisioner "powershell" {
    inline = [
      "Write-Host 'Checking .NET Framework version...'",
      "$netVersion = Get-ItemProperty 'HKLM:SOFTWARE\\Microsoft\\NET Framework Setup\\NDP\\v4\\Full\\' -Name Release -ErrorAction SilentlyContinue",
      "if ($netVersion -and $netVersion.Release -lt 528040) {",
      "  Write-Host 'Installing .NET Framework 4.8...'",
      "  try {",
      "    choco install dotnetfx -y",
      "    Write-Host '.NET Framework 4.8 installed'",
      "  } catch {",
      "    Write-Warning \"Failed to install .NET Framework: $($_.Exception.Message)\"",
      "  }",
      "} else {",
      "  Write-Host '.NET Framework 4.8 or later already installed'",
      "}"
    ]
    timeout = "20m"
  }
  
  # Configure Vagrant user and SSH
  provisioner "powershell" {
    inline = [
      "Write-Host 'Configuring Vagrant user...'",
      "# Ensure vagrant user exists and is configured properly",
      "try {",
      "  $user = Get-LocalUser -Name 'vagrant' -ErrorAction Stop",
      "  Write-Host 'Vagrant user exists'",
      "} catch {",
      "  Write-Host 'Creating vagrant user...'",
      "  $password = ConvertTo-SecureString 'vagrant' -AsPlainText -Force",
      "  New-LocalUser -Name 'vagrant' -Password $password -FullName 'Vagrant User' -Description 'Vagrant SSH User'",
      "}",
      "# Ensure vagrant user is in administrators group",
      "Add-LocalGroupMember -Group 'Administrators' -Member 'vagrant' -ErrorAction SilentlyContinue",
      "# Set password to never expire",
      "Set-LocalUser -Name 'vagrant' -PasswordNeverExpires $true",
      "# Configure auto-login",
      "Set-ItemProperty -Path 'HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Winlogon' -Name 'AutoAdminLogon' -Value '1'",
      "Set-ItemProperty -Path 'HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Winlogon' -Name 'DefaultUserName' -Value 'vagrant'",
      "Set-ItemProperty -Path 'HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Winlogon' -Name 'DefaultPassword' -Value 'vagrant'",
      "Write-Host 'Vagrant user configured successfully'"
    ]
    timeout = "5m"
  }
  
  # Configure WinRM more robustly
  provisioner "powershell" {
    inline = [
      "Write-Host 'Configuring WinRM for Vagrant...'",
      "# Enable WinRM and configure for Vagrant",
      "Enable-PSRemoting -Force -SkipNetworkProfileCheck",
      "winrm quickconfig -q -force",
      "winrm set winrm/config/winrs '@{MaxMemoryPerShellMB=\"0\"}'",
      "winrm set winrm/config '@{MaxTimeoutms=\"1800000\"}'",
      "winrm set winrm/config/service '@{AllowUnencrypted=\"true\"}'",
      "winrm set winrm/config/service/auth '@{Basic=\"true\"}'",
      "winrm set winrm/config/client/auth '@{Basic=\"true\"}'",
      "winrm set winrm/config/listener?Address=*+Transport=HTTP '@{Port=\"5985\"}'",
      "# Configure firewall",
      "netsh advfirewall firewall set rule group='Windows Remote Management' new enable=yes",
      "netsh advfirewall firewall add rule name='WinRM-HTTP' dir=in localport=5985 protocol=TCP action=allow",
      "# Restart WinRM service",
      "Restart-Service winrm -Force",
      "Write-Host 'WinRM configured successfully'"
    ]
    timeout = "10m"
  }
  
  # Install OpenSSH Server (useful for Vagrant)
  provisioner "powershell" {
    inline = [
      "Write-Host 'Installing OpenSSH Server...'",
      "try {",
      "  Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0",
      "  Start-Service sshd",
      "  Set-Service -Name sshd -StartupType 'Automatic'",
      "  # Configure SSH for Vagrant",
      "  $sshDir = 'C:\\Users\\vagrant\\.ssh'",
      "  New-Item -Path $sshDir -ItemType Directory -Force",
      "  # Download Vagrant public key",
      "  try {",
      "    Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/hashicorp/vagrant/master/keys/vagrant.pub' -OutFile '$sshDir\\authorized_keys'",
      "    # Set proper permissions",
      "    icacls '$sshDir' /inheritance:r /grant 'vagrant:F' /grant 'SYSTEM:F'",
      "    icacls '$sshDir\\authorized_keys' /inheritance:r /grant 'vagrant:F' /grant 'SYSTEM:F'",
      "    Write-Host 'SSH configured successfully'",
      "  } catch {",
      "    Write-Warning \"Failed to download SSH key: $($_.Exception.Message)\"",
      "  }",
      "} catch {",
      "  Write-Warning \"OpenSSH installation failed: $($_.Exception.Message)\"",
      "}"
    ]
    timeout = "15m"
  }
  
  # Configure UAC and other Windows settings
  provisioner "powershell" {
    inline = [
      "Write-Host 'Configuring Windows settings...'",
      "# Disable UAC",
      "Set-ItemProperty -Path 'HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\System' -Name 'EnableLUA' -Value 0",
      "# Disable Windows Defender real-time protection",
      "try {",
      "  Set-MpPreference -DisableRealtimeMonitoring $true",
      "  Write-Host 'Windows Defender real-time protection disabled'",
      "} catch {",
      "  Write-Warning \"Could not disable Windows Defender: $($_.Exception.Message)\"",
      "}",
      "# Disable Windows Update automatic restart",
      "Set-ItemProperty -Path 'HKLM:\\SOFTWARE\\Microsoft\\WindowsUpdate\\UX\\Settings' -Name 'UxOption' -Value 1 -ErrorAction SilentlyContinue",
      "# Show file extensions",
      "Set-ItemProperty -Path 'HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced' -Name 'HideFileExt' -Value 0 -ErrorAction SilentlyContinue",
      "# Disable Server Manager at startup",
      "try {",
      "  Get-ScheduledTask -TaskName ServerManager | Disable-ScheduledTask",
      "  Write-Host 'Server Manager startup disabled'",
      "}"
    ]
  }
}
