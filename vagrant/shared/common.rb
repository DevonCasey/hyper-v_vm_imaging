# -*- mode: ruby -*-
# vi: set ft=ruby :

# Shared Vagrant configuration for Hyper-V VM Imaging Workflow
# Author: Devon Casey
# Date: 06-30-2025
# Version: 1.0.0

require 'json'
require 'yaml'

class VagrantConfig
  attr_reader :config_data, :environment_name
  
  def initialize(environment_name)
    @environment_name = environment_name
    @config_data = load_configuration
  end
  
  def load_configuration
    # Try to load from project config directory
    config_paths = [
      File.join(File.dirname(__FILE__), '..', '..', 'config', 'default.json'),
      File.join(ENV['HOME'] || ENV['USERPROFILE'] || '.', '.vagrant-hyperv-config.json')
    ]
    
    config_data = nil
    config_paths.each do |path|
      if File.exist?(path)
        config_data = JSON.parse(File.read(path))
        break
      end
    end
    
    if config_data.nil?
      # Fallback to default configuration
      warn "Warning: Configuration file not found, using defaults"
      config_data = default_configuration
    end
    
    config_data
  end
  
  def default_configuration
    {
      "global" => {
        "default_os" => "windows-server-2025",
        "workgroup_name" => "SERVERS",
        "timezone" => "Eastern Standard Time",
        "default_switch" => "Virtual Switch VLAN Trunk",
        "default_vlan" => 31
      },
      "golden_image" => {
        "box_name" => "windows-server-2025-golden"
      },
      "vagrant" => {
        "default_credentials" => {
          "username" => "vagrant",
          "password" => "vagrant"
        },
        "timeouts" => {
          "boot" => 600,
          "graceful_halt" => 600,
          "winrm" => 300,
          "winrm_retry_limit" => 20,
          "winrm_retry_delay" => 10
        },
        "vm_defaults" => {
          "cpus" => 2,
          "memory" => 2048,
          "linked_clone" => false,
          "enable_secure_boot" => false,
          "enable_automatic_checkpoints" => false,
          "enable_enhanced_session_mode" => true,
          "vm_integration_services" => {
            "guest_service_interface" => true,
            "heartbeat" => true,
            "key_value_pair_exchange" => true,
            "shutdown" => true,
            "time_synchronization" => false,
            "vss" => true
          }
        }
      },
      "environments" => {
        "barebones" => {
          "description" => "Minimal Windows Server installation",
          "memory" => 2048,
          "cpus" => 2,
          "default_drive_size" => 25,
          "features" => ["basic_config", "windows_updates", "firewall_ping"]
        },
        "fileserver" => {
          "description" => "File server with deduplication and DFS",
          "memory" => 4096,
          "cpus" => 4,
          "default_drive_size" => 100,
          "features" => ["file_services", "dfs", "deduplication", "fsrm"]
        },
        "dev-box" => {
          "description" => "Development environment with tools",
          "memory" => 8192,
          "cpus" => 4,
          "default_drive_size" => 50,
          "features" => ["chocolatey", "vscode", "git", "python", "nodejs"]
        },
        "domain-controller" => {
          "description" => "Active Directory Domain Services",
          "memory" => 4096,
          "cpus" => 4,
          "default_drive_size" => 50,
          "features" => ["adds", "dns", "group_policy"]
        },
        "iis-server" => {
          "description" => "IIS Web Server with ASP.NET",
          "memory" => 4096,
          "cpus" => 4,
          "default_drive_size" => 100,
          "features" => ["iis", "aspnet", "management_tools"]
        }
      }
    }
  end
  
  def golden_image_box
    config_data.dig("golden_image", "box_name") || "windows-server-2025-golden"
  end
  
  def environment_config
    config_data.dig("environments", environment_name) || {}
  end
  
  def vm_defaults
    config_data.dig("vagrant", "vm_defaults") || {}
  end
  
  def credentials
    config_data.dig("vagrant", "default_credentials") || {}
  end
  
  def timeouts
    config_data.dig("vagrant", "timeouts") || {}
  end
  
  def global_config
    config_data["global"] || {}
  end
  
  def get_vm_setting(key, default_value = nil)
    environment_config[key] || vm_defaults[key] || default_value
  end
  
  def get_timeout(key, default_value = 300)
    timeouts[key] || default_value
  end
end

