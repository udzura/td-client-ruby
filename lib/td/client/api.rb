require 'td/client/version'

module TreasureData


class APIError < StandardError
end

class AuthError < APIError
end

class AlreadyExistsError < APIError
end

class NotFoundError < APIError
end


class API
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

    @apikey = apikey
    @user_agent = "TD-Client-Ruby: #{TreasureData::Client::VERSION}"
    @user_agent = "#{opts[:user_agent]}; " + @user_agent if opts.has_key?(:user_agent)

    endpoint = opts[:endpoint] || ENV['TD_API_SERVER'] || DEFAULT_ENDPOINT
    uri = URI.parse(endpoint)

    @connect_timeout = opts[:connect_timeout] || 60
    @read_timeout = opts[:read_timeout] || 600
    @send_timeout = opts[:send_timeout] || 600

    case uri.scheme
    when 'http', 'https'
      @host = uri.host
      @port = uri.port
      @ssl = uri.scheme == 'https'
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
      proxy_host, proxy_port = http_proxy.split(':',2)
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

  def self.validate_database_name(name)
    name = name.to_s
    if name.empty?
      raise "Empty name is not allowed"
    end
    if name.length < 3 || 256 < name.length
      raise "Name must be 3 to 256 characters, got #{name.length} characters."
    end
    unless name =~ /^([a-z0-9_]+)$/
      raise "Name must consist only of lower-case alphabets, numbers and '_'."
    end
    name
  end

  def self.validate_table_name(name)
    validate_database_name(name)
  end

  def self.validate_result_set_name(name)
    validate_database_name(name)
  end

  def self.validate_column_name(name)
    name = name.to_s
    if name.empty?
      raise "Empty column name is not allowed"
    end
    if 256 < name.length
      raise "Column name must be to 256 characters, got #{name.length} characters."
    end
    unless name =~ /^([a-z0-9_]+)$/
      raise "Column name must consist only of alphabets, numbers, '_'."
    end
  end

  def self.normalize_database_name(name)
    name = name.to_s
    if name.empty?
      raise "Empty name is not allowed"
    end
    if name.length < 3
      name += "_"*(3-name.length)
    end
    if 256 < name.length
      name = name[0,254]+"__"
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
    require 'zlib'
    require 'stringio'

    io = StringIO.new
    Zlib::GzipWriter.new(io).close
    io.string
  end

  ####
  ## Account API
  ##

  def show_account
    code, body, res = get("/v3/account/show")
    if code != "200"
      raise_error("Show account failed", res)
    end
    js = checked_json(body, %w[account])
    a = js["account"]
    account_id = a['id'].to_i
    plan = a['plan'].to_i
    storage_size = a['storage_size'].to_i
    guaranteed_cores = a['guaranteed_cores'].to_i
    maximum_cores = a['maximum_cores'].to_i
    created_at = a['created_at']
    return [account_id, plan, storage_size, guaranteed_cores, maximum_cores, created_at]
  end

  def account_core_utilization(from, to)
    params = { }
    params['from'] = from.to_s if from
    params['to'] = to.to_s if to
    code, body, res = get("/v3/account/core_utilization", params)
    if code != "200"
      raise_error("Show account failed", res)
    end
    js = checked_json(body, %w[from to interval history])
    from = Time.parse(js['from']).utc
    to = Time.parse(js['to']).utc
    interval = js['interval'].to_i
    history = js['history']
    return [from, to, interval, history]
  end


  ####
  ## Database API
  ##

  # => [name:String]
  def list_databases
    code, body, res = get("/v3/database/list")
    if code != "200"
      raise_error("List databases failed", res)
    end
    js = checked_json(body, %w[databases])
    result = {}
    js["databases"].each {|m|
      name = m['name']
      count = m['count']
      created_at = m['created_at']
      updated_at = m['updated_at']
      result[name] = [count, created_at, updated_at, nil] # set nil to org for API compatibiilty
    }
    return result
  end

  # => true
  def delete_database(db)
    code, body, res = post("/v3/database/delete/#{e db}")
    if code != "200"
      raise_error("Delete database failed", res)
    end
    return true
  end

  # => true
  def create_database(db, opts={})
    params = opts.dup
    code, body, res = post("/v3/database/create/#{e db}", params)
    if code != "200"
      raise_error("Create database failed", res)
    end
    return true
  end


  ####
  ## Table API
  ##

  # => {name:String => [type:Symbol, count:Integer]}
  def list_tables(db)
    code, body, res = get("/v3/table/list/#{e db}")
    if code != "200"
      raise_error("List tables failed", res)
    end
    js = checked_json(body, %w[tables])
    result = {}
    js["tables"].map {|m|
      name = m['name']
      type = (m['type'] || '?').to_sym
      count = (m['count'] || 0).to_i  # TODO?
      created_at = m['created_at']
      updated_at = m['updated_at']
      last_import = m['counter_updated_at']
      last_log_timestamp = m['last_log_timestamp']
      estimated_storage_size = m['estimated_storage_size'].to_i
      schema = JSON.parse(m['schema'] || '[]')
      expire_days = m['expire_days']
      result[name] = [type, schema, count, created_at, updated_at, estimated_storage_size, last_import, last_log_timestamp, expire_days]
    }
    return result
  end

  def create_log_or_item_table(db, table, type)
    code, body, res = post("/v3/table/create/#{e db}/#{e table}/#{type}")
    if code != "200"
      raise_error("Create #{type} table failed", res)
    end
    return true
  end
  private :create_log_or_item_table

  # => true
  def create_log_table(db, table)
    create_table(db, table, :log)
  end

  # => true
  def create_item_table(db, table, primary_key, primary_key_type)
    params = {'primary_key' => primary_key, 'primary_key_type' => primary_key_type}
    create_table(db, table, :item, params)
  end

  def create_table(db, table, type, params={})
    schema = schema.to_s
    code, body, res = post("/v3/table/create/#{e db}/#{e table}/#{type}", params)
    if code != "200"
      raise_error("Create #{type} table failed", res)
    end
    return true
  end
  private :create_table

  # => true
  def swap_table(db, table1, table2)
    code, body, res = post("/v3/table/swap/#{e db}/#{e table1}/#{e table2}")
    if code != "200"
      raise_error("Swap tables failed", res)
    end
    return true
  end

  # => true
  def update_schema(db, table, schema_json)
    code, body, res = post("/v3/table/update-schema/#{e db}/#{e table}", {'schema'=>schema_json})
    if code != "200"
      raise_error("Create schema table failed", res)
    end
    return true
  end

  def update_expire(db, table, expire_days)
    code, body, res = post("/v3/table/update/#{e db}/#{e table}", {'expire_days'=>expire_days})
    if code != "200"
      raise_error("Update table expiration failed", res)
    end
    return true
  end  

  # => type:Symbol
  def delete_table(db, table)
    code, body, res = post("/v3/table/delete/#{e db}/#{e table}")
    if code != "200"
      raise_error("Delete table failed", res)
    end
    js = checked_json(body, %w[])
    type = (js['type'] || '?').to_sym
    return type
  end

  def tail(db, table, count, to, from, &block)
    params = {'format' => 'msgpack'}
    params['count'] = count.to_s if count
    params['to'] = to.to_s if to
    params['from'] = from.to_s if from
    code, body, res = get("/v3/table/tail/#{e db}/#{e table}", params)
    if code != "200"
      raise_error("Tail table failed", res)
    end
    require 'msgpack'
    if block
      MessagePack::Unpacker.new.feed_each(body, &block)
      nil
    else
      result = []
      MessagePack::Unpacker.new.feed_each(body) {|row|
        result << row
      }
      return result
    end
  end


  ####
  ## Job API
  ##

  # => [(jobId:String, type:Symbol, status:String, start_at:String, end_at:String, result_url:String)]
  def list_jobs(from=0, to=nil, status=nil, conditions=nil)
    params = {}
    params['from'] = from.to_s if from
    params['to'] = to.to_s if to
    params['status'] = status.to_s if status
    params.merge!(conditions) if conditions
    code, body, res = get("/v3/job/list", params)
    if code != "200"
      raise_error("List jobs failed", res)
    end
    js = checked_json(body, %w[jobs])
    result = []
    js['jobs'].each {|m|
      job_id = m['job_id']
      type = (m['type'] || '?').to_sym
      database = m['database']
      status = m['status']
      query = m['query']
      start_at = m['start_at']
      end_at = m['end_at']
      result_url = m['result']
      priority = m['priority']
      retry_limit = m['retry_limit']
      result << [job_id, type, status, query, start_at, end_at, result_url, priority, retry_limit, nil, database] # same as database
    }
    return result
  end

  # => (type:Symbol, status:String, result:String, url:String, result:String)
  def show_job(job_id)
    # use v3/job/status instead of v3/job/show to poll finish of a job
    code, body, res = get("/v3/job/show/#{e job_id}")
    if code != "200"
      raise_error("Show job failed", res)
    end
    js = checked_json(body, %w[status])
    # TODO debug
    type = (js['type'] || '?').to_sym  # TODO
    database = js['database']
    query = js['query']
    status = js['status']
    debug = js['debug']
    url = js['url']
    start_at = js['start_at']
    end_at = js['end_at']
    result = js['result']
    hive_result_schema = (js['hive_result_schema'] || '')
    if hive_result_schema.empty?
      hive_result_schema = nil
    else
      hive_result_schema = JSON.parse(hive_result_schema)
    end
    priority = js['priority']
    retry_limit = js['retry_limit']
    return [type, query, status, url, debug, start_at, end_at, result, hive_result_schema, priority, retry_limit, nil, database] # same as above
  end

  def job_status(job_id)
    code, body, res = get("/v3/job/status/#{e job_id}")
    if code != "200"
      raise_error("Get job status failed", res)
    end

    js = checked_json(body, %w[status])
    return js['status']
  end

  def job_result(job_id)
    require 'msgpack'
    code, body, res = get("/v3/job/result/#{e job_id}", {'format'=>'msgpack'})
    if code != "200"
      raise_error("Get job result failed", res)
    end
    result = []
    MessagePack::Unpacker.new.feed_each(body) {|row|
      result << row
    }
    return result
  end

  def job_result_format(job_id, format, io=nil)
    if io
      code, body, res = get("/v3/job/result/#{e job_id}", {'format'=>format}) {|res|
        if res.code != "200"
          raise_error("Get job result failed", res)
        end
        res.each_fragment {|fragment|
          io.write(fragment)
        }
      }
      nil
    else
      code, body, res = get("/v3/job/result/#{e job_id}", {'format'=>format})
      if res.code != "200"
        raise_error("Get job result failed", res)
      end
      body
    end
  end

  def job_result_each(job_id, &block)
    require 'msgpack'
    get("/v3/job/result/#{e job_id}", {'format'=>'msgpack'}) {|res|
      if res.code != "200"
        raise_error("Get job result failed", res)
      end
      u = MessagePack::Unpacker.new
      res.each_fragment {|fragment|
        u.feed_each(fragment, &block)
      }
    }
    nil
  end

  def job_result_raw(job_id, format)
    code, body, res = get("/v3/job/result/#{e job_id}", {'format'=>format})
    if code != "200"
      raise_error("Get job result failed", res)
    end
    return body
  end

  def kill(job_id)
    code, body, res = post("/v3/job/kill/#{e job_id}")
    if code != "200"
      raise_error("Kill job failed", res)
    end
    js = checked_json(body, %w[])
    former_status = js['former_status']
    return former_status
  end

  # => jobId:String
  def hive_query(q, db=nil, result_url=nil, priority=nil, retry_limit=nil, opts={})
    query(q, :hive, db, result_url, priority, retry_limit, opts)
  end

  # => jobId:String
  def pig_query(q, db=nil, result_url=nil, priority=nil, retry_limit=nil, opts={})
    query(q, :pig, db, result_url, priority, retry_limit, opts)
  end

  # => jobId:String
  def query(q, type=:hive, db=nil, result_url=nil, priority=nil, retry_limit=nil, opts={})
    params = {'query' => q}.merge(opts)
    params['result'] = result_url if result_url
    params['priority'] = priority if priority
    params['retry_limit'] = retry_limit if retry_limit
    code, body, res = post("/v3/job/issue/#{type}/#{e db}", params)
    if code != "200"
      raise_error("Query failed", res)
    end
    js = checked_json(body, %w[job_id])
    return js['job_id'].to_s
  end

  ####
  ## Export API
  ##

  # => jobId:String
  def export(db, table, storage_type, opts={})
    params = opts.dup
    params['storage_type'] = storage_type
    code, body, res = post("/v3/export/run/#{e db}/#{e table}", params)
    if code != "200"
      raise_error("Export failed", res)
    end
    js = checked_json(body, %w[job_id])
    return js['job_id'].to_s
  end


  ####
  ## Partial delete API
  ##

  def partial_delete(db, table, to, from, opts={})
    params = opts.dup
    params['to'] = to.to_s
    params['from'] = from.to_s
    code, body, res = post("/v3/table/partialdelete/#{e db}/#{e table}", params)
    if code != "200"
      raise_error("Partial delete failed", res)
    end
    js = checked_json(body, %w[job_id])
    return js['job_id'].to_s
  end

  ####
  ## Bulk import API
  ##

  # => nil
  def create_bulk_import(name, db, table, opts={})
    params = opts.dup
    code, body, res = post("/v3/bulk_import/create/#{e name}/#{e db}/#{e table}", params)
    if code != "200"
      raise_error("Create bulk import failed", res)
    end
    return nil
  end

  # => nil
  def delete_bulk_import(name, opts={})
    params = opts.dup
    code, body, res = post("/v3/bulk_import/delete/#{e name}", params)
    if code != "200"
      raise_error("Delete bulk import failed", res)
    end
    return nil
  end

  # => data:Hash
  def show_bulk_import(name)
    code, body, res = get("/v3/bulk_import/show/#{name}")
    if code != "200"
      raise_error("Show bulk import failed", res)
    end
    js = checked_json(body, %w[status])
    return js
  end

  # => result:[data:Hash]
  def list_bulk_imports(opts={})
    params = opts.dup
    code, body, res = get("/v3/bulk_import/list", params)
    if code != "200"
      raise_error("List bulk imports failed", res)
    end
    js = checked_json(body, %w[bulk_imports])
    return js['bulk_imports']
  end

  def list_bulk_import_parts(name, opts={})
    params = opts.dup
    code, body, res = get("/v3/bulk_import/list_parts/#{e name}", params)
    if code != "200"
      raise_error("List bulk import parts failed", res)
    end
    js = checked_json(body, %w[parts])
    return js['parts']
  end

  # => nil
  def bulk_import_upload_part(name, part_name, stream, size, opts={})
    code, body, res = put("/v3/bulk_import/upload_part/#{e name}/#{e part_name}", stream, size)
    if code[0] != ?2
      raise_error("Upload a part failed", res)
    end
    return nil
  end

  # => nil
  def bulk_import_delete_part(name, part_name, opts={})
    params = opts.dup
    code, body, res = post("/v3/bulk_import/delete_part/#{e name}/#{e part_name}", params)
    if code[0] != ?2
      raise_error("Delete a part failed", res)
    end
    return nil
  end

  # => nil
  def freeze_bulk_import(name, opts={})
    params = opts.dup
    code, body, res = post("/v3/bulk_import/freeze/#{e name}", params)
    if code != "200"
      raise_error("Freeze bulk import failed", res)
    end
    return nil
  end

  # => nil
  def unfreeze_bulk_import(name, opts={})
    params = opts.dup
    code, body, res = post("/v3/bulk_import/unfreeze/#{e name}", params)
    if code != "200"
      raise_error("Unfreeze bulk import failed", res)
    end
    return nil
  end

  # => jobId:String
  def perform_bulk_import(name, opts={})
    params = opts.dup
    code, body, res = post("/v3/bulk_import/perform/#{e name}", params)
    if code != "200"
      raise_error("Perform bulk import failed", res)
    end
    js = checked_json(body, %w[job_id])
    return js['job_id'].to_s
  end

  # => nil
  def commit_bulk_import(name, opts={})
    params = opts.dup
    code, body, res = post("/v3/bulk_import/commit/#{e name}", params)
    if code != "200"
      raise_error("Commit bulk import failed", res)
    end
    return nil
  end

  # => data...
  def bulk_import_error_records(name, opts={}, &block)
    params = opts.dup
    code, body, res = get("/v3/bulk_import/error_records/#{e name}", params)
    if code != "200"
      raise_error("Failed to get bulk import error records", res)
    end
    if body.empty?
      if block
        return nil
      else
        return []
      end
    end
    require 'zlib'
    require 'stringio'
    require 'msgpack'
    require File.expand_path('compat_gzip_reader', File.dirname(__FILE__))
    u = MessagePack::Unpacker.new(Zlib::GzipReader.new(StringIO.new(body)))
    if block
      begin
        u.each(&block)
      rescue EOFError
      end
      nil
    else
      result = []
      begin
        u.each {|row|
          result << row
        }
      rescue EOFError
      end
      return result
    end
  end

  ####
  ## Schedule API
  ##

  # => start:String
  def create_schedule(name, opts)
    params = opts.update({:type=> opts[:type] || opts['type'] || 'hive'})
    code, body, res = post("/v3/schedule/create/#{e name}", params)
    if code != "200"
      raise_error("Create schedule failed", res)
    end
    js = checked_json(body, %w[start])
    return js['start']
  end

  # => cron:String, query:String
  def delete_schedule(name)
    code, body, res = post("/v3/schedule/delete/#{e name}")
    if code != "200"
      raise_error("Delete schedule failed", res)
    end
    js = checked_json(body, %w[])
    return js['cron'], js["query"]
  end

  # => [(name:String, cron:String, query:String, database:String, result_url:String)]
  def list_schedules
    code, body, res = get("/v3/schedule/list")
    if code != "200"
      raise_error("List schedules failed", res)
    end
    js = checked_json(body, %w[schedules])
    result = []
    js['schedules'].each {|m|
      name = m['name']
      cron = m['cron']
      query = m['query']
      database = m['database']
      result_url = m['result']
      timezone = m['timezone']
      delay = m['delay']
      next_time = m['next_time']
      priority = m['priority']
      retry_limit = m['retry_limit']
      result << [name, cron, query, database, result_url, timezone, delay, next_time, priority, retry_limit, nil] # same as database
    }
    return result
  end

  def update_schedule(name, params)
    code, body, res = get("/v3/schedule/update/#{e name}", params)
    if code != "200"
      raise_error("Update schedule failed", res)
    end
    return nil
  end

  def history(name, from=0, to=nil)
    params = {}
    params['from'] = from.to_s if from
    params['to'] = to.to_s if to
    code, body, res = get("/v3/schedule/history/#{e name}", params)
    if code != "200"
      raise_error("List history failed", res)
    end
    js = checked_json(body, %w[history])
    result = []
    js['history'].each {|m|
      job_id = m['job_id']
      type = (m['type'] || '?').to_sym
      database = m['database']
      status = m['status']
      query = m['query']
      start_at = m['start_at']
      end_at = m['end_at']
      scheduled_at = m['scheduled_at']
      result_url = m['result']
      priority = m['priority']
      result << [scheduled_at, job_id, type, status, query, start_at, end_at, result_url, priority, database]
    }
    return result
  end

  def run_schedule(name, time, num)
    params = {}
    params = {'num' => num} if num
    code, body, res = post("/v3/schedule/run/#{e name}/#{e time}", params)
    if code != "200"
      raise_error("Run schedule failed", res)
    end
    js = checked_json(body, %w[jobs])
    result = []
    js['jobs'].each {|m|
      job_id = m['job_id']
      scheduled_at = m['scheduled_at']
      type = (m['type'] || '?').to_sym
      result << [job_id, type, scheduled_at]
    }
    return result
  end

  ####
  ## Import API
  ##

  # => time:Float
  def import(db, table, format, stream, size, unique_id=nil)
    if unique_id
      path = "/v3/table/import_with_id/#{e db}/#{e table}/#{unique_id}/#{format}"
    else
      path = "/v3/table/import/#{e db}/#{e table}/#{format}"
    end
    opts = {}
    if @host == DEFAULT_ENDPOINT
      opts[:host] = DEFAULT_IMPORT_ENDPOINT
    elsif @host == NEW_DEFAULT_ENDPOINT
      opts[:host] = NEW_DEFAULT_IMPORT_ENDPOINT
    end
    code, body, res = put(path, stream, size, opts)
    if code[0] != ?2
      raise_error("Import failed", res)
    end
    js = checked_json(body, %w[])
    time = js['time'].to_f
    return time
  end


  ####
  ## Result API
  ##

  def list_result
    code, body, res = get("/v3/result/list")
    if code != "200"
      raise_error("List result table failed", res)
    end
    js = checked_json(body, %w[results])
    result = []
    js['results'].map {|m|
      result << [m['name'], m['url'], nil] # same as database
    }
    return result
  end

  # => true
  def create_result(name, url, opts={})
    params = {'url'=>url}.merge(opts)
    code, body, res = post("/v3/result/create/#{e name}", params)
    if code != "200"
      raise_error("Create result table failed", res)
    end
    return true
  end

  # => true
  def delete_result(name)
    code, body, res = post("/v3/result/delete/#{e name}")
    if code != "200"
      raise_error("Delete result table failed", res)
    end
    return true
  end


  ####
  ## User API
  ##

  # apikey:String
  def authenticate(user, password)
    code, body, res = post("/v3/user/authenticate", {'user'=>user, 'password'=>password})
    if code != "200"
      if code == "400"
        raise_error("Authentication failed", res, AuthError)
      else
        raise_error("Authentication failed", res)
      end
    end
    js = checked_json(body, %w[apikey])
    apikey = js['apikey']
    return apikey
  end

  # => [[name:String,organization:String,[user:String]]
  def list_users
    code, body, res = get("/v3/user/list")
    if code != "200"
      raise_error("List users failed", res)
    end
    js = checked_json(body, %w[users])
    result = js["users"].map {|roleinfo|
      name = roleinfo['name']
      email = roleinfo['email']
      [name, nil, nil, email] # set nil to org and role for API compatibiilty
    }
    return result
  end

  # => true
  def add_user(name, org, email, password)
    params = {'organization'=>org, :email=>email, :password=>password}
    code, body, res = post("/v3/user/add/#{e name}", params)
    if code != "200"
      raise_error("Adding user failed", res)
    end
    return true
  end

  # => true
  def remove_user(user)
    code, body, res = post("/v3/user/remove/#{e user}")
    if code != "200"
      raise_error("Removing user failed", res)
    end
    return true
  end

  # => true
  def change_email(user, email)
    params = {'email' => email}
    code, body, res = post("/v3/user/email/change/#{e user}", params)
    if code != "200"
      raise_error("Changing email failed", res)
    end
    return true
  end

  # => [apikey:String]
  def list_apikeys(user)
    code, body, res = get("/v3/user/apikey/list/#{e user}")
    if code != "200"
      raise_error("List API keys failed", res)
    end
    js = checked_json(body, %w[apikeys])
    return js['apikeys']
  end

  # => true
  def add_apikey(user)
    code, body, res = post("/v3/user/apikey/add/#{e user}")
    if code != "200"
      raise_error("Adding API key failed", res)
    end
    return true
  end

  # => true
  def remove_apikey(user, apikey)
    params = {'apikey' => apikey}
    code, body, res = post("/v3/user/apikey/remove/#{e user}", params)
    if code != "200"
      raise_error("Removing API key failed", res)
    end
    return true
  end

  # => true
  def change_password(user, password)
    params = {'password' => password}
    code, body, res = post("/v3/user/password/change/#{e user}", params)
    if code != "200"
      raise_error("Changing password failed", res)
    end
    return true
  end

  # => true
  def change_my_password(old_password, password)
    params = {'old_password' => old_password, 'password' => password}
    code, body, res = post("/v3/user/password/change", params)
    if code != "200"
      raise_error("Changing password failed", res)
    end
    return true
  end


  ####
  ## Access Control API
  ##

  def grant_access_control(subject, action, scope, grant_option)
    params = {'subject'=>subject, 'action'=>action, 'scope'=>scope, 'grant_option'=>grant_option.to_s}
    code, body, res = post("/v3/acl/grant", params)
    if code != "200"
      raise_error("Granting access control failed", res)
    end
    return true
  end

  def revoke_access_control(subject, action, scope)
    params = {'subject'=>subject, 'action'=>action, 'scope'=>scope}
    code, body, res = post("/v3/acl/revoke", params)
    if code != "200"
      raise_error("Revoking access control failed", res)
    end
    return true
  end

  # [true, [{subject:String,action:String,scope:String}]]
  def test_access_control(user, action, scope)
    params = {'user'=>user, 'action'=>action, 'scope'=>scope}
    code, body, res = get("/v3/acl/test", params)
    if code != "200"
      raise_error("Testing access control failed", res)
    end
    js = checked_json(body, %w[permission access_controls])
    perm = js["permission"]
    acl = js["access_controls"].map {|roleinfo|
      subject = roleinfo['subject']
      action = roleinfo['action']
      scope = roleinfo['scope']
      [name, action, scope]
    }
    return perm, acl
  end

  # [{subject:String,action:String,scope:String}]
  def list_access_controls
    code, body, res = get("/v3/acl/list")
    if code != "200"
      raise_error("Listing access control failed", res)
    end
    js = checked_json(body, %w[access_controls])
    acl = js["access_controls"].map {|roleinfo|
      subject = roleinfo['subject']
      action = roleinfo['action']
      scope = roleinfo['scope']
      grant_option = roleinfo['grant_option']
      [subject, action, scope, grant_option]
    }
    return acl
  end

  ####
  ## Server Status API
  ##

  # => status:String
  def server_status
    code, body, res = get('/v3/system/server_status')
    if code != "200"
      return "Server is down (#{code})"
    end
    js = checked_json(body, %w[status])
    status = js['status']
    return status
  end


  private
  module DeflateReadBodyMixin
    attr_accessor :gzip

    def each_fragment(&block)
      if @gzip
        infl = Zlib::Inflate.new(Zlib::MAX_WBITS+16)
      else
        infl = Zlib::Inflate.new
      end
      begin
        read_body do |fragment|
          block.call infl.inflate(fragment)
        end
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
    http, header = new_http

    path = @base_path + url
    if params && !params.empty?
      path << "?"+params.map {|k,v|
        "#{k}=#{e v}"
      }.join('&')
    end

    header['Accept-Encoding'] = 'deflate, gzip'
    request = Net::HTTP::Get.new(path, header)

    if block
      response = http.request(request) do |res|
        if ce = res.header['Content-Encoding']
          require 'zlib'
          res.extend(DeflateReadBodyMixin)
          res.gzip = true if ce == 'gzip'
        else
          res.extend(DirectReadBodyMixin)
        end
        block.call(res)
      end
    else
      response = http.request(request)
    end

    body = response.body
    unless block
      if ce = response.header['content-encoding']
        require 'zlib'
        if ce == 'gzip'
          infl = Zlib::Inflate.new(Zlib::MAX_WBITS+16)
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
    http, header = new_http

    path = @base_path + url

    if params && !params.empty?
      request = Net::HTTP::Post.new(path, header)
      request.set_form_data(params)
    else
      header['Content-Length'] = 0.to_s
      request = Net::HTTP::Post.new(path, header)
    end

    response = http.request(request)
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
    response = client.put(target, body, header)
    return [response.code.to_s, response.body, response]
  end

  def build_endpoint(url, host)
    schema = @ssl ? 'https' : 'http'
    "#{schema}://#{host}:#{@port}/#{@base_path + url}"
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

  def raise_error(msg, res, klass=nil)
    begin
      status_code = res.code.to_s
      js = JSON.load(res.body)
      msg = js['message']
      error_code = js['error_code']

      if klass
        raise klass, "#{error_code}: #{msg}"
      elsif status_code == "404"
        raise NotFoundError, "#{error_code}: #{msg}"
      elsif status_code == "409"
        raise AlreadyExistsError, "#{error_code}: #{msg}"
      else
        raise APIError, "#{error_code}: #{msg}"
      end

    rescue
      if klass
        raise klass, "#{error_code}: #{msg}"
      elsif status_code == "404"
        raise NotFoundError, "#{msg}: #{res.body}"
      elsif status_code == "409"
        raise AlreadyExistsError, "#{msg}: #{res.body}"
      else
        raise APIError, "#{msg}: #{res.body}"
      end
    end
    # TODO error
  end

  def e(s)
    require 'cgi'
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


end

