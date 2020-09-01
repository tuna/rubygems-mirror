require 'rubygems'
require 'fileutils'
require 'rubygems/mirror/version'
require 'aws-sdk-s3'

class Gem::Mirror
  autoload :Fetcher, 'rubygems/mirror/fetcher'
  autoload :Pool, 'rubygems/mirror/pool'

  SPECS_FILES = [ "specs.#{Gem.marshal_version}", "prerelease_specs.#{Gem.marshal_version}", "latest_specs.#{Gem.marshal_version}" ]

  DEFAULT_URI = 'http://production.cf.rubygems.org/'
  DEFAULT_TO = File.join(Gem.user_home, '.gem', 'mirror')

  RUBY = 'ruby'

  def initialize(from = DEFAULT_URI, to = DEFAULT_TO, bucket = nil, region = nil, parallelism = nil, retries = nil, skiperror = nil)
    @s3 = Aws::S3::Resource.new(region: region)
    @bucket = @s3.bucket(bucket)
    @from, @to = from, to
    @fetcher = Fetcher.new @bucket, :retries => retries, :skiperror => skiperror
    @pool = Pool.new(parallelism || 10)
  end

  def from(*args)
    File.join(@from, *args)
  end

  def to(*args)
    File.join(@to, *args)
  end

  def update_specs
    SPECS_FILES.each do |sf|
      sfz = "#{sf}.gz"
      puts "Fetching: #{from(sfz)}"
      specz = to(sfz)
      @fetcher.fetch(from(sfz), specz, s3=false)
      open(to(sf), 'wb') { |f| f << Gem::Util.gunzip(File.binread(specz)) }

      puts "Uploading: #{sfz}"
      dst = @bucket.object(sfz)
      dst.upload_file(to(sfz), acl: 'public-read')

      puts "Uploading: #{sf}"
      dst = @bucket.object(sf)
      dst.upload_file(to(sf), acl: 'public-read')
    end
  end

  def gems
    gems = []

    SPECS_FILES.each do |sf|
      update_specs unless File.exist?(to(sf))

      gems += Marshal.load(File.binread(to(sf)))
    end

    if ENV["RUBYGEMS_MIRROR_ONLY_LATEST"].to_s.upcase != "TRUE"
      gems.map! do |name, ver, plat|
        # If the platform is ruby, it is not in the gem name
        "#{name}-#{ver}#{"-#{plat}" unless plat == RUBY}.gem"
      end
    else
      latest_gems = {}

      gems.each do |name, ver, plat|
        next if ver.prerelease?
        next unless plat == RUBY
        latest_gems[name] = ver
      end

      gems = latest_gems.map do |name, ver|
        "#{name}-#{ver}.gem"
      end
    end

    gems
  end

  def existing_gems
    @bucket.objects(prefix: 'rubygems/gems').collect(&:key).map { |f| File.basename(f) }
  end

  def existing_gemspecs
    @bucket.objects(prefix: "rubygems/quick/Marshal.#{Gem.marshal_version}").collect(&:key).map { |f| File.basename(f) }
  end

  def gems_to_fetch
    gems - existing_gems
  end

  def gemspecs_to_fetch
    gems.map { |g| "#{g}spec.rz" } - existing_gemspecs
  end

  def gems_to_delete
    existing_gems - gems
  end

  def update_gems
    gems_to_fetch.each do |g|
      @pool.job do
        @fetcher.fetch(from('gems', g), "rubygems/gems/#{g}")
        yield if block_given?
      end
    end

    if ENV["RUBYGEMS_MIRROR_ONLY_LATEST"].to_s.upcase != "TRUE"
      gemspecs_to_fetch.each do |g_spec|
        @pool.job do
          @fetcher.fetch(from("quick/Marshal.#{Gem.marshal_version}", g_spec), "rubygems/quick/Marshal.#{Gem.marshal_version}/#{g_spec}")
          yield if block_given?
        end
      end
    end

    @pool.run_til_done
  end

  def delete_gems
    gems_to_delete.each do |g|
      @pool.job do
        obj = @bucket.object("rubygems/gems/${g}")
        obj.delete()
        yield if block_given?
      end
    end

    @pool.run_til_done
  end

  def update
    update_specs
    update_gems
    cleanup_gems
  end
end