# Interactive VM configuration
def get_vm_configuration(environment_name, config_helper)
  vm_config = {}
  
  if ARGV[0] == "up" && (ARGV.length == 2 || ENV['VAGRANT_INTERACTIVE'])
    puts "\n" + "=" * 60
    puts "   #{environment_name.upcase} VM Configuration"
    puts "=" * 60
    puts ""
    
    # Get VM name
    default_name = "ax-#{environment_name}image"
    print "Enter VM name [#{default_name}]: "
    vm_name = $stdin.gets.chomp
    vm_config[:name] = vm_name.empty? ? default_name : vm_name
    
    # Get data drive configuration
    print "Enter data drive name [Data]: "
    drive_name_input = $stdin.gets.chomp
    vm_config[:drive_name] = drive_name_input.empty? ? "Data" : drive_name_input
    vm_config[:drive_letter] = vm_config[:drive_name][0].upcase
    
    # Get drive size
    default_size = config_helper.get_vm_setting("default_drive_size", 25)
    print "Enter size for #{vm_config[:drive_letter]}: drive (GB) [#{default_size}]: "
    drive_size_input = $stdin.gets.chomp
    vm_config[:drive_size] = drive_size_input.empty? ? default_size : drive_size_input.to_i
    
    # Get drive type
    print "Fixed size drive? (y/n) [n]: "
    fixed_input = $stdin.gets.chomp.downcase
    vm_config[:fixed_size] = (fixed_input == 'y' || fixed_input == 'yes')
    
    # Resource configuration
    default_memory = config_helper.get_vm_setting("memory", 2048)
    print "Enter memory (MB) [#{default_memory}]: "
    memory_input = $stdin.gets.chomp
    vm_config[:memory] = memory_input.empty? ? default_memory : memory_input.to_i
    
    default_cpus = config_helper.get_vm_setting("cpus", 2)
    print "Enter CPU count [#{default_cpus}]: "
    cpu_input = $stdin.gets.chomp
    vm_config[:cpus] = cpu_input.empty? ? default_cpus : cpu_input.to_i
    
    puts ""
    puts "Configuration Summary:"
    puts "  VM Name: #{vm_config[:name]}"
    puts "  #{vm_config[:drive_letter]}: Drive: #{vm_config[:drive_size]}GB (#{vm_config[:fixed_size] ? 'Fixed' : 'Dynamic'})"
    puts "  Memory: #{vm_config[:memory]}MB"
    puts "  CPUs: #{vm_config[:cpus]}"
    puts ""
    
    print "Continue with this configuration? (Y/n): "
    confirm = $stdin.gets.chomp.downcase
    if confirm == 'n' || confirm == 'no'
      puts "Configuration cancelled."
      exit 0
    end
  else
    # Use defaults from configuration
    vm_config[:name] = "ax-#{environment_name}image"
    vm_config[:drive_name] = "Data"
    vm_config[:drive_letter] = "D"
    vm_config[:drive_size] = config_helper.get_vm_setting("default_drive_size", 25)
    vm_config[:fixed_size] = false
    vm_config[:memory] = config_helper.get_vm_setting("memory", 2048)
    vm_config[:cpus] = config_helper.get_vm_setting("cpus", 2)
  end
  
  vm_config
end

# Common VM configuration
def configure_common_vm_settings(config, vm_config, config_helper)
  # Basic VM settings
  config.vm.hostname = vm_config[:name]
  config.vm.guest = :windows
  config.vm.communicator = "winrm"
  config.vm.boot_timeout = config_helper.get_timeout("boot", 600)
  config.vm.graceful_halt_timeout = config_helper.get_timeout("graceful_halt", 600)
  
  # WinRM configuration
  credentials = config_helper.credentials
  config.winrm.username = credentials["username"] || "vagrant"
  config.winrm.password = credentials["password"] || "vagrant"
  config.winrm.transport = :plaintext
  config.winrm.basic_auth_only = true
  config.winrm.timeout = config_helper.get_timeout("winrm", 300)
  config.winrm.retry_limit = config_helper.get_timeout("winrm_retry_limit", 20)
  config.winrm.retry_delay = config_helper.get_timeout("winrm_retry_delay", 10)
  
  # Use the golden image box
  config.vm.box = config_helper.golden_image_box
  
  # Network configuration
  global_config = config_helper.global_config
  config.vm.network "public_network", bridge: global_config["default_switch"] || "Virtual Switch VLAN Trunk"
end

