# encoding: utf-8
require "logstash/inputs/base"
require "logstash/namespace"
require "stud/interval"
require "socket" # for Socket.gethostname
require "json"
require "date"
require "base64"

# Fetch Centrify Identity Platform request data.
#

class LogStash::Inputs::Centrifyidplatform < LogStash::Inputs::Base
  config_name "centrifyidplatform"

  # If undefined, Logstash will complain, even if codec is unused.
  default :codec, "json"

  #query = 'Select * from Event where WhenOccurred >= start_time_string  and WhenOccurred < end_time_string ORDER BY WhenOccurred ASC'

  # Configurable variables
  # Centrify PAS OAuth2 account username.
  config :username, :validate => :string, :default => ""
  # Centrify OAuth2 password.
  config :password, :validate => :string, :default => ""
  # Centrify Tenant.
  config :tenant, :validate => :string, :default => "not_provided"
  # Centrify OAuth2 client path
  config :oauthclient, :validate => :string, :default => "not_provided"
  config :debug, :validate => :boolean, :default => false
  # Scope defined within Oauthclient
  config :scope, :validate => :string, :default => "siem"
  # Previous timeframe to query from in hours integer
  config :historyhrs, :validate => :number, :default => 24
  # Search previoushrs true or false
  config :historysearch, :validate => :boolean, :default => false

  public
  def register
    @host = Socket.gethostname.force_encoding(Encoding::UTF_8)
    
    @logger.info("Registering Centrify Identify Platform Input", :tenant => @tenant, :username => @username, :password => @password, :oauthclient => @oauthclient, :scope => @scope,  :historyhrs => @historyhrs, :historysearch => @historysearch )
    @http = Net::HTTP.new(@tenant, 443)
    @http.use_ssl = true
    @http.set_debug_output($stdout) if @debug
    # set version for UA string
    @version = "1.0.0"
    @token_endpoint = "/oauth2/token/#{@oauthclient}/"
    @query_endpoint = "/Redrock/query"
    # set interval to value of from @from minus five minutes
    @interval = 300
    if historysearch
      @from = @historyhrs * 3600
    else
      @from = 300
    end
    t = Time.now.utc.strftime("%Y-%m-%dT%H:%M:%S.%zZ")
    dt = DateTime.parse(t)
    ts_until = Time.at(dt.to_time.to_i - 300) # now - 5 minutes
    ts_from = Time.at(ts_until - @from) # @until - @from
    @timestamp_until = ts_until.strftime("%Y-%m-%d %H:%M:%S%z")
    @timestamp_from = ts_from.strftime("%Y-%m-%d %H:%M:%S%z")
    @eventquery = "select * from Event where WhenOccurred between datefunc('#{@timestamp_from}') and datefunc('#{@timestamp_until}') ORDER BY WhenOccurred ASC"
  end

  public
  def run(queue)
    while !stop?
      if fetch(queue)
        @logger.debug("Centrify Identity Platform requests feed retreived successfully.")
      else
        @logger.warn("Centrify Identity Platform problem retreiving request!")
      end
      @logger.debug("Centrify Identity Platform Sleep: #{@interval}")
      @timestamp_from = @timestamp_until
      Stud.stoppable_sleep(@interval) { stop? }
      t = Time.now.utc.strftime("%Y-%m-%dT%H:%M:%S.%zZ")
      dt = DateTime.parse(t)
      ts_until = Time.at(dt.to_time.to_i - 300) # now - 5 minutes
      @timestamp_until = ts_until.strftime("%Y-%m-%d %H:%M:%S%z")
      @eventquery = "select * from Event where WhenOccurred between datefunc('#{@timestamp_from}') and datefunc('#{@timestamp_until}') ORDER BY WhenOccurred ASC"
      end #end loop
  end

  def fetch(queue)
    @logger.debug("Centrify Identity Platform tenant: #{@name}")
    @logger.debug("Centrify Identity Platform OAuth endpoint: #{@oauthclient}")
    bearer_token = setup_auth_requests!
    request = post_request(queue, bearer_token)
    response = @http.request(request)
    if response.code == "200"
      body = response.body
      if body && body.size > 0
        json = JSON.load(body)
        if json.has_key? "success"
          _success = json['success']
          @logger.debug("Centrify Identity Platform Query success: #{_success}")
          if _success == 'false'
            _message = json['message']
            _exception = json['exception']
            @logger.warn("Centrify Identity Platform exception: #{_exception} message: #{_message}")
            return
          end
          _events = json['Result']['Results']
          _events.each do |child|
            if child.is_a?(Hash)
              temp = {}
              _row = child['Row']
              temp = _row.delete_if { |k, v| v.nil? }
              _row = temp
              _whenlogged = date_fix!(_row['WhenLogged'])
              @logger.debug("Centrify Identity Platform Query whenlogged date fix: #{_whenlogged}")
              _row['WhenLogged'] = _whenlogged
              _whenoccurred = date_fix!(_row['WhenOccurred'])
              @logger.debug("Centrify Identity Platform Query whenlogged date fix: #{_whenoccurred}") 
              _row['WhenOccurred'] = _whenoccurred

              @logger.debug("Centrify Identity Platform Query JSON dump Row: #{_row}")
              process_payload!(_row, queue)
            end
          end
        end
      end
      #handle_success!(queue, event_results)
    else
      @logger.warn("Centrify Identity Platform post exception: #{response.code}")
      check_response_code!(response.code, "Post Exception")
    end
  end

  private
  def post_request(queue, bearer_token)
    post = Net::HTTP::Post.new("#{@query_endpoint}")
    post["Authorization"] = "Bearer #{bearer_token}"
    post.body = JSON.generate({:Script => @eventquery})
    post['User-Agent'] = "logstash-centrifyidplatform/#{@version}"
    @logger.debug("Requesting query data: #{JSON.generate({:Script => @eventquery})}")
    return post
  end

  private
  def handle_success!(queue, event_results)
    event_results['Row'].each do |payload|
      @logger.debug("event_result: #{payload}")
      process_payload!(payload, queue)
    end
  end

  private
  def setup_auth_requests!
    login = Net::HTTP::Post.new(@token_endpoint)
    login['User-Agent'] = "logstash-centrifyidplatform/#{@version}"
    login['Content-Type'] = "application/x-www-form-urlencoded"
    credentials = Base64.strict_encode64 ("#{@username}:#{@password}")
    @logger.debug("Centrify Identity Platform login credentials: Basic #{credentials}")
    login["Authorization"] = "Basic #{credentials}"
    login.body = "grant_type=client_credentials&scope=#{@scope}"

    begin
      loginresponse = @http.request(login)
      @logger.debug("Centrify Identity Platform login response: #{loginresponse.code}")
    rescue
      @logger.warn("Centrify Identity Platform could not reach API endpoint to login!")
      return false
    end
    if loginresponse.code != "200"
      return check_response_code!(loginresponse.code, "Auth")
    end
    json = JSON.parse(loginresponse.body)
    if json.has_key? "message"
      # failed to login
      @logger.warn("Centrify Identity Platform login failed: #{json['message']}")
      return false
    end
    bearer_token = json['access_token']
    @logger.debug("Centrify Identity Platform Bearer Token: #{bearer_token}")
    return bearer_token
  end

  private
  def check_response_code!(res_code, message)
    if res_code == "524"
      @logger.warn("524 - Origin Timeout!")
      @logger.info("Another attempt will be made later. #{message}")
      return false
    end
    if res_code == "429"
      @logger.warn("429 - Too Many Requests!")
      @logger.info("API request throttling as been triggered, another attempt will be made later. Contact support if this error continues. #{message}")
      return false
    end
    if res_code == "404"
      @logger.warn("404 - Not Found! #{message}")
      return false
    end
    if res_code == "401"
      @logger.warn("401 - Unauthorized! #{message}")
      return false
    end
    @logger.warn("Non-200 return enable debug to troubleshoot: #{res_code} #{message}")
    return false
  end

  private 
  def date_fix!(when_str)
    prefix = '/Date('
    suffix = ')/'
    when_str = when_str.delete_prefix(prefix)
    when_str = when_str.delete_suffix(suffix).to_f
    when_str = when_str / 1000.0
    when_str = Time.at(when_str).utc
    when_str = when_str.strftime("%Y-%m-%dT%H:%M:%S.%3NZ")
    return when_str
  end

  private
  def process_payload!(payload, queue)
    temp = {}
    payload['logstash_host.name'] = @host

    event = LogStash::Event.new('message' => payload.to_json, 'host' => @host, '@timestamp' => payload['WhenOccurred'])
    event.tag('centrifyidplatform')
    decorate(event)
    queue << event
  end
#
#  def stop
#    # nothing to do in this case so it is not necessary to define stop
#    # examples of common "stop" tasks:
#    #  * close sockets (unblocking blocking reads/accepts)
#    #  * cleanup temporary files
#    #  * terminate spawned threads
#  end
end # class LogStash::Inputs::Centrifyidplatform
