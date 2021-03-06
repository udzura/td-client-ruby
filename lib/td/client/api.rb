require 'td/client/api_error'
require 'td/client/version'
require 'td/client/api/access_control'
require 'td/client/api/account'
require 'td/client/api/bulk_import'
require 'td/client/api/database'
require 'td/client/api/export'
require 'td/client/api/import'
require 'td/client/api/job'
require 'td/client/api/partial_delete'
require 'td/client/api/result'
require 'td/client/api/schedule'
require 'td/client/api/server_status'
require 'td/client/api/table'
require 'td/client/api/user'

# For disabling SSLv3 connection in favor of POODLE Attack protection
require 'td/core_ext/openssl/ssl/sslcontext/set_params'

module TreasureData

class API
  include API::AccessControl
  include API::Account
  include API::BulkImport
  include API::Database
  include API::Export
  include API::Import
  include API::Job
  include API::PartialDelete
  include API::Result
  include API::Schedule
  include API::ServerStatus
  include API::Table
  include API::User

  DEFAULT_ENDPOINT = 'api.treasure-data.com'
  DEFAULT_IMPORT_ENDPOINT = 'api-import.treasure-data.com'

  NEW_DEFAULT_ENDPOINT = 'api.treasuredata.com'
  NEW_DEFAULT_IMPORT_ENDPOINT = 'api-import.treasuredata.com'

  def initialize(apikey, opts={})
    require 'json'
    require 'time'
    require 'uri'
    require 'net/http'
    require 'net/https'
    require 'time'
    #require 'faraday' # faraday doesn't support streaming upload with httpclient yet so now disabled
    require 'httpclient'
    require 'zlib'
    require 'stringio'
    require 'cgi'
    require 'msgpack'

    @apikey = apikey
    @user_agent = "TD-Client-Ruby: #{TreasureData::Client::VERSION}"
    @user_agent = "#{opts[:user_agent]}; " + @user_agent if opts.has_key?(:user_agent)

    endpoint = opts[:endpoint] || ENV['TD_API_SERVER'] || DEFAULT_ENDPOINT
    uri = URI.parse(endpoint)

    @connect_timeout = opts[:connect_timeout] || 60
    @read_timeout = opts[:read_timeout] || 600
    @send_timeout = opts[:send_timeout] || 600
    @retry_post_requests = opts[:retry_post_requests] || false
    @max_cumul_retry_delay = opts[:max_cumul_retry_delay] || 600

    case uri.scheme
    when 'http', 'https'
      @host = uri.host
      @port = uri.port
      # the opts[:ssl] option is ignored here, it's value
      #   overridden by the scheme of the endpoint URI
      @ssl = (uri.scheme == 'https')
      @base_path = uri.path.to_s

    else
      if uri.port
        # invalid URI
        raise "Invalid endpoint: #{endpoint}"
      end

      # generic URI
      @host, @port = endpoint.split(':', 2)
      @port = @port.to_i
      if opts[:ssl]
        @port = 443 if @port == 0
        @ssl = true
      else
        @port = 80 if @port == 0
        @ssl = false
      end
      @base_path = ''
    end

    @http_proxy = opts[:http_proxy] || ENV['HTTP_PROXY']
    if @http_proxy
      http_proxy = if @http_proxy =~ /\Ahttp:\/\/(.*)\z/
                     $~[1]
                   else
                     @http_proxy
                   end
      proxy_host, proxy_port = http_proxy.split(':', 2)
      proxy_port = (proxy_port ? proxy_port.to_i : 80)
      @http_class = Net::HTTP::Proxy(proxy_host, proxy_port)
    else
      @http_class = Net::HTTP
    end

    @headers = opts[:headers] || {}
  end

  # TODO error check & raise appropriate errors

  attr_reader :apikey

  def self.normalized_msgpack(record, out = nil)
    record.keys.each { |k|
      v = record[k]
      if v.kind_of?(Bignum)
        record[k] = v.to_s
      end
    }
    record.to_msgpack(out)
  end

  def self.validate_name(target, min_len, max_len, name)
    if !target.instance_of?(String) || target.empty?
      raise ParameterValidationError,
            "A valid target name is required"
    end

    name = name.to_s
    if name.empty?
      raise ParameterValidationError,
            "Empty #{target} name is not allowed"
    end
    if name.length < min_len || name.length > max_len
      raise ParameterValidationError,
            "#{target.capitalize} name must be between #{min_len} and #{max_len} characters long. Got #{name.length} " +
            (name.length == 1 ? "character" : "characters") + "."
    end
    unless name =~ /^([a-z0-9_]+)$/
      raise ParameterValidationError,
            "#{target.capitalize} name must only consist of lower-case alpha-numeric characters and '_'."
    end

    name
  end

  def self.validate_database_name(name)
    validate_name("database", 3, 255, name)
  end

  def self.validate_table_name(name)
    validate_name("table", 3, 255, name)
  end

  def self.validate_result_set_name(name)
    validate_name("result set", 3, 255, name)
  end

  def self.validate_column_name(name)
    validate_name("column", 1, 255, name)
  end

  def self.normalize_database_name(name)
    name = name.to_s
    if name.empty?
      raise "Empty name is not allowed"
    end
    if name.length < 3
      name += "_" * (3 - name.length)
    end
    if 255 < name.length
      name = name[0, 253] + "__"
    end
    name = name.downcase
    name = name.gsub(/[^a-z0-9_]/, '_')
    name
  end

  def self.normalize_table_name(name)
    normalize_database_name(name)
  end

  # TODO support array types
  def self.normalize_type_name(name)
    case name
    when /int/i, /integer/i
      "int"
    when /long/i, /bigint/i
      "long"
    when /string/i
      "string"
    when /float/i
      "float"
    when /double/i
      "double"
    else
      raise "Type name must eather of int, long, string float or double"
    end
  end

  # for fluent-plugin-td / td command to check table existence with import onlt user
  def self.create_empty_gz_data
    io = StringIO.new
    Zlib::GzipWriter.new(io).close
    io.string
  end

  def ssl_ca_file=(ssl_ca_file)
    @ssl_ca_file = ssl_ca_file
  end

