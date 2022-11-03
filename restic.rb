#!/usr/bin/env ruby
#
# Restic backup wrapper
#
require 'fileutils'
require 'logger'
require 'optparse'
require 'yaml'

RUNDIR=__dir__
CONFDIR=__dir__
APPNAME="ResticBackup"
RESTIC="/usr/local/bin/restic"

def notify(msg)
  cmd = "/usr/bin/osascript -e 'display notification \""
  cmd << msg
  cmd << "\" with title \"#{APPNAME}\"'"
  system cmd
end

class GLogger
  def self.log
	if @logger.nil?
		if ENV['LOGFILE']
			@logger = Logger.new(ENV['LOGFILE'], 'monthly')
		else
			@logger = Logger.new(STDERR)
		end
		@logger.level = Logger::WARN
	    @logger.datetime_format = '%Y-%m-%d %H:%M:%S '
    end
    @logger
  end
end

def logger
	GLogger.log
end

class Volume
	attr_reader :uuid, :path, :state
	def initialize(id)
		@uuid=id
		@lockfile="#{RUNDIR}/#{@uuid}.lock"
		set_state
		check
	end

	def locked? 
		File.exists?(@lockfile)
	end

	def lock
		return false if File.exists?(@lockfile)
		FileUtils.touch(@lockfile)
		raise "Could not create lock file #{@lockfile}" unless File.exists?(@lockfile) 
		true
	end

	def unlock
		return unless File.exists?(@lockfile)
		FileUtils.rm(@lockfile)
		raise "Could not remove lock file #{@lockfile}" if File.exists?(@lockfile) 
	end

	def mounted?
		return @state == "mounted"
	end

	def attached?
		return @state != "unknown"
	end

	# Get rid of dangling lock files
	def check
		if self.locked? && (!self.attached? || !self.mounted?)
			unlock
		end
	end

	# The following command returns:
	#   an empty string if the volume is not attached, 
	#   "null"          if the volume is attached but not mounted
	#   the mount point if the volume is attached and mounted
	# diskutil list -plist external | plutil -convert json -o - - | jq '..|objects|.["APFSVolumes"]|arrays|.[]|select(.VolumeUUID == "0142FD6F-7AE2-4DE3-875E-A2FFE1A9EEC1")|.MountPoint'
	# The following is for wdeTM which is on a non-APFS partition.
	# diskutil list -plist external | plutil -convert json -o - - | jq '..|objects|select(.VolumeName == "wdeTM")' 
	def set_state
		jq="..|objects|.[\"APFSVolumes\"]|arrays|.[]|select(.VolumeUUID == \"#{@uuid}\")|.MountPoint"
		r=`diskutil list -plist external | plutil -convert json -o - - | /usr/local/bin/jq -r '#{jq}'`.chomp
		if r.empty?
			@state = "unknown"
			@path = nil
			@mount_count = 0
		elsif r=="null"
			@state = "unmounted"
			@path = nil
			@mount_count = 0
		else
			@state = "mounted"
			@path = r
			@mount_count = 1
		end
	end

	def mount
		return false if @state == "unknown"
		if @state == "mounted"
			@mount_count = @mount_count + 1
			return true
		end
		if mount!
			@mount_count = 1
			return true
		else			
			return false
		end
	end

	def umount
		return true unless @state == "mounted"
		@mount_count = @mount_count - 1
		if @mount_count > 0
			true
		else
			umount!
		end
	end

	def mount!
		return false if @state == "unknown"		
		return true  if @state == "mounted"
		return false unless system("diskutil quiet mount \"#{@uuid}\"")
		sleep 1
		set_state
		@state == "mounted"
	end

	def umount!
		return true unless @state == "mounted"
		unlock
		return false unless system("diskutil quiet umount \"#{@uuid}\"")
		sleep 1
		set_state
		@state == "unmounted"
	end

	def to_s
		"#{@uuid} / #{@state} / #{self.locked? ? 'locked' : 'not locked'}"
	end
end

class LastRun
	def initialize(p="#{RUNDIR}/.lastrun.marshal")
		@path=p
		load!
	end

	def touch(r,d)
		@data[r] ||= {}
		@data[r][d] = Time.now
		save!
	end

	# return time interval in seconds since last update
	def dt(r, d)
		t0 = (@data[r] && @data[r][d]) ? @data[r][d] : Time.at(0)
		t1 = Time.now
		(t1 - t0).to_i
	end

	def load!
		if File.exist?(@path)
			@data = Marshal.load(File.open(@path))
		else
			@data = {}
		end
	end

	def save!
		File.open(@path, "w") { |f| f.write Marshal.dump(@data) }
	end

	def to_yaml
		@data.to_yaml
	end

end