# Hyper-V provider configuration
def configure_hyperv_provider(config, vm_config, config_helper)
  config.vm.provider "hyperv" do |hv|
    hv.vmname = vm_config[:name]
    hv.memory = vm_config[:memory]
    hv.cpus = vm_config[:cpus]
    
    # Apply VM defaults from configuration
    vm_defaults = config_helper.vm_defaults
    hv.enable_virtualization_extensions = vm_defaults["enable_virtualization_extensions"] || false
    hv.linked_clone = vm_defaults["linked_clone"] || false
    hv.enable_secure_boot = vm_defaults["enable_secure_boot"] || false
    hv.enable_automatic_checkpoints = vm_defaults["enable_automatic_checkpoints"] || false
    hv.enable_checkpoints = false
    hv.enable_enhanced_session_mode = vm_defaults["enable_enhanced_session_mode"] || true
    
    # VM Integration Services
    integration_services = vm_defaults["vm_integration_services"] || {}
    hv.vm_integration_services = {
      guest_service_interface: integration_services["guest_service_interface"] || true,
      heartbeat: integration_services["heartbeat"] || true,
      key_value_pair_exchange: integration_services["key_value_pair_exchange"] || true,
      shutdown: integration_services["shutdown"] || true,
      time_synchronization: integration_services["time_synchronization"] || false,
      vss: integration_services["vss"] || true
    }
    
    # Disk configuration
    hv.vhdx_name = "#{vm_config[:name]}_os.vhdx"
    hv.additional_disk_path = "#{vm_config[:name]}_#{vm_config[:drive_letter].downcase}.vhdx"
    hv.maxmemory = nil if vm_config[:fixed_size]
    
    # VLAN configuration
    global_config = config_helper.global_config
    hv.vlan_id = global_config["default_vlan"] || 31
  end
end

# Data drive creation trigger
def configure_data_drive_trigger(config, vm_config)
  config.trigger.before :up do |trigger|
    trigger.info = "Creating #{vm_config[:drive_letter]}: drive (#{vm_config[:drive_name]})..."
    trigger.run = {
      inline: powershell_drive_creation_script(vm_config)
    }
  end
end

def powershell_drive_creation_script(vm_config)
  <<~POWERSHELL
    powershell -Command "
      $DrivePath = '#{vm_config[:name]}_#{vm_config[:drive_letter].downcase}.vhdx'
      $DriveSize = #{vm_config[:drive_size]}GB
      $FixedSize = $#{vm_config[:fixed_size]}
      
      if (!(Test-Path $DrivePath)) {
        if ($FixedSize) {
          New-VHD -Path $DrivePath -SizeBytes $DriveSize -Fixed
        } else {
          New-VHD -Path $DrivePath -SizeBytes $DriveSize -Dynamic
        }
        Write-Host 'Created #{vm_config[:drive_letter]}: drive (#{vm_config[:drive_name]}): ' $DrivePath
      } else {
        Write-Host '#{vm_config[:drive_letter]}: drive already exists: ' $DrivePath
      }
    "
  POWERSHELL
end

# Common provisioning scripts
def get_base_provisioning_script(vm_config, config_helper)
  global_config = config_helper.global_config
  
  <<~POWERSHELL
    Write-Host ("=" * 60) 
    Write-Host "=== Base Configuration Starting ===" -ForegroundColor Green
    Write-Host ("=" * 60) 
    
    $DriveLetter = "#{vm_config[:drive_letter]}"
    $DriveName = "#{vm_config[:drive_name]}"
    $WorkgroupName = "#{global_config['workgroup_name'] || 'SERVERS'}"
    $TimeZone = "#{global_config['timezone'] || 'Eastern Standard Time'}"
    
    # Initialize and format data drive
    Write-Host "Configuring $DriveLetter`: drive ($DriveName)..." -ForegroundColor Yellow
    try {
        # Get the disk that is not initialized (should be our new data drive)
        $NewDisk = Get-Disk | Where-Object {$_.PartitionStyle -eq 'RAW' -and $_.Size -gt 1GB} | Select-Object -First 1
        if ($NewDisk) {
            Write-Host "Found uninitialized disk, setting up as $DriveLetter`: drive..." -ForegroundColor Green
            $NewDisk | Initialize-Disk -PartitionStyle GPT -PassThru | 
                New-Partition -DriveLetter $DriveLetter -UseMaximumSize | 
                Format-Volume -FileSystem NTFS -NewFileSystemLabel $DriveName -Confirm:$false
            Write-Host "$DriveLetter`: drive ($DriveName) configured successfully!" -ForegroundColor Green
        } else {
            Write-Host "No uninitialized disk found, $DriveLetter`: drive may already be configured" -ForegroundColor Yellow
        }
    } catch {
        Write-Warning "Failed to configure $DriveLetter`: drive: $($_.Exception.Message)"
    }
    
    # Set timezone
    Write-Host "Setting timezone to $TimeZone..." -ForegroundColor Yellow
    try {
        Set-TimeZone -Id $TimeZone
        Write-Host "Timezone set successfully" -ForegroundColor Green
    } catch {
        Write-Warning "Failed to set timezone: $($_.Exception.Message)"
    }
    
    # Join workgroup
    Write-Host "Joining $WorkgroupName workgroup..." -ForegroundColor Yellow
    $ComputerSystem = Get-WmiObject -Class Win32_ComputerSystem
    
    if ($ComputerSystem.Workgroup -ne $WorkgroupName) {
        try {
            Add-Computer -WorkgroupName $WorkgroupName -Force
            Write-Host "Successfully joined workgroup: $WorkgroupName" -ForegroundColor Green
        } catch {
            Write-Warning "Failed to join workgroup: $($_.Exception.Message)"
        }
    } else {
        Write-Host "Already member of workgroup: $WorkgroupName" -ForegroundColor Green
    }
    
    # Enable ping
    Write-Host "Enabling ping..." -ForegroundColor Yellow
    Enable-NetFirewallRule -DisplayName "File and Printer Sharing (Echo Request - ICMPv4-In)" -ErrorAction SilentlyContinue
    Enable-NetFirewallRule -DisplayName "File and Printer Sharing (Echo Request - ICMPv6-In)" -ErrorAction SilentlyContinue
    
    Write-Host "Base configuration completed!" -ForegroundColor Green
  POWERSHELL
