module OpenStack

class Connection

    attr_reader   :authuser
    attr_reader   :authtenant
    attr_reader   :authkey
    attr_reader   :auth_method
    attr_accessor :authtoken
    attr_accessor :authok
    attr_accessor :service_host
    attr_accessor :service_path
    attr_accessor :service_port
    attr_accessor :service_scheme
    attr_reader   :auth_host
    attr_reader   :auth_port
    attr_reader   :auth_scheme
    attr_reader   :auth_path
    attr_reader   :service_name
    attr_reader   :service_type
    attr_reader   :proxy_host
    attr_reader   :proxy_port
    attr_reader   :region

    attr_reader   :http
    attr_reader   :is_debug

    # Creates and returns a new Connection object, depending on the service_type
    # passed in the options:
    #
    # e.g:
    # os = OpenStack::Connection.create({:username => "herp@derp.com", :api_key=>"password",
    #               :auth_url => "https://region-a.geo-1.identity.cloudsvc.com:35357/v2.0/",
    #               :authtenant=>"herp@derp.com-default-tenant", :service_type=>"object-store")
    #
    # Will return an OpenStack::Swift::Connection object.
    #
    #   options hash:
    #
    #   :username - Your OpenStack username *required*
    #   :tenant - Your OpenStack tenant *required*. Defaults to username.
    #   :api_key - Your OpenStack API key *required*
    #   :auth_url - Configurable auth_url endpoint.
    #   :service_name - (Optional for v2.0 auth only). The optional name of the compute service to use.
    #   :service_type - (Optional for v2.0 auth only). Defaults to "compute"
    #   :region - (Optional for v2.0 auth only). The specific service region to use. Defaults to first returned region.
    #   :retry_auth - Whether to retry if your auth token expires (defaults to true)
    #   :proxy_host - If you need to connect through a proxy, supply the hostname here
    #   :proxy_port - If you need to connect through a proxy, supply the port here
    #
    # The options hash is used to create a new OpenStack::Connection object
    # (private constructor) and this is passed to the constructor of OpenStack::Compute::Connection
    # or OpenStack::Swift::Connection (depending on :service_type) where authentication is done using
    # OpenStack::Authentication.
    #
    def self.create(options = {:retry_auth => true})
      #call private constructor and grab instance vars
      connection = new(options)
      case connection.service_type
        when "compute"
          OpenStack::Compute::Connection.new(connection)
        when "object-store"
          OpenStack::Swift::Connection.new(connection)
        else
          raise Exception::InvalidArgument, "Invalid :service_type parameter: #{@service_type}"
      end
    end

    private_class_method :new

    def initialize(options = {:retry_auth => true})
      @authuser = options[:username] || (raise Exception::MissingArgument, "Must supply a :username")
      @authkey = options[:api_key] || (raise Exception::MissingArgument, "Must supply an :api_key")
      @auth_url = options[:auth_url] || (raise Exception::MissingArgument, "Must supply an :auth_url")
      @authtenant = options[:authtenant] || @authuser
      @auth_method = options[:auth_method] || "password"
      @service_name = options[:service_name] || nil
      @service_type = options[:service_type] || "compute"
      @region = options[:region] || @region = nil
      @is_debug = options[:is_debug]
      auth_uri=nil
      begin
        auth_uri=URI.parse(@auth_url)
      rescue Exception => e
        raise Exception::InvalidArgument, "Invalid :auth_url parameter: #{e.message}"
      end
      raise Exception::InvalidArgument, "Invalid :auth_url parameter." if auth_uri.nil? or auth_uri.host.nil?
      @auth_host = auth_uri.host
      @auth_port = auth_uri.port
      @auth_scheme = auth_uri.scheme
      @auth_path = auth_uri.path
      @retry_auth = options[:retry_auth]
      @proxy_host = options[:proxy_host]
      @proxy_port = options[:proxy_port]
      @authok = false
      @http = {}
    end

    #specialised from of csreq for PUT object... uses body_stream if possible
    def put_object(server,path,port,scheme,headers = {},data = nil,attempts = 0) # :nodoc:
      start = Time.now
      if data.respond_to? :read
        headers['Transfer-Encoding'] = 'chunked'
        hdrhash = headerprep(headers)
        request = Net::HTTP::Put.new(path,hdrhash)
        chunked = OpenStack::Swift::ChunkedConnectionWrapper.new(data, 65535)
        request.body_stream = chunked
      else
        headers['Content-Length'] = (body.respond_to?(:lstat))? body.lstat.size.to_s : ((body.respond_to?(:size))? body.size.to_s : "0")
        hdrhash = headerprep(headers)
        request = Net::HTTP::Put.new(path,hdrhash)
        request.body = data
      end
      start_http(server,path,port,scheme,hdrhash)
      response = @http[server].request(request)
      if @is_debug
          puts "REQUEST: #{method} => #{path}"
          puts data if data
          puts "RESPONSE: #{response.body}"
          puts '----------------------------------------'
      end
      raise OpenStack::Exception::ExpiredAuthToken if response.code == "401"
      response
    rescue Errno::EPIPE, Timeout::Error, Errno::EINVAL, EOFError
      # Server closed the connection, retry
      raise OpenStack::Exception::Connection, "Unable to reconnect to #{server} after #{attempts} attempts" if attempts >= 5
      attempts += 1
      @http[server].finish if @http[server].started?
      start_http(server,path,port,scheme,headers)
      retry
    rescue OpenStack::Exception::ExpiredAuthToken
      raise OpenStack::Exception::Connection, "Authentication token expired and you have requested not to retry" if @retry_auth == false
      OpenStack::Authentication.init(self)
      retry
    end


    # This method actually makes the HTTP REST calls out to the server
    def csreq(method,server,path,port,scheme,headers = {},data = nil,attempts = 0, &block) # :nodoc:
      start = Time.now
      hdrhash = headerprep(headers)
      start_http(server,path,port,scheme,hdrhash)
      request = Net::HTTP.const_get(method.to_s.capitalize).new(path,hdrhash)
      request.body = data
      if block_given?
        response =  @http[server].request(request) do |res|
          res.read_body do |b|
            yield b
          end
        end
      else
        response = @http[server].request(request)
      end
      if @is_debug
          puts "REQUEST: #{method} => #{path}"
          puts data if data
          puts "RESPONSE: #{response.body}"
          puts '----------------------------------------'
      end
      raise OpenStack::Exception::ExpiredAuthToken if response.code == "401"
      response
    rescue Errno::EPIPE, Timeout::Error, Errno::EINVAL, EOFError
      # Server closed the connection, retry
      raise OpenStack::Exception::Connection, "Unable to reconnect to #{server} after #{attempts} attempts" if attempts >= 5
      attempts += 1
      @http[server].finish if @http[server].started?
      start_http(server,path,port,scheme,headers)
      retry
    rescue OpenStack::Exception::ExpiredAuthToken
      raise OpenStack::Exception::Connection, "Authentication token expired and you have requested not to retry" if @retry_auth == false
      OpenStack::Authentication.init(self)
      retry
    end

    # This is a much more sane way to make a http request to the api.
    # Example: res = conn.req('GET', "/servers/#{id}")
    def req(method, path, options = {})
      server   = options[:server]   || @service_host
      port     = options[:port]     || @service_port
      scheme   = options[:scheme]   || @service_scheme
      headers  = options[:headers]  || {'content-type' => 'application/json'}
      data     = options[:data]
      attempts = options[:attempts] || 0
      path = @service_path + path
      res = csreq(method,server,path,port,scheme,headers,data,attempts)
      if not res.code.match(/^20.$/)
        OpenStack::Exception.raise_exception(res)
      end
      return res
    end;

    private

    # Sets up standard HTTP headers
    def headerprep(headers = {}) # :nodoc:
      default_headers = {}
      default_headers["X-Auth-Token"] = @authtoken if authok
      default_headers["X-Storage-Token"] = @authtoken if authok
      default_headers["Connection"] = "Keep-Alive"
      default_headers["User-Agent"] = "OpenStack Ruby API #{VERSION}"
      default_headers["Accept"] = "application/json"
      default_headers.merge(headers)
    end

    # Starts (or restarts) the HTTP connection
    def start_http(server,path,port,scheme,headers) # :nodoc:
      if (@http[server].nil?)
        begin
          @http[server] = Net::HTTP::Proxy(@proxy_host, @proxy_port).new(server,port)
          if scheme == "https"
            @http[server].use_ssl = true
            @http[server].verify_mode = OpenSSL::SSL::VERIFY_NONE
          end
          @http[server].start
        rescue
          raise OpenStack::Exception::Connection, "Unable to connect to #{server}"
        end
      end
    end

