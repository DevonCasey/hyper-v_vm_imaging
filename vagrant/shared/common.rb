# -*- mode: ruby -*-
# vi: set ft=ruby :

# Shared Vagrant configuration for Hyper-V VM Imaging Workflow
# Author: Devon Casey
# Date: 06-30-2025
# Version: 1.0.0

require 'json'
require 'yaml'

# Helper methods for golden image detection
def get_available_golden_images
  # Get list of Vagrant boxes that match the golden image pattern
  boxes = `vagrant box list`.split("\n")
  golden_boxes = boxes.select { |box| box.match(/windows-server-\d{4}-golden/) }
  
  golden_images = {}
  golden_boxes.each do |box|
    # Extract box name and version
    match = box.match(/^(windows-server-(\d{4})-golden)/)
    if match
      box_name = match[1]
      version = match[2]
      golden_images[version] = {
        'box_name' => box_name,
        'version' => version,
        'os_name' => "windows-server-#{version}"
      }
    end
  end
  
  golden_images
end

def get_default_golden_image
  available_images = get_available_golden_images
  
  if available_images.empty?
    # Fallback to expected naming convention
    return {
      'box_name' => 'windows-server-2019-golden',
      'version' => '2019',
      'os_name' => 'windows-server-2019'
    }
  end
  
  # Prefer the latest version available
  latest_version = available_images.keys.sort.last
  available_images[latest_version]
end

def select_golden_image(preferred_version = nil)
  available_images = get_available_golden_images
  
  if preferred_version && available_images.key?(preferred_version)
    return available_images[preferred_version]
  end
  
  # If preferred version not available or not specified, use default
  get_default_golden_image
end

