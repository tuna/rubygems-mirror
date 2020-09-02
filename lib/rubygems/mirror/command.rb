require 'rubygems/mirror'
require 'rubygems/command'
require 'yaml'

class Gem::Commands::MirrorCommand < Gem::Command
  SUPPORTS_INFO_SIGNAL = Signal.list['INFO']

  def initialize
    super 'mirror', 'Mirror a gem repository'
  end

  def description # :nodoc:
    <<-EOF
The mirror command uses the ~/.gem/.mirrorrc config file to mirror
remote gem repositories to a local path. The config file is a YAML
document that looks like this:

  ---
  - from: http://gems.example.com # source repository URI
    to: /path/to/mirror           # temporary destination directory
    bucket: bucket-name           # destination s3 bucket
    region: us-east-1             # s3 region
    parallelism: 10               # use 10 threads for downloads
    retries: 3                    # retry 3 times if fail to download a gem, optional, def is 1. (no retry)
    delete: false                 # whether delete gems (if remote ones are removed),optional, default is false. 
    skiperror: true               # whether skip error, optional, def is true. will stop at error if set this to false.

Multiple sources and destinations may be specified.
    EOF
  end

  def execute
    # always flush stdout
    $stdout.sync = true
    logger = Logger.new($stdout)
    config_file = File.join Gem.user_home, '.gem', '.mirrorrc'

    raise "Config file #{config_file} not found" unless File.exist? config_file

    mirrors = YAML.load_file config_file

    raise "Invalid config file #{config_file}" unless mirrors.respond_to? :each

    mirrors.each do |mir|
      raise "mirror missing 'from' field" unless mir.has_key? 'from'
      raise "mirror missing 'to' field" unless mir.has_key? 'to'
      raise "mirror missing 'bucket' field" unless mir.has_key? 'bucket'
      raise "mirror missing 'region' field" unless mir.has_key? 'region'

      get_from = mir['from']
      save_to = mir['to']
      bucket = mir['bucket']
      region = mir['region']
      parallelism = mir['parallelism']
      retries = mir['retries'] || 1
      skiperror = mir['skiperror']
      delete = mir['delete']

      mirror = Gem::Mirror.new(get_from, save_to, bucket, region, parallelism, retries, skiperror)
      
      mirror.update_specs

      logger.info "Total gems: #{mirror.gems.size}"

      num_to_fetch = mirror.gems_to_fetch.size + mirror.gemspecs_to_fetch.size

      logger.info "Fetching #{mirror.gems_to_fetch.size} gems and #{mirror.gemspecs_to_fetch.size} gemspecs"

      gems_fetched = 0
      gems_fetched_percent = -1

      mirror.update_gems { 
        gems_fetched = gems_fetched + 1
        if gems_fetched * 100 / num_to_fetch != gems_fetched_percent
          gems_fetched_percent = gems_fetched * 100 / num_to_fetch
          logger.info "Fetched #{gems_fetched}/#{num_to_fetch}=#{gems_fetched_percent}%"
        end
      }

      if delete
        num_to_delete = mirror.gems_to_delete.size

        progress = ui.progress_reporter num_to_delete,
                                 "Deleting #{num_to_delete} gems"

        trap(:INFO) { puts "Fetched: #{progress.count}/#{num_to_delete}" } if SUPPORTS_INFO_SIGNAL

        mirror.delete_gems { progress.updated true }
      end
    end
  end
end
