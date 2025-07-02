# Common functions for Vagrant box selection
# This file can be included in Vagrantfiles to provide consistent box selection

def get_available_golden_images
  available_boxes = []
  
  begin
    # Get list of installed Vagrant boxes
    box_list = `vagrant box list 2>/dev/null`.strip.split("\n")
    box_list.each do |line|
      # Look for boxes with golden image naming patterns
      if line.match(/(golden|server|windows).*hyperv/i)
        box_name = line.split(/\s+/).first
        available_boxes << box_name unless box_name.nil? || box_name.empty?
      end
    end
  rescue => e
    puts "Warning: Could not retrieve box list: #{e.message}"
  end
  
  # Remove duplicates and sort
  available_boxes.uniq!.sort!
  
  # Add default options if no boxes found
  if available_boxes.empty?
    puts "No golden image boxes found. Adding default options..."
    available_boxes = [
      "windows-server-2019-golden",
      "windows-server-2025-golden"
    ]
  end
  
  return available_boxes
end

def select_golden_image(available_boxes, interactive = true)
  return available_boxes.first unless interactive
  
  puts "\n=== Available Golden Images ==="
  puts "Choose which golden image to use for this VM:"
  puts "-" * 50
  
  available_boxes.each_with_index do |box, index|
    # Check if box actually exists
    box_exists = system("vagrant box list | grep -q \"#{box}\"", :out => File::NULL, :err => File::NULL)
    status = box_exists ? "✓" : "✗"
    puts "#{index + 1}. #{box} #{status}"
  end
  
  puts "#{available_boxes.length + 1}. Enter custom box name"
  puts "-" * 50
  
  print "Select golden image (1-#{available_boxes.length + 1}, default: 1): "
  selection = $stdin.gets.chomp
  
  if selection.empty? || selection == "1"
    selected_box = available_boxes.first
  elsif selection.to_i > 0 && selection.to_i <= available_boxes.length
    selected_box = available_boxes[selection.to_i - 1]
  elsif selection.to_i == available_boxes.length + 1
    print "Enter custom box name: "
    custom_box = $stdin.gets.chomp
    selected_box = custom_box.empty? ? available_boxes.first : custom_box
  else
    puts "Invalid selection, using default: #{available_boxes.first}"
    selected_box = available_boxes.first
  end
  
  return selected_box
end

def display_box_info(box_name)
  puts "\n=== Golden Image Information ==="
  puts "Selected: #{box_name}"
  
  # Try to get box information
  begin
    box_info = `vagrant box list | grep "#{box_name}"`.strip
    if !box_info.empty?
      puts "Status: Box is installed"
      puts "Details: #{box_info}"
    else
      puts "Status: Box not found locally"
      puts "Note: Box will be downloaded/created when needed"
    end
  rescue
    puts "Status: Could not verify box status"
  end
  puts "-" * 50
end