end #end class Connection

#============================
# OpenStack::Authentication
#============================

class Authentication

  # Performs an authentication to the OpenStack auth server.
  # If it succeeds, it sets the service_host, service_path, service_port,
  # service_scheme, authtoken, and authok variables on the connection.
  # If it fails, it raises an exception.

  def self.init(conn)
    if conn.auth_path =~ /.*v2.0\/?$/
      AuthV20.new(conn)
    else
      AuthV10.new(conn)
    end
  end

end

 private

class AuthV20
  attr_reader :uri

  def initialize(connection)
    begin
      server = Net::HTTP::Proxy(connection.proxy_host, connection.proxy_port).new(connection.auth_host, connection.auth_port)
      if connection.auth_scheme == "https"
        server.use_ssl = true
        server.verify_mode = OpenSSL::SSL::VERIFY_NONE
      end
      server.start
    rescue
      raise OpenStack::Exception::Connection, "Unable to connect to #{server}"
    end

    @uri = String.new

    if connection.auth_method == "password"
      auth_data = JSON.generate({ "auth" =>  { "passwordCredentials" => { "username" => connection.authuser, "password" => connection.authkey }, "tenantName" => connection.authtenant}})
    elsif connection.auth_method == "rax-kskey"
      auth_data = JSON.generate({"auth" => {"RAX-KSKEY:apiKeyCredentials" => {"username" => connection.authuser, "apiKey" => connection.authkey}}})
    else
      raise Exception::InvalidArgument, "Unrecognized auth method #{connection.auth_method}"
    end

    response = server.post(connection.auth_path.chomp("/")+"/tokens", auth_data, {'Content-Type' => 'application/json'})
    if (response.code =~ /^20./)
      resp_data=JSON.parse(response.body)
      connection.authtoken = resp_data['access']['token']['id']
      resp_data['access']['serviceCatalog'].each do |service|
        if service['type'] == connection.service_type
          endpoints = service["endpoints"]
          if connection.region
            endpoints.each do |ep|
              if ep["region"] and ep["region"].upcase == connection.region.upcase
                @uri = URI.parse(ep["publicURL"])
              end
            end
          else
            @uri = URI.parse(endpoints[0]["publicURL"])
          end
          if @uri == ""
            raise OpenStack::Exception::Authentication, "No API endpoint for region #{connection.region}"
          else
            connection.service_host = @uri.host
            connection.service_path = @uri.path
            connection.service_port = @uri.port
            connection.service_scheme = @uri.scheme
            connection.authok = true
          end
        end
      end
    else
      connection.authtoken = false
      raise OpenStack::Exception::Authentication, "Authentication failed with response code #{response.code}"
    end
    server.finish
  end
