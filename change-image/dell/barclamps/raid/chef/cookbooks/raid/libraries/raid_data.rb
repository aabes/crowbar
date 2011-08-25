#
# Copyright 2011, Dell
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
# 
#     http://www.apache.org/licenses/LICENSE-2.0
# 
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Author: andi abes
#


####
# Some common data structures used by all RAID support libraries


class Crowbar
  class RAID
    
    RAID0 = :RAID0
    RAID1 = :RAID1      
    RAID1E = :RAID1E
    RAID10 = :RAID10
    JBOD = :JBOD
    
    attr_accessor :disks, :volumes, :debug
    @@controller_styles = []
    
    def describe_volumes
      return if @volumes.nil?
      s = ""
      @volumes.each { |v| s << v.to_s << " "}
      s
    end
    
    def describe_disks
      return if @disks.nil?
      s = ""
      @disks.each { |d| s << d.to_s << " " }
      s
    end
    
    ### 
    # Catch classes that inherit us, so we have a list of controller styles to try to use
    def self.inherited(subclass)      
      @@controller_styles  << subclass
    end
    
    def self.controller_styles
      @@controller_styles
    end
    
    class Volume
      attr_accessor :vol_name, :vol_id, :raid_level, :members, :name , :os_dev, :size
      attr_accessor :pci_id ## seems to be the main connection between volumes and OS device names
      
      def initialize
        @members = []
      end
      
      def to_s
        "id: #{vol_id} name: #{vol_name} type: #{raid_level} members:{ #{members.join(",")} }"
      end
      
    end
    
    class RaidDisk
      attr_accessor :disk_id, :enclosure ,:slot
      
      def to_s
        "#{enclosure}:#{slot}"
      end
      
    end
    
    class OSDisk
      attr_accessor :pci_id, :dev_name
    end
    
    
    def log( msg, sev=:DEBUG)
      return unless @debug
      if $in_chef == true 
        case sev 
          when :DEBUG
          Chef::Log.info(msg)
          when :ERROR
          Chef::Log.error(msg)
        end          
      else
        puts msg
      end        
      true        
    end      
    
    ###
    # Extract the value from text following the pattern:
    #
    #  Label with some words: <value>    
    def extract_value(line, re = /\s+(.*)\s*:(.*)\s*$/)
      re.match(line)
      $2.strip unless $2.nil?
    end
    
    
    ###
    # Skip items in the lines string array until a line matching the given Regexp is found.
    # return the skipped lines. The matching line is the lines[0]
    #
    def skip_to_find(lines, re) 
      skipped = []
      skipped << lines.shift while lines.length > 0 and re.match(lines[0]).nil?
      log("first line is:#{lines[0].nil? ? '-' : lines[0]}")
      skipped
    end
    
    
    ##### 
    #  Execute the given command, and check for errors.
    #  
    def run_command(cmd, &block)    
      log "will execute #{cmd}"
      if block_given?
        ret = IO.popen(cmd,&block)            
        log ("return code is #{$?}")          
        raise "cmd #{cmd} returned #{$?}" unless $? ==0 
        return ret
      else
        text = ""
        IO.popen(cmd) {|f|                
          text = f.readlines  
        }
        raise "cmd #{cmd} returned #{$?}" unless $? ==0
      end
      text
    end
    
    
    
    
  end
end