private

  module DeflateReadBodyMixin
    attr_accessor :gzip

    def each_fragment(&block)
      if @gzip
        infl = Zlib::Inflate.new(Zlib::MAX_WBITS + 16)
      else
        infl = Zlib::Inflate.new
      end
      begin
        read_body {|fragment|
          block.call infl.inflate(fragment)
        }
      ensure
        infl.close
      end
      nil
    end
  end

  module DirectReadBodyMixin
    def each_fragment(&block)
      read_body(&block)
    end
  end

  def get(url, params=nil, &block)
    guard_no_sslv3 do
      do_get(url, params, &block)
    end
  end

  def do_get(url, params=nil, &block)
    http, header = new_http

    path = @base_path + url
    if params && !params.empty?
      path << "?"+params.map {|k,v|
        "#{k}=#{e v}"
      }.join('&')
    end

    header['Accept-Encoding'] = 'deflate, gzip'
    request = Net::HTTP::Get.new(path, header)

    unless ENV['TD_CLIENT_DEBUG'].nil?
      puts "DEBUG: REST GET call:"
      puts "DEBUG:   header: " + header.to_s
      puts "DEBUG:   path:   " + path.to_s
      puts "DEBUG:   params: " + params.to_s
    end

    # up to 7 retries with exponential (base 2) back-off starting at 'retry_delay'
    retry_delay = 5
    cumul_retry_delay = 0

    # for both exceptions and 500+ errors retrying is enabled by default.
    # The total number of retries cumulatively should not exceed 10 minutes / 600 seconds
    response = nil
    begin # this block is to allow retry (redo) in the begin part of the begin-rescue block
      begin
        if block
          response = http.request(request) {|res|
            block.call(res)
          }
        else
          response = http.request(request)
        end

        status = response.code.to_i
        # retry if the HTTP error code is 500 or higher and we did not run out of retrying attempts
        if !block_given? && status >= 500 && cumul_retry_delay <= @max_cumul_retry_delay
          $stderr.puts "Error #{status}: #{get_error(response)}. Retrying after #{retry_delay} seconds..."
          sleep retry_delay
          cumul_retry_delay += retry_delay
          retry_delay *= 2
          redo # restart from beginning of do-while loop
        end
      rescue Errno::ECONNREFUSED, Errno::ECONNRESET, Timeout::Error, EOFError, OpenSSL::SSL::SSLError, SocketError => e
        if block_given?
          raise e
        end
        $stderr.print "#{e.class}: #{e.message}. "
        if cumul_retry_delay <= @max_cumul_retry_delay
          $stderr.puts "Retrying after #{retry_delay} seconds..."
          sleep retry_delay
          cumul_retry_delay += retry_delay
          retry_delay *= 2
          retry
        else
          $stderr.puts "Retrying stopped after #{@max_cumul_retry_delay} seconds."
          raise e
        end
      rescue => e
        raise e
      end
    end while false

    unless ENV['TD_CLIENT_DEBUG'].nil?
      puts "DEBUG: REST GET response:"
      puts "DEBUG:   header: " + response.header.to_s
      puts "DEBUG:   status: " + response.code.to_s
      puts "DEBUG:   body:   " + response.body.to_s
    end

    body = response.body
    unless block
      if ce = response.header['content-encoding']
        if ce == 'gzip'
          infl = Zlib::Inflate.new(Zlib::MAX_WBITS + 16)
          begin
            body = infl.inflate(body)
          ensure
            infl.close
          end
        else
          body = Zlib::Inflate.inflate(body)
        end
      end
    end

    return [response.code, body, response]
  end

  def post(url, params=nil)
    guard_no_sslv3 do
      do_post(url, params)
    end
  end

  def do_post(url, params=nil)
    http, header = new_http

    path = @base_path + url

    unless ENV['TD_CLIENT_DEBUG'].nil?
      puts "DEBUG: REST POST call:"
      puts "DEBUG:   header: " + header.to_s
      puts "DEBUG:   path:   " + path.to_s
      puts "DEBUG:   params: " + params.to_s
    end

    if params && !params.empty?
      request = Net::HTTP::Post.new(path, header)
      request.set_form_data(params)
    else
      header['Content-Length'] = 0.to_s
      request = Net::HTTP::Post.new(path, header)
    end

    # up to 7 retries with exponential (base 2) back-off starting at 'retry_delay'
    retry_delay = 5
    cumul_retry_delay = 0

    # for both exceptions and 500+ errors retrying can be enabled by initialization
    # parameter 'retry_post_requests'. The total number of retries cumulatively
    # should not exceed 10 minutes / 600 seconds
    response = nil
    begin # this block is to allow retry (redo) in the begin part of the begin-rescue block
      begin
        response = http.request(request)

        # if the HTTP error code is 500 or higher and the user requested retrying
        # on post request, attempt a retry
        status = response.code.to_i
        if @retry_post_requests && status >= 500 && cumul_retry_delay <= @max_cumul_retry_delay
          $stderr.puts "Error #{status}: #{get_error(response)}. Retrying after #{retry_delay} seconds..."
          sleep retry_delay
          cumul_retry_delay += retry_delay
          retry_delay *= 2
          redo # restart from beginning of do-while loop
        end
      rescue Errno::ECONNREFUSED, Errno::ECONNRESET, Timeout::Error, EOFError, OpenSSL::SSL::SSLError, SocketError => e
        $stderr.print "#{e.class}: #{e.message}. "
        if @retry_post_requests && cumul_retry_delay <= @max_cumul_retry_delay
          $stderr.puts "Retrying after #{retry_delay} seconds..."
          sleep retry_delay
          cumul_retry_delay += retry_delay
          retry_delay *= 2
          retry
        else
          $stderr.puts "Retrying stopped after #{@max_cumul_retry_delay} seconds."
          raise e
        end
      rescue => e
        raise e
      end
    end while false

    unless ENV['TD_CLIENT_DEBUG'].nil?
      puts "DEBUG: REST POST response:"
      puts "DEBUG:   header: " + response.header.to_s
      puts "DEBUG:   status: " + response.code.to_s
      puts "DEBUG:   body:   <omitted>"
    end

    return [response.code, response.body, response]
  end

  def put(url, stream, size, opts = {})
    client, header = new_client(opts)
    client.send_timeout = @send_timeout
    client.receive_timeout = @read_timeout

    header['Content-Type'] = 'application/octet-stream'
    header['Content-Length'] = size.to_s

    body = if stream.class.name == 'StringIO'
             stream.string
           else
             stream
           end
    target = build_endpoint(url, opts[:host] || @host)

    unless ENV['TD_CLIENT_DEBUG'].nil?
      puts "DEBUG: REST PUT call:"
      puts "DEBUG:   header: " + header.to_s
      puts "DEBUG:   target: " + target.to_s
      puts "DEBUG:   body:   " + body.to_s
    end

    response = client.put(target, body, header)
    begin
      unless ENV['TD_CLIENT_DEBUG'].nil?
        puts "DEBUG: REST PUT response:"
        puts "DEBUG:   header: " + response.header.to_s
        puts "DEBUG:   status: " + response.code.to_s
        puts "DEBUG:   body:   <omitted>"
      end
      return [response.code.to_s, response.body, response]
    ensure
      # Disconnect keep-alive connection explicitly here, not by GC.
      client.reset(target) rescue nil
    end
  end

  def build_endpoint(url, host)
    schema = @ssl ? 'https' : 'http'
    "#{schema}://#{host}:#{@port}#{@base_path + url}"
  end

  def guard_no_sslv3
    key = :SET_SSL_OP_NO_SSLv3
    backup = Thread.current[key]
    begin
      # Disable SSLv3 connection: See Net::HTTP hack at the bottom
      Thread.current[key] = true
      yield
    ensure
      # backup could be nil, but assigning nil to TLS means 'delete'
      Thread.current[key] = backup
    end
  end

  def new_http(opts = {})
    host = opts[:host] || @host
    http = @http_class.new(host, @port)
    http.open_timeout = 60
    if @ssl
      http.use_ssl = true
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      #store = OpenSSL::X509::Store.new
      #http.cert_store = store
      http.ca_file = File.join(ssl_ca_file)
      # Disable SSLv3 connection in favor of POODLE Attack protection
      # ruby 1.8.7 uses own @ssl_context instead of calling
      # SSLContext#set_params.
      if ctx = http.instance_eval { @ssl_context }
        ctx.options = OpenSSL::SSL::OP_ALL | OpenSSL::SSL::OP_NO_SSLv3
      end
    end

    header = {}
    if @apikey
      header['Authorization'] = "TD1 #{apikey}"
    end
    header['Date'] = Time.now.rfc2822
    header['User-Agent'] = @user_agent

    header.merge!(@headers)

    return http, header
  end

  def new_client(opts = {})
    client = HTTPClient.new(@http_proxy, @user_agent)
    client.connect_timeout = @connect_timeout

    if @ssl
      client.ssl_config.add_trust_ca(ssl_ca_file)
      client.ssl_config.verify_mode = OpenSSL::SSL::VERIFY_PEER
      # Disable SSLv3 connection in favor of POODLE Attack protection
      client.ssl_config.options |= OpenSSL::SSL::OP_NO_SSLv3
    end

    header = {}
    if @apikey
      header['Authorization'] = "TD1 #{apikey}"
    end
    header['Date'] = Time.now.rfc2822

    header.merge!(@headers)

    return client, header
  end

  def ssl_ca_file
    @ssl_ca_file ||= File.join(File.dirname(__FILE__), '..', '..', '..', 'data', 'ca-bundle.crt')
  end

  def get_error(res)
    begin
      js = JSON.load(res.body)
      if js.nil?
        error_msg = if res.respond_to?(:message)
                      res.message # Net::HTTP
                    else
                      res.reason # HttpClient
                    end
      else
        error_msg = js['message'] || js['error']
      end
    rescue JSON::ParserError
      error_msg = res.body
    end
    error_msg
  end

  def raise_error(msg, res, klass=nil)
    status_code = res.code.to_s
    error_msg = get_error(res)
    if klass
      raise klass, "#{status_code}: #{msg}: #{res.body}"
    elsif status_code == "404"
      raise NotFoundError, "#{msg}: #{res.body}"
    elsif status_code == "409"
      raise AlreadyExistsError, "#{msg}: #{res.body}"
    elsif status_code == "401"
      raise AuthError, "#{msg}: #{res.body}"
    elsif status_code == "403"
      raise ForbiddenError, "#{msg}: #{res.body}"
    else
      raise APIError, "#{status_code}: #{msg}: #{res.body}"
    end
    # TODO error
  end

  def e(s)
    CGI.escape(s.to_s)
  end

  def checked_json(body, required)
    js = nil
    begin
      js = JSON.load(body)
    rescue
      raise "Unexpected API response: #{$!}"
    end
    unless js.is_a?(Hash)
      raise "Unexpected API response: #{body}"
    end
    required.each {|k|
      unless js[k]
        raise "Unexpected API response: #{body}"
      end
    }
    js
  end
end

end # module TreasureData