end

class AuthV10

  def initialize(connection)
    hdrhash = { "X-Auth-User" => connection.authuser, "X-Auth-Key" => connection.authkey }
    begin
      server = Net::HTTP::Proxy(connection.proxy_host, connection.proxy_port).new(connection.auth_host, connection.auth_port)
      if connection.auth_scheme == "https"
        server.use_ssl = true
        server.verify_mode = OpenSSL::SSL::VERIFY_NONE
      end
      server.start
    rescue
      raise OpenStack::Exception::Connection, "Unable to connect to #{server}"
    end
    response = server.get(connection.auth_path, hdrhash)
    if (response.code =~ /^20./)
      connection.authtoken = response["x-auth-token"]
      case connection.service_type
        when "compute"
          uri = URI.parse(response["x-server-management-url"])
        when "object-store"
          uri = URI.parse(response["x-storage-url"])
      end
      raise OpenStack::Exception::Authentication, "Unexpected Response from  #{connection.auth_host} - couldn't get service URLs: \"x-server-management-url\" is: #{response["x-server-management-url"]} and \"x-storage-url\" is: #{response["x-storage-url"]}"  if (uri.host.nil? || uri.host=="")
      connection.service_host = uri.host
      connection.service_path = uri.path
      connection.service_port = uri.port
      connection.service_scheme = uri.scheme
      connection.authok = true
    else
      connection.authok = false
      raise OpenStack::Exception::Authentication, "Authentication failed with response code #{response.code}"
    end
    server.finish
  end

