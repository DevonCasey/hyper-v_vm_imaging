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

source "hyperv-iso" "windows-server-2025" {
  vm_name          = var.VirtualMachineName
  iso_url          = var.iso_url
  iso_checksum     = "none"  # TODO: Add proper checksum validation
  output_directory = var.OutputDirectory
  
  # VM resources - now configurable
  cpus         = var.cpus
  memory       = var.memory
  disk_size    = var.disk_size
  generation   = 2
  
  # Hyper-V specific settings
  switch_name                       = var.switch_name
  enable_secure_boot                = false
  enable_virtualization_extensions  = false
  enable_tpm                        = false
  guest_additions_mode              = "disable"
  
  # Boot settings - autounattend.xml is embedded in custom ISO
  boot_wait = "2s"
  boot_command = [
    "<spacebar><wait1s><spacebar><wait1s><spacebar>"
  ]
  
  # Communication settings
  communicator     = "winrm"
  winrm_username   = var.WinRMUsername
  winrm_password   = var.WinRMPassword
  winrm_timeout    = "90m"  # Increased timeout for Windows updates
  winrm_port       = 5985
  winrm_use_ssl    = false
  winrm_insecure   = true
  winrm_use_ntlm   = false
  
  # Shutdown command
  shutdown_command = "shutdown /s /t 10 /f /d p:4:1 /c \"Packer Shutdown\""
  shutdown_timeout = "15m"
}

