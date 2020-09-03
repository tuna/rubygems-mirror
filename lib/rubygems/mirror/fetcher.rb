require 'net/http/persistent'
require 'time'

class Gem::Mirror::Fetcher
  # TODO  beef
  class Error < StandardError; end

  def initialize(bucket = nil, acl = nil, opts = {})
    @logger = Logger.new($stdout)
    @http = 
      if defined?(Net::HTTP::Persistent::DEFAULT_POOL_SIZE)
        Net::HTTP::Persistent.new(name: self.class.name, proxy: :ENV)
      else
        # net-http-persistent < 3.0
        Net::HTTP::Persistent.new(self.class.name, :ENV)
      end

    @acl = acl
    @bucket = bucket
    @opts = opts

    # default opts
    @opts[:retries] ||= 1
    @opts[:skiperror] = true if @opts[:skiperror].nil?
  end

  # Fetch a source path under the base uri, and put it in the same or given
  # destination path under the base path.
  def fetch(uri, path, s3 = true)
    modified_time = File.exist?(path) && File.stat(path).mtime.rfc822

    req = Net::HTTP::Get.new URI.parse(uri).path
    req.add_field 'If-Modified-Since', modified_time if modified_time

    retries = @opts[:retries]

    begin
      # Net::HTTP will throw an exception on things like http timeouts.
      # Therefore some generic error handling is needed in case no response
      # is returned so the whole mirror operation doesn't abort prematurely.
      begin
        @http.request URI(uri), req do |resp|
          return handle_response(resp, path, s3)
        end
      rescue Exception => e
        @logger.warn "Error connecting to #{uri.to_s}: #{e.message}"
      end
    rescue Error
      retries -= 1
      retry if retries > 0
      raise if not @opts[:skiperror]
    end
  end

  # Handle an http response, follow redirects, etc. returns true if a file was
  # downloaded, false if a 304. Raise Error on unknown responses.
  def handle_response(resp, path, s3)
    case resp.code.to_i
    when 304
    when 301, 302
      fetch resp['location'], path, s3
    when 200
      write_file(resp, path, s3)
    when 403, 404
      raise Error,"#{resp.code} on #{File.basename(path)}"
    else
      raise Error, "unexpected response #{resp.inspect}"
    end
    # TODO rescue http errors and reraise cleanly
  end

  # Efficiently writes an http response object to a particular path. If there
  # is an error, it will remove the target file.
  def write_file(resp, path, s3)
    if s3
      begin
        obj = @bucket.object(path)
        obj.upload_stream :acl => @acl do |dest|
          resp.read_body { |chunk| dest << chunk }
        end
      ensure
        obj = @bucket.object(path)
        obj.delete() rescue nil if $!
      end
    else
      begin
        FileUtils.mkdir_p File.dirname(path)
        File.open(path, 'wb') do |output|
          resp.read_body { |chunk| output << chunk }
      ensure
        # cleanup incomplete files, rescue perm errors etc, they're being
        # raised already.
        File.delete(path) rescue nil if $!
        end
      end
    end
    true
  end

end