end


#============================
# OpenStack::Exception
#============================

class Exception

  class ComputeError < StandardError

    attr_reader :response_body
    attr_reader :response_code

    def initialize(message, code, response_body)
      @response_code=code
      @response_body=response_body
      super(message)
    end

  end

  class ComputeFault                < ComputeError # :nodoc:
  end
  class ServiceUnavailable          < ComputeError # :nodoc:
  end
  class Unauthorized                < ComputeError # :nodoc:
  end
  class BadRequest                  < ComputeError # :nodoc:
  end
  class OverLimit                   < ComputeError # :nodoc:
  end
  class BadMediaType                < ComputeError # :nodoc:
  end
  class BadMethod                   < ComputeError # :nodoc:
  end
  class ItemNotFound                < ComputeError # :nodoc:
  end
  class BuildInProgress             < ComputeError # :nodoc:
  end
  class ServerCapacityUnavailable   < ComputeError # :nodoc:
  end
  class BackupOrResizeInProgress    < ComputeError # :nodoc:
  end
  class ResizeNotAllowed            < ComputeError # :nodoc:
  end
  class NotImplemented              < ComputeError # :nodoc:
  end
  class Other                       < ComputeError # :nodoc:
  end
  class ResourceStateConflict       < ComputeError # :nodoc:
  end

  # Plus some others that we define here

  class ExpiredAuthToken            < StandardError # :nodoc:
  end
  class MissingArgument             < StandardError # :nodoc:
  end
  class InvalidArgument             < StandardError # :nodoc:
  end
  class TooManyPersonalityItems     < StandardError # :nodoc:
  end
  class PersonalityFilePathTooLong  < StandardError # :nodoc:
  end
  class PersonalityFileTooLarge     < StandardError # :nodoc:
  end
  class Authentication              < StandardError # :nodoc:
  end
  class Connection                  < StandardError # :nodoc:
  end

  # In the event of a non-200 HTTP status code, this method takes the HTTP response, parses
  # the JSON from the body to get more information about the exception, then raises the
  # proper error.  Note that all exceptions are scoped in the OpenStack::Compute::Exception namespace.
  def self.raise_exception(response)
    return if response.code =~ /^20.$/
    begin
      fault = nil
      info = nil
      if response.body.nil? && response.code == "404" #HEAD ops no body returned
        exception_class = self.const_get("ItemNotFound")
        raise exception_class.new("The resource could not be found", "404", "")
      else
        JSON.parse(response.body).each_pair do |key, val|
          fault=key
          info=val
        end
        exception_class = self.const_get(fault[0,1].capitalize+fault[1,fault.length])
        raise exception_class.new(info["message"], response.code, response.body)
      end
    rescue JSON::ParserError => parse_error
        deal_with_faulty_error(response, parse_error)
    rescue NameError
      raise OpenStack::Exception::Other.new("The server returned status #{response.code}", response.code, response.body)
    end
  end

  private

  #e.g. os.delete("non-existant") ==> response.body is:
  # "404 Not Found\n\nThe resource could not be found.\n\n   "
  # which doesn't parse. Deal with such cases here if possible (JSON::ParserError)
  def self.deal_with_faulty_error(response, parse_error)
  case response.code
    when "404"
      klass = self.const_get("ItemNotFound")
      msg = "The resource could not be found"
    when "409"
      klass = self.const_get("ResourceStateConflict")
      msg = "There was a conflict with the state of the resource"
    else
      klass = self.const_get("Other")
      msg = "Oops - not sure what happened: #{parse_error}"
    end
    raise klass.new(msg, response.code.to_s, response.body)
  end
end

end