class Repo
	@@last = LastRun.new()
	KEEP = {
		"hourly" => "--keep-hourly 18 --keep-daily 6 --keep-weekly 4 --keep-monthly 4",
		"daily"  => "--keep-hourly 1 --keep-daily 6 --keep-weekly 4 --keep-monthly 4",
		"weekly" => "--keep-hourly 0 --keep-daily 1 --keep-weekly 4 --keep-monthly 4",
	}

	INT2SEC = {
		"hourly"  => 3600,
		"daily"   => 3600*24,
		"weekly"  => 3600*24*7,
		"monthly" => 31556952/12,
		"yearly"  => 31556952
	}

	attr_reader :name, :volume, :base, :dirs
	def initialize(h)
		@name   = h['name']
		@volume = h['volume']
		@freq   = h['freq']
		@dt     = Repo::INT2SEC[@freq] || Repo::INT2SEC["daily"]
		@base   = h['base']
		@dirs   = h['dirs']
		@keep   = Repo::KEEP[@freq] || Repo::KEEP["daily"]
	end

	def duedirs
		@dirs.select{|d| @@last.dt(@name, d) > @dt }
	end

	def to_s
		"#{@freq}\n" << @dirs.map{|d| "- #{@base}/#{d}"}.join("\n")
	end

	def something_to_do?
		!self.duedirs.empty?
	end

	def backup(host)
		dd=self.duedirs
		logger.debug "Backup #{@name}: #{dd.count}/#{@dirs.count} due directories"
		return true if dd.empty?
		# Restic do locks the repo but I want the lock to be volume-wide so 
		# no two backups are running on the same volume (USB external disk).
		return false unless @volume.mount
		return false unless @volume.lock

		logger.debug "Backup #{@name}: volume ok"

		restic="#{RESTIC} --repo #{@volume.path}/#{@name}"
		ef="#{CONFDIR}/excludes.txt"
		excl = File.exists?(ef) ? "--exclude-file=#{ef}" : ""
		dd.each do |d|
			p = "#{@base}/#{d}"
			ef= "#{p}/.excludes"
			eexcl = File.exists?(ef) ? "--exclude-file=#{ef}" : ""
			r = system "#{restic} backup --host=#{host} #{excl} #{eexcl} #{p}"
			@@last.touch(@name, d) if r
			logger.info "Backup of #{p} into #{@name}. #{r ? 'Done.' : 'Error!'}" 
		end
		r = system "#{restic} forget --prune #{@keep}"
		logger.info "Cleaning of #{@name}. #{r ? 'Done.' : 'Error!'}"
		@volume.unlock
		@volume.umount
	end

	def snapshots
		return "Could not mount volume" unless @volume.mount
		repo="#{@volume.path}/#{@name}"
		ret=`#{RESTIC} --repo #{repo} snapshots`		
		@volume.umount
		ret
	end

end	

# ------------------------------------------------------------------------------

args = {
	verbose: 0,
	notify: false,
	devices: [],
	repos: [],
	file: "#{CONFDIR}/backups.yml",
	umount: false,
}

OptionParser.new do |opts|
  opts.banner = """
  	Usage:
  	restic.rb [options] command ... 
    -
  	Where command is one of:
  	list    to see the configured volumes and repos
  	inspect like list but with details about the restic snapshots
  	backup  to perform the backup of due configured paths
    -
  	Options:
  """.gsub(/^\s+/, '')

  opts.on("-v", "--verbose", "Increase verbosity level") do
    args[:verbose] = args[:verbose] + 1
  end

  opts.on("-n", "--notify", "Send notification to screen") do
  	args[:notify] = true
  end
 
  opts.on("-dNAME", "--device=NAME", "Limit to the provided list of devices") do |p|
  	args[:devices] << p
  end

  opts.on("-rNAME", "--repo=NAME", "Limit to the provided list of repos") do |p|
  	args[:repos] << p
  end

  opts.on("-cPATH", "--config=PATH", "Read config from given file instead of #{args[:file]}") do |p|
  	args[:file] = p
  end

  opts.on("-u", "--umount", "Force umount after backup is done") do 
  	args[:umount] = true
  end
end.parse!

cmd=ARGV.first || "backup"

args[:verbose].times do
	logger.level = logger.level - 1 if logger.level > 0
end

# ------------------------------------------------------------------------------

cfg=YAML.load_file args[:file]

# Environment variable have precedence over configuration file
unless ENV['RESTIC_PASSWORD']
	rp = cfg['restic_password'] || YAML.load_file(cfg['passfile'])[cfg['passkey']]
	raise "Could not determine a password for restic" if rp.nil? || rp.empty?
	ENV['RESTIC_PASSWORD']=rp
end

repos=[]
volumes={}
cfg['volumes'].each do |k,uuid| 
	if args[:devices].empty? or args[:devices].include?(k)
		volumes[k] = Volume.new(uuid)
	end
end
cfg['repos'].each do |k,rd|
	v = volumes[rd['volume']]
	next if v.nil?
	if args[:repos].empty? or args[:repos].include?(k)
		repos << Repo.new(rd.merge({'volume' => v, 'name' => k}))
	end
end

logger.debug "Volumes: #{volumes.inspect}"
logger.debug "Repos:   #{repos.inspect}"
logger.debug "Cmd:     #{cmd}"

case cmd
when "backup"
	unless repos.any? { |r| r.something_to_do? }
		logger.debug "Nothing to do yet."
		exit
	end
	allok=true
	logger.info "Running backup"
	volumes.each_value {|v| v.mount }
	repos.each do |r| 
		ok=r.backup(cfg['host'])
		allok = allok && ok
	end
	volumes.each_value {|v| v.umount }
	logger.info  "Done backup #{allok ? 'without errors' : 'with some error'}"
	if  args[:notify]
		notify "Done backup #{allok ? 'without errors' : 'with some error'}"
	end
when "list"
	puts "\nConfigured Volumes:"
	volumes.each do |k,v|
		puts "  #{k}: #{v.to_s}"
	end

	puts "\nConfigured backups:"
	repos.each do |r|
		puts "  #{r.name}:"
		puts r.to_s.gsub(/^/, "    ")
	end
when "inspect"
	puts "\nConfigured Volumes:"
	volumes.each do |k,v|
		puts "  #{k}: #{v.to_s}"
	end

	puts "\nConfigured backups:"
	volumes.each_value {|v| v.mount }
	repos.each do |r|
		if r.volume.mounted? 
			puts "\n  #{r.name}:"
			puts r.snapshots.gsub(/^/, "    ").lines[2..-3].join()
		else
			puts "\n  #{r.name}:\n    volume not mounted"
		end
	end
	volumes.each_value {|v| v.umount }
end
if args[:umount]
	volumes.each_value {|v| v.umount! }
end