end

def get_windows_updates_script
  <<~POWERSHELL
    Write-Host ("=" * 60) 
    Write-Host "Installing Windows Updates..." -ForegroundColor Yellow
    Write-Host ("=" * 60) 
    
    try {
        # Install PSWindowsUpdate module if not present
        if (!(Get-Module -ListAvailable -Name PSWindowsUpdate)) {
            Write-Host "Installing PSWindowsUpdate module..." -ForegroundColor Yellow
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Confirm:$false
            Install-Module PSWindowsUpdate -Force -Scope AllUsers -Confirm:$false
        }
        
        Import-Module PSWindowsUpdate -Force
        
        # Get and install critical updates only
        $updates = Get-WindowsUpdate -Category 'Critical Updates','Security Updates' -AcceptAll -Verbose:$false
        
        if ($updates) {
            Write-Host "Found $($updates.Count) critical/security updates" -ForegroundColor Yellow
            Install-WindowsUpdate -Category 'Critical Updates','Security Updates' -AcceptAll -AutoReboot:$false -Confirm:$false -Verbose:$false
            Write-Host "Critical updates installed successfully" -ForegroundColor Green
        } else {
            Write-Host "No critical updates available" -ForegroundColor Green
        }
    } catch {
        Write-Warning "Windows Updates failed: $($_.Exception.Message)"
        Write-Host "Continuing without updates..." -ForegroundColor Yellow
    }
  POWERSHELL
end

def get_status_report_script(vm_config, config_helper, environment_description)
  <<~POWERSHELL
    Write-Host ("=" * 60) 
    Write-Host "#{environment_description.upcase} READY" -ForegroundColor Green
    Write-Host ("=" * 60) 
    
    $DriveLetter = "#{vm_config[:drive_letter]}"
    $DriveName = "#{vm_config[:drive_name]}"
    
    # Display system information
    $ComputerInfo = Get-ComputerInfo
    $TimeZone = Get-TimeZone
    $Workgroup = (Get-WmiObject -Class Win32_ComputerSystem).Workgroup
    
    Write-Host "Server Name: $env:COMPUTERNAME" -ForegroundColor White
    Write-Host "Workgroup: $Workgroup" -ForegroundColor White
    Write-Host "Timezone: $($TimeZone.Id) ($($TimeZone.DisplayName))" -ForegroundColor White
    Write-Host "OS Version: $($ComputerInfo.WindowsProductName)" -ForegroundColor White
    Write-Host "Last Boot: $($ComputerInfo.LastBootUpTime)" -ForegroundColor White
    
    # Storage information
    Write-Host "`nStorage Configuration:" 
    Write-Host "  - C:\\\\ (OS drive)" -ForegroundColor White
    Write-Host "  - $DriveLetter`:\\\\ ($DriveName drive)" -ForegroundColor White
    
    # Network information
    $IPAddress = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object {$_.IPAddress -notlike "127.*" -and $_.IPAddress -notlike "169.*"}).IPAddress
    if ($IPAddress) {
        Write-Host "`nIP Address: $IPAddress" -ForegroundColor White
    }
    
    Write-Host "`nAccess via: vagrant rdp" -ForegroundColor Yellow
    Write-Host "Username: #{config_helper.credentials['username'] || 'vagrant'}" -ForegroundColor Yellow
    Write-Host "Password: #{config_helper.credentials['password'] || 'vagrant'}" -ForegroundColor Yellow
    
    Write-Host "`n#{environment_description} setup complete!" -ForegroundColor Green
  POWERSHELL
end

# Validation helpers
def validate_box_exists(box_name)
  # Check if the golden image box exists
  result = `vagrant box list`.split("\n").any? { |line| line.include?(box_name) }
  
  unless result
    puts ""
    puts "ERROR: Golden image box '#{box_name}' not found!"
    puts ""
    puts "Please build the golden image first:"
    puts "  .\\scripts\\Build-WeeklyGoldenImage.ps1"
    puts ""
    puts "Or check if the box name is correct in your configuration."
    puts ""
    exit 1
  end
end