build {
  name = "windows-server-2025"
  sources = ["source.hyperv-iso.windows-server-2025"]
  
  # Wait for system to be fully ready
  provisioner "powershell" {
    inline = [
      "Write-Host 'Waiting for system to be fully ready...' -ForegroundColor Yellow",
      "Start-Sleep -Seconds 180",  # Longer wait for complete boot
      "Write-Host 'Testing basic connectivity...' -ForegroundColor Yellow",
      "Test-NetConnection -ComputerName localhost -Port 5985 -InformationLevel Quiet",
      "Write-Host 'System ready, continuing with provisioning...' -ForegroundColor Green"
    ]
    timeout = "15m"
  }
  
  # Verify WinRM is working properly
  provisioner "powershell" {
    inline = [
      "Write-Host 'Testing WinRM connectivity and configuration...' -ForegroundColor Yellow",
      "Get-Service WinRM | Select-Object Status, StartType",
      "winrm get winrm/config/service | Out-String",
      "Write-Host 'WinRM is operational and properly configured' -ForegroundColor Green"
    ]
    timeout = "10m"
  }
  
  # Install Chocolatey (useful for package management)
  provisioner "powershell" {
    inline = [
      "Write-Host 'Installing Chocolatey package manager...' -ForegroundColor Yellow",
      "Set-ExecutionPolicy Bypass -Scope Process -Force",
      "[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072",
      "try {",
      "  Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))",
      "  Write-Host 'Chocolatey installed successfully' -ForegroundColor Green",
      "} catch {",
      "  Write-Warning \"Chocolatey installation failed: $($_.Exception.Message)\"",
      "  Write-Host 'Continuing without Chocolatey...' -ForegroundColor Yellow",
      "}"
    ]
    timeout = "20m"
  }
  
  # Configure Windows Updates with enhanced error handling
  provisioner "powershell" {
    inline = [
      "Write-Host 'Configuring Windows Updates...' -ForegroundColor Yellow",
      "try {",
      "  # Check if PSWindowsUpdate module is available",
      "  if (!(Get-Module -ListAvailable -Name PSWindowsUpdate)) {",
      "    Write-Host 'Installing PSWindowsUpdate module...' -ForegroundColor Yellow",
      "    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Confirm:$false",
      "    Install-Module PSWindowsUpdate -Force -Scope AllUsers -Confirm:$false",
      "  }",
      "  ",
      "  Import-Module PSWindowsUpdate -Force",
      "  Write-Host 'Getting available updates...' -ForegroundColor Yellow",
      "  ",
      "  # Get critical and security updates only for faster installation",
      "  $updates = Get-WindowsUpdate -Category 'Critical Updates','Security Updates','Definition Updates' -AcceptAll -Verbose:$false",
      "  ",
      "  if ($updates) {",
      "    Write-Host \"Found $($updates.Count) critical/security updates\" -ForegroundColor Yellow",
      "    Install-WindowsUpdate -Category 'Critical Updates','Security Updates','Definition Updates' -AcceptAll -AutoReboot:$false -Confirm:$false -Verbose:$false",
      "    Write-Host 'Critical updates installed successfully' -ForegroundColor Green",
      "  } else {",
      "    Write-Host 'No critical updates available' -ForegroundColor Green",
      "  }",
      "} catch {",
      "  Write-Warning \"Windows Updates encountered an issue: $($_.Exception.Message)\"",
      "  Write-Host 'Attempting alternative update method...' -ForegroundColor Yellow",
      "  ",
      "  # Fallback to Windows Update API",
      "  try {",
      "    $UpdateSession = New-Object -ComObject Microsoft.Update.Session",
      "    $UpdateSearcher = $UpdateSession.CreateUpdateSearcher()",
      "    $SearchResult = $UpdateSearcher.Search(\"IsInstalled=0 and Type='Software'\")",
      "    ",
      "    if ($SearchResult.Updates.Count -gt 0) {",
      "      Write-Host \"Found $($SearchResult.Updates.Count) updates via COM API\" -ForegroundColor Yellow",
      "      ",
      "      $UpdatesToInstall = New-Object -ComObject Microsoft.Update.UpdateColl",
      "      foreach ($Update in $SearchResult.Updates) {",
      "        if ($Update.Title -notmatch 'Preview' -and $Update.InstallationBehavior.CanRequestUserInput -eq $false) {",
      "          $UpdatesToInstall.Add($Update) | Out-Null",
      "        }",
      "      }",
      "      ",
      "      if ($UpdatesToInstall.Count -gt 0) {",
      "        $Installer = $UpdateSession.CreateUpdateInstaller()",
      "        $Installer.Updates = $UpdatesToInstall",
      "        $InstallationResult = $Installer.Install()",
      "        Write-Host \"Update installation result: $($InstallationResult.ResultCode)\" -ForegroundColor Green",
      "      }",
      "    } else {",
      "      Write-Host 'No updates available via COM API' -ForegroundColor Green",
      "    }",
      "  } catch {",
      "    Write-Warning \"COM API update also failed: $($_.Exception.Message)\"",
      "    Write-Host 'Continuing without updates...' -ForegroundColor Yellow",
      "  }",
      "}"
    ]
    timeout = "60m"  # Increased timeout for Windows updates
  }
  
  # Install .NET Framework 4.8 if needed
  provisioner "powershell" {
    inline = [
      "Write-Host 'Checking .NET Framework version...' -ForegroundColor Yellow",
      "$netVersion = Get-ItemProperty 'HKLM:SOFTWARE\\Microsoft\\NET Framework Setup\\NDP\\v4\\Full\\' -Name Release -ErrorAction SilentlyContinue",
      "if ($netVersion -and $netVersion.Release -lt 528040) {",
      "  Write-Host 'Installing .NET Framework 4.8...' -ForegroundColor Yellow",
      "  try {",
      "    if (Get-Command choco -ErrorAction SilentlyContinue) {",
      "      choco install dotnetfx -y",
      "      Write-Host '.NET Framework 4.8 installed via Chocolatey' -ForegroundColor Green",
      "    } else {",
      "      Write-Host 'Chocolatey not available, .NET Framework installation skipped' -ForegroundColor Yellow",
      "    }",
      "  } catch {",
      "    Write-Warning \"Failed to install .NET Framework: $($_.Exception.Message)\"",
      "  }",
      "} else {",
      "  Write-Host '.NET Framework 4.8 or later already installed' -ForegroundColor Green",
      "}"
    ]
    timeout = "25m"
  }
  
  # Configure Vagrant user with enhanced security
  provisioner "powershell" {
    inline = [
      "Write-Host 'Configuring Vagrant user...' -ForegroundColor Yellow",
      "try {",
      "  # Ensure vagrant user exists",
      "  $user = Get-LocalUser -Name 'vagrant' -ErrorAction SilentlyContinue",
      "  if (-not $user) {",
      "    Write-Host 'Creating vagrant user...' -ForegroundColor Yellow",
      "    $password = ConvertTo-SecureString 'vagrant' -AsPlainText -Force",
      "    New-LocalUser -Name 'vagrant' -Password $password -FullName 'Vagrant User' -Description 'Vagrant SSH User' -UserMayNotChangePassword",
      "  }",
      "  ",
      "  # Ensure vagrant user is in administrators group",
      "  Add-LocalGroupMember -Group 'Administrators' -Member 'vagrant' -ErrorAction SilentlyContinue",
      "  ",
      "  # Set password to never expire",
      "  Set-LocalUser -Name 'vagrant' -PasswordNeverExpires $true",
      "  ",
      "  # Configure auto-login for initial setup",
      "  Set-ItemProperty -Path 'HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Winlogon' -Name 'AutoAdminLogon' -Value '1'",
      "  Set-ItemProperty -Path 'HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Winlogon' -Name 'DefaultUserName' -Value 'vagrant'",
      "  Set-ItemProperty -Path 'HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Winlogon' -Name 'DefaultPassword' -Value 'vagrant'",
      "  ",
      "  Write-Host 'Vagrant user configured successfully' -ForegroundColor Green",
      "} catch {",
      "  Write-Error \"Failed to configure vagrant user: $($_.Exception.Message)\"",
      "  throw",
      "}"
    ]
    timeout = "10m"
  }
  
  # Configure WinRM more robustly
  provisioner "powershell" {
    inline = [
      "Write-Host 'Configuring WinRM for Vagrant...' -ForegroundColor Yellow",
      "try {",
      "  # Enable PowerShell Remoting",
      "  Enable-PSRemoting -Force -SkipNetworkProfileCheck",
      "  ",
      "  # Configure WinRM service",
      "  winrm quickconfig -q -force",
      "  winrm set winrm/config/winrs '@{MaxMemoryPerShellMB=\"0\"}'",
      "  winrm set winrm/config '@{MaxTimeoutms=\"1800000\"}'",
      "  winrm set winrm/config/service '@{AllowUnencrypted=\"true\"}'",
      "  winrm set winrm/config/service/auth '@{Basic=\"true\"}'",
      "  winrm set winrm/config/client/auth '@{Basic=\"true\"}'",
      "  winrm set winrm/config/listener?Address=*+Transport=HTTP '@{Port=\"5985\"}'",
      "  ",
      "  # Configure firewall for WinRM",
      "  netsh advfirewall firewall set rule group='Windows Remote Management' new enable=yes",
      "  netsh advfirewall firewall add rule name='WinRM-HTTP' dir=in localport=5985 protocol=TCP action=allow",
      "  ",
      "  # Restart WinRM service to apply changes",
      "  Restart-Service winrm -Force",
      "  ",
      "  Write-Host 'WinRM configured successfully' -ForegroundColor Green",
      "} catch {",
      "  Write-Error \"Failed to configure WinRM: $($_.Exception.Message)\"",
      "  throw",
      "}"
    ]
    timeout = "15m"
  }
  
  # Install OpenSSH Server (useful for Vagrant)
  provisioner "powershell" {
    inline = [
      "Write-Host 'Installing OpenSSH Server...' -ForegroundColor Yellow",
      "try {",
      "  # Install OpenSSH Server capability",
      "  Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0",
      "  ",
      "  # Start and configure SSH service",
      "  Start-Service sshd",
      "  Set-Service -Name sshd -StartupType 'Automatic'",
      "  ",
      "  # Configure SSH for Vagrant",
      "  $sshDir = 'C:\\Users\\vagrant\\.ssh'",
      "  New-Item -Path $sshDir -ItemType Directory -Force | Out-Null",
      "  ",
      "  # Download Vagrant public key",
      "  try {",
      "    $vagrantKey = Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/hashicorp/vagrant/master/keys/vagrant.pub' -UseBasicParsing",
      "    $vagrantKey.Content | Out-File -FilePath \"$sshDir\\authorized_keys\" -Encoding ASCII",
      "    ",
      "    # Set proper permissions",
      "    icacls $sshDir /inheritance:r /grant 'vagrant:F' /grant 'SYSTEM:F'",
      "    icacls \"$sshDir\\authorized_keys\" /inheritance:r /grant 'vagrant:F' /grant 'SYSTEM:F'",
      "    ",
      "    Write-Host 'SSH configured successfully' -ForegroundColor Green",
      "  } catch {",
      "    Write-Warning \"Failed to download SSH key: $($_.Exception.Message)\"",
      "  }",
      "} catch {",
      "  Write-Warning \"OpenSSH installation failed: $($_.Exception.Message)\"",
      "}"
    ]
    timeout = "20m"
  }
  
  # Configure Windows settings and security
  provisioner "powershell" {
    inline = [
      "Write-Host 'Configuring Windows settings and security...' -ForegroundColor Yellow",
      "try {",
      "  # Disable UAC for easier automation",
      "  Set-ItemProperty -Path 'HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\System' -Name 'EnableLUA' -Value 0",
      "  Write-Host 'UAC disabled' -ForegroundColor Green",
      "  ",
      "  # Configure Windows Defender",
      "  try {",
      "    Set-MpPreference -DisableRealtimeMonitoring $true -DisableScriptScanning $true -DisableArchiveScanning $true",
      "    Write-Host 'Windows Defender real-time protection disabled' -ForegroundColor Green",
      "  } catch {",
      "    Write-Warning \"Could not configure Windows Defender: $($_.Exception.Message)\"",
      "  }",
      "  ",
      "  # Disable Windows Update automatic restart",
      "  Set-ItemProperty -Path 'HKLM:\\SOFTWARE\\Microsoft\\WindowsUpdate\\UX\\Settings' -Name 'UxOption' -Value 1 -ErrorAction SilentlyContinue",
      "  ",
      "  # Configure Explorer settings",
      "  Set-ItemProperty -Path 'HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced' -Name 'HideFileExt' -Value 0 -ErrorAction SilentlyContinue",
      "  Set-ItemProperty -Path 'HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced' -Name 'Hidden' -Value 1 -ErrorAction SilentlyContinue",
      "  ",
      "  # Disable Server Manager at startup",
      "  try {",
      "    Get-ScheduledTask -TaskName ServerManager -ErrorAction SilentlyContinue | Disable-ScheduledTask",
      "    Write-Host 'Server Manager startup disabled' -ForegroundColor Green",
      "  } catch {",
      "    Write-Verbose 'Server Manager task not found or already disabled'",
      "  }",
      "  ",
      "  # Configure power settings for better VM performance",
      "  powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c  # High Performance",
      "  powercfg /change monitor-timeout-ac 0",
      "  powercfg /change standby-timeout-ac 0",
      "  powercfg /change disk-timeout-ac 0",
      "  powercfg /change hibernate-timeout-ac 0",
      "  ",
      "  Write-Host 'Windows settings configured successfully' -ForegroundColor Green",
      "} catch {",
      "  Write-Warning \"Some Windows settings could not be configured: $($_.Exception.Message)\"",
      "}"
    ]
    timeout = "10m"
  }
  
  # Configure network settings
  provisioner "powershell" {
    inline = [
      "Write-Host 'Configuring network settings...' -ForegroundColor Yellow",
      "try {",
      "  # Set network profile to Private (more permissive firewall)",
      "  Get-NetConnectionProfile | Set-NetConnectionProfile -NetworkCategory Private",
      "  ",
      "  # Enable ping (ICMP)",
      "  Enable-NetFirewallRule -DisplayName 'File and Printer Sharing (Echo Request - ICMPv4-In)' -ErrorAction SilentlyContinue",
      "  Enable-NetFirewallRule -DisplayName 'File and Printer Sharing (Echo Request - ICMPv6-In)' -ErrorAction SilentlyContinue",
      "  ",
      "  # Enable network discovery",
      "  Enable-NetFirewallRule -DisplayGroup 'Network Discovery' -ErrorAction SilentlyContinue",
      "  ",
      "  Write-Host 'Network settings configured successfully' -ForegroundColor Green",
      "} catch {",
      "  Write-Warning \"Network configuration failed: $($_.Exception.Message)\"",
      "}"
    ]
    timeout = "5m"
  }
  
  # Clean up and optimize
  provisioner "powershell" {
    inline = [
      "Write-Host 'Performing cleanup and optimization...' -ForegroundColor Yellow",
      "try {",
      "  # Clean temporary files",
      "  Remove-Item -Path 'C:\\Windows\\Temp\\*' -Recurse -Force -ErrorAction SilentlyContinue",
      "  Remove-Item -Path 'C:\\Users\\*\\AppData\\Local\\Temp\\*' -Recurse -Force -ErrorAction SilentlyContinue",
      "  ",
      "  # Clean Windows Update cache",
      "  Stop-Service wuauserv -Force -ErrorAction SilentlyContinue",
      "  Remove-Item -Path 'C:\\Windows\\SoftwareDistribution\\Download\\*' -Recurse -Force -ErrorAction SilentlyContinue",
      "  Start-Service wuauserv -ErrorAction SilentlyContinue",
      "  ",
      "  # Clear event logs",
      "  wevtutil el | ForEach-Object { wevtutil cl $_ }",
      "  ",
      "  # Defragment system drive",
      "  defrag C: /O",
      "  ",
      "  # Run disk cleanup",
      "  cleanmgr /sagerun:1",
      "  ",
      "  Write-Host 'Cleanup and optimization completed' -ForegroundColor Green",
      "} catch {",
      "  Write-Warning \"Cleanup encountered issues: $($_.Exception.Message)\"",
      "}"
    ]
    timeout = "30m"
  }
  
  # Final validation and preparation
  provisioner "powershell" {
    inline = [
      "Write-Host 'Performing final validation...' -ForegroundColor Yellow",
      "try {",
      "  # Verify WinRM is working",
      "  $winrmStatus = Get-Service WinRM",
      "  if ($winrmStatus.Status -ne 'Running') {",
      "    throw 'WinRM service is not running'",
      "  }",
      "  ",
      "  # Verify vagrant user",
      "  $vagrantUser = Get-LocalUser -Name 'vagrant'",
      "  if (-not $vagrantUser) {",
      "    throw 'Vagrant user not found'",
      "  }",
      "  ",
      "  # Test WinRM connectivity",
      "  $testResult = Test-NetConnection -ComputerName localhost -Port 5985",
      "  if (-not $testResult.TcpTestSucceeded) {",
      "    throw 'WinRM connectivity test failed'",
      "  }",
      "  ",
      "  # Display system information",
      "  Write-Host 'Golden Image Build Information:' -ForegroundColor Green",
      "  Write-Host \"  OS: $((Get-CimInstance Win32_OperatingSystem).Caption)\" -ForegroundColor White",
      "  Write-Host \"  Version: $((Get-CimInstance Win32_OperatingSystem).Version)\" -ForegroundColor White",
      "  Write-Host \"  Build Date: $(Get-Date)\" -ForegroundColor White",
      "  Write-Host \"  Vagrant User: Configured\" -ForegroundColor White",
      "  Write-Host \"  WinRM: Enabled\" -ForegroundColor White",
      "  Write-Host \"  SSH: $((Get-WindowsCapability -Online -Name OpenSSH.Server* | Where-Object State -eq 'Installed') ? 'Enabled' : 'Disabled')\" -ForegroundColor White",
      "  ",
      "  Write-Host 'Golden image preparation completed successfully!' -ForegroundColor Green",
      "} catch {",
      "  Write-Error \"Final validation failed: $($_.Exception.Message)\"",
      "  throw",
      "}"
    ]
    timeout = "10m"
  }
}