class VagrantConfig
  attr_reader :config_data, :environment_name, :golden_image_info
  
  def initialize(environment_name, preferred_version = nil)
    @environment_name = environment_name
    @golden_image_info = select_golden_image(preferred_version)
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
    # Use detected golden image information
    golden_image = @golden_image_info
    
    {
      "global" => {
        "default_os" => golden_image['os_name'],
        "windows_version" => golden_image['version'],
        "workgroup_name" => "SERVERS",
        "timezone" => "Eastern Standard Time",
        "default_switch" => "Virtual Switch VLAN Trunk",
        "default_vlan" => 31
      },
      "golden_image" => {
        "box_name" => golden_image['box_name'],
        "version" => golden_image['version'],
        "os_name" => golden_image['os_name']
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
            "time_synchronization" => false, # important so the VM gets its time from the DC
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
    @golden_image_info['box_name'] || config_data.dig("golden_image", "box_name") || "windows-server-2025-golden"
  end
  
  def windows_version
    @golden_image_info['version'] || config_data.dig("golden_image", "version") || config_data.dig("global", "windows_version") || "2025"
  end
  
  def windows_os_name
    @golden_image_info['os_name'] || config_data.dig("golden_image", "os_name") || config_data.dig("global", "default_os") || "windows-server-2025"
  end
  
  def golden_image_info
    {
      'box_name' => golden_image_box,
      'version' => windows_version,
      'os_name' => windows_os_name
    }
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
  
  # Class method for interactive golden image selection
  def self.create_with_interactive_selection(environment_name)
    if ARGV[0] == "up" && ENV['VAGRANT_SELECT_IMAGE']
      golden_image = interactive_golden_image_selection
      new(environment_name, golden_image['version'])
    else
      new(environment_name)
    end
  end
end

# Interactive VM configuration
def get_vm_configuration(environment_name)
  # Create config helper
  config_helper = VagrantConfig.new(environment_name)
  vm_config = {}
  
  if ARGV[0] == "up" && (ARGV.length == 2 || ENV['VAGRANT_INTERACTIVE'])
    puts "\n" + "=" * 60
    puts "   #{environment_name.upcase} VM Configuration"
    puts "   Golden Image: #{config_helper.golden_image_box} (#{config_helper.windows_os_name})"
    puts "=" * 60
    puts ""
    
    # Get VM name
    default_name = "ax-#{environment_name}image"
    print "Enter VM name [#{default_name}]: "
    vm_name = $stdin.gets.chomp
    vm_config[:name] = vm_name.empty? ? default_name : vm_name
    

    
    # Resource configuration
    default_memory = config_helper.get_vm_setting("memory", 2048)
    print "Enter memory (MB) [#{default_memory}]: "
    memory_input = $stdin.gets.chomp
    vm_config[:memory] = memory_input.empty? ? default_memory : memory_input.to_i
    
    default_cpus = config_helper.get_vm_setting("cpus", 2)
    print "Enter CPU count [#{default_cpus}]: "
    cpu_input = $stdin.gets.chomp
    vm_config[:cpus] = cpu_input.empty? ? default_cpus : cpu_input.to_i
    
    # Domain joining configuration (available for all environments)
    puts ""
    print "Join a domain? (y/n) [n]: "
    join_domain_input = $stdin.gets.chomp.downcase
    vm_config[:join_domain] = (join_domain_input == 'y' || join_domain_input == 'yes')
    
    if vm_config[:join_domain]
      print "Enter domain FQDN (e.g., contoso.local): "
      vm_config[:domain_fqdn] = $stdin.gets.chomp
      
      if vm_config[:domain_fqdn].empty?
        puts "Error: Domain FQDN is required for domain join"
        exit 1
      end
      
      print "Enter domain join username (e.g., DOMAIN\\admin or admin@domain.com): "
      vm_config[:domain_username] = $stdin.gets.chomp
      
      if vm_config[:domain_username].empty?
        puts "Error: Domain username is required for domain join"
        exit 1
      end
      
      print "Enter domain join password: "
      begin
        # Hide password input on Windows/Unix
        require 'io/console'
        vm_config[:domain_password] = $stdin.noecho(&:gets).chomp
      rescue LoadError
        # Fallback for systems without io/console
        vm_config[:domain_password] = $stdin.gets.chomp
      end
      puts "" # New line after hidden input
      
      if vm_config[:domain_password].empty?
        puts "Error: Domain password is required for domain join"
        exit 1
      end
    end
    
    puts ""
    puts "Configuration Summary:"
    puts "  VM Name: #{vm_config[:name]}"
    puts "  Memory: #{vm_config[:memory]}MB"
    puts "  CPUs: #{vm_config[:cpus]}"
    if vm_config[:join_domain]
      puts "  Domain: #{vm_config[:domain_fqdn]} (User: #{vm_config[:domain_username]})"
    else
      puts "  Domain: Workgroup (not joining domain)"
    end
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
    vm_config[:memory] = config_helper.get_vm_setting("memory", 2048)
    vm_config[:cpus] = config_helper.get_vm_setting("cpus", 2)
    vm_config[:join_domain] = false
  end

  # Validate that the golden image exists
  validate_box_exists(vm_config[:box_name])
  
  # Add the golden image box name to the config
  vm_config[:box_name] = config_helper.golden_image_box

  
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
    
    # OS disk configuration
    hv.vhdx_name = "#{vm_config[:name]}_os.vhdx"
    
    # VLAN configuration
    global_config = config_helper.global_config
    hv.vlan_id = global_config["default_vlan"] || 31
  end
end

# Common provisioning scripts
def get_base_provisioning_script(vm_config, config_helper)
  global_config = config_helper.global_config
  
  <<~POWERSHELL
    Write-Host ("=" * 60) 
    Write-Host "=== Base Configuration Starting ===" -ForegroundColor Green
    Write-Host ("=" * 60) 
    
    $WorkgroupName = "#{global_config['workgroup_name'] || 'SERVERS'}"
    $TimeZone = "#{global_config['timezone'] || 'Eastern Standard Time'}"
    
    # Set timezone
    Write-Host "Setting timezone to $TimeZone..." -ForegroundColor Yellow
    try {
        Set-TimeZone -Id $TimeZone
        Write-Host "Timezone set successfully" -ForegroundColor Green
    } catch {
        Write-Warning "Failed to set timezone: $($_.Exception.Message)"
    }
    
    # Domain joining or workgroup configuration
    $JoinDomain = $#{vm_config[:join_domain] ? 'true' : 'false'}
    $DomainFQDN = "#{vm_config[:domain_fqdn] || ''}"
    $DomainUsername = "#{vm_config[:domain_username] || ''}"
    $DomainPassword = "#{vm_config[:domain_password] || ''}"
    
    if ($JoinDomain -eq $true -and $DomainFQDN -ne "") {
        Write-Host "Joining domain: $DomainFQDN..." -ForegroundColor Yellow
        try {
            $SecurePassword = ConvertTo-SecureString $DomainPassword -AsPlainText -Force
            $Credential = New-Object System.Management.Automation.PSCredential($DomainUsername, $SecurePassword)
            
            # Test domain connectivity first
            Write-Host "Testing domain connectivity..." -ForegroundColor Yellow
            $DomainController = (Resolve-DnsName -Name $DomainFQDN -Type A -ErrorAction SilentlyContinue | Select-Object -First 1).IPAddress
            
            if ($DomainController) {
                Write-Host "Domain controller found: $DomainController" -ForegroundColor Green
                
                # Join the domain
                Add-Computer -DomainName $DomainFQDN -Credential $Credential -Force -Restart:$false
                Write-Host "Successfully joined domain: $DomainFQDN" -ForegroundColor Green
                Write-Host "Note: VM will need to be restarted to complete domain join" -ForegroundColor Yellow
            } else {
                Write-Warning "Could not resolve domain controller for: $DomainFQDN"
                Write-Host "Falling back to workgroup configuration..." -ForegroundColor Yellow
                Add-Computer -WorkgroupName $WorkgroupName -Force
            }
        } catch {
            Write-Warning "Failed to join domain: $($_.Exception.Message)"
            Write-Host "Falling back to workgroup configuration..." -ForegroundColor Yellow
            try {
                Add-Computer -WorkgroupName $WorkgroupName -Force
                Write-Host "Successfully joined workgroup: $WorkgroupName" -ForegroundColor Green
            } catch {
                Write-Warning "Failed to join workgroup: $($_.Exception.Message)"
            }
        }
    } else {
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
    Write-Host "Golden Image: #{config_helper.golden_image_box}" -ForegroundColor Green
    Write-Host ("=" * 60) 
    
    # Display system information
    $ComputerInfo = Get-ComputerInfo
    $TimeZone = Get-TimeZone
    $ComputerSystem = Get-WmiObject -Class Win32_ComputerSystem
    
    Write-Host "Server Name: $env:COMPUTERNAME" -ForegroundColor White
    Write-Host "Golden Image: #{config_helper.golden_image_box}" -ForegroundColor White
    Write-Host "Windows Version: #{config_helper.windows_version}" -ForegroundColor White
    
    # Display domain or workgroup status
    if ($ComputerSystem.PartOfDomain) {
        Write-Host "Domain: $($ComputerSystem.Domain)" -ForegroundColor White
        Write-Host "Domain Status: Member" -ForegroundColor Green
    } else {
        Write-Host "Workgroup: $($ComputerSystem.Workgroup)" -ForegroundColor White
        Write-Host "Domain Status: Not joined" -ForegroundColor Yellow
    }
    
    Write-Host "Timezone: $($TimeZone.Id) ($($TimeZone.DisplayName))" -ForegroundColor White
    Write-Host "OS Version: $($ComputerInfo.WindowsProductName)" -ForegroundColor White
    Write-Host "Last Boot: $($ComputerInfo.LastBootUpTime)" -ForegroundColor White
    
    # Storage information
    Write-Host "`nStorage Configuration:" 
    Write-Host "  - C:\\\\ (OS drive)" -ForegroundColor White
    
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

def interactive_golden_image_selection
  available_images = get_available_golden_images
  
  if available_images.empty?
    puts "No golden images found! Please build a golden image first."
    return get_default_golden_image
  end
  
  if available_images.length == 1
    # Only one option, use it
    version = available_images.keys.first
    puts "Found golden image: #{available_images[version]['box_name']}"
    return available_images[version]
  end
  
  # Multiple options, let user choose
  puts "\nAvailable Golden Images:"
  available_images.each_with_index do |(version, info), index|
    puts "  #{index + 1}. #{info['box_name']} (Windows Server #{version})"
  end
  
  print "\nSelect golden image [1]: "
  choice = $stdin.gets.chomp
  
  if choice.empty?
    choice = "1"
  end
  
  index = choice.to_i - 1
  versions = available_images.keys.sort
  
  if index >= 0 && index < versions.length
    selected_version = versions[index]
    available_images[selected_version]
  else
    puts "Invalid selection, using default."
    get_default_golden_image
  end
end

# Validation helpers
def validate_box_exists(box_name)
  # Check if the golden image box exists
  result = `vagrant box list`.split("\n").any? { |line| line.include?(box_name) }
  
  unless result
    puts ""
    puts "ERROR: Golden image box '#{box_name}' not found!"
    puts ""
    
    # Show available golden images
    available_images = get_available_golden_images
    if available_images.any?
      puts "Available golden images:"
      available_images.each do |version, info|
        puts "  - #{info['box_name']} (Windows Server #{version})"
      end
      puts ""
      puts "To use a different version, modify your configuration or rebuild the golden image."
    else
      puts "No golden images found!"
    end
    
    puts ""
    puts "Please build the golden image first:"
    puts "  .\\scripts\\Build-GoldenImage.ps1"
    puts ""
    exit 1
  end
end