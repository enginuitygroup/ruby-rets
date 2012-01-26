require "cgi"
require "net/http"
require "digest"

module RETS
  class HTTP
    ##
    # Creates a new HTTP instance which will automatically handle authenting to the RETS server.
    def initialize(args)
      @headers = {"User-Agent" => "Ruby RETS/v#{RETS::VERSION}"}
      @request_count = 1
      @config = args

      if @config[:useragent] and @config[:useragent][:name]
        @headers["User-Agent"] = @config[:useragent][:name]
      end

      if @config[:auth_mode] == :basic
        @auth_mode = @config.delete(:auth_mode)
      end
    end

    ##
    # Creates and manages the HTTP digest auth
    # if the WWW-Authorization header is passed, then it will overwrite what it knows about the auth data.
    def save_digest(header)
      @request_count = 0

      @digest = {}
      header.split(",").each do |line|
        k, v = line.strip.split("=", 2)
        @digest[k] = (k != "algorithm" and k != "stale") && v[1..-2] || v
      end

      @digest["qop"] ||= "auth"
      @digest_type = @digest["qop"].split(",")
    end

    ##
    # Creates a HTTP digest header.
    def create_digest(method, request_uri)
      first = Digest::MD5.hexdigest("#{@config[:username]}:#{@digest["realm"]}:#{@config[:password]}")
      second = Digest::MD5.hexdigest("#{method}:#{request_uri}")
      cnonce = Digest::MD5.hexdigest("#{@headers["User-Agent"]}:#{@config[:password]}:#{@request_count}:#{@digest["nonce"]}")

      if @digest_type.include?("auth")
        hash = Digest::MD5.hexdigest("#{first}:#{@digest["nonce"]}:#{"%08X" % @request_count}:#{cnonce}:#{@digest["qop"]}:#{second}")
      else
        raise RETS::ServerError, "Cannot determine auth type for server"
      end

      http_digest = "Digest username=\"#{@config[:username]}\", "
      http_digest << "realm=\"#{@digest["realm"]}\", "
      http_digest << "nonce=\"#{@digest["nonce"]}\", "
      http_digest << "uri=\"#{request_uri}\", "
      http_digest << "algorithm=MD5, "
      http_digest << "response=\"#{hash}\", "
      http_digest << "opaque=\"#{@digest["opaque"]}\", "
      http_digest << "qop=\"#{@digest["qop"]}\", "
      http_digest << "nc=#{"%08X" % @request_count}, "
      http_digest << "cnonce=\"#{cnonce}\""
    end

    ##
    # Creates a HTTP basic header.
    def create_basic
       "Basic " << ["#{@config[:username]}:#{@config[:password]}"].pack("m").delete("\r\n")
    end

    ##
    # Sends a request to the RETS server.
    #
    # @param [Hash] args
    # @option args [URI] :url URI to request data from
    # @option args [Hash, Optional] :params Query string to include with the request
    # @option args [Integer, Optional] :read_timeout How long to wait for the socket to return data before timing out
    #
    # @raise [RETS::ServerError]
    # @raise [RETS::HTTPError]
    # @raise [RETS::Unauthorized]
    def request(args, &block)
      request_uri = "#{args[:url].request_uri}"
      if args[:params]
        request_uri << "?"
        args[:params].each do |k, v|
          request_uri << "#{k}=#{CGI::escape(v.to_s)}&" if v
        end
      end

      headers = args[:headers]

      # Digest will change every time due to how its setup
      @request_count += 1
      if @auth_mode == :digest
        headers ||= {}
        headers.merge!(:Authorization => create_digest("GET", request_uri))
      end

      headers = headers ? @headers.merge(headers) : @headers

      http = ::Net::HTTP.new(args[:url].host, args[:url].port)
      http.read_timeout = args[:read_timeout] if args[:read_timeout]
      http.set_debug_output(@config[:debug_output]) if @config[:debug_output]

      http.start do
        http.request_get(request_uri, headers) do |response|
          # Digest can become stale requiring us to reload data
          if @auth_mode == :digest and response.header["www-authenticate"] =~ /stale=true/i
            save_digest(response.header["www-authenticate"].split(" ", 2)[1])
            args[:block] = block

          elsif response.code == "401"
            raise RETS::Unauthorized, "Cannot login, check credentials" if @auth_mode

            @auth_mode, header = response.header.get_fields("www-authenticate").last.split(" ", 2)
            @auth_mode = @auth_mode.downcase.to_sym

            if @auth_mode == :digest
              save_digest(header)
            elsif @auth_mode == :basic
              @headers.merge!(:Authorization => create_basic)
            end

            # Most RETS implementations don't care about RETS-Version for RETS-UA-Authorization.
            # Because Rapattoni's does, will set and use it when possible, but otherwise will fake one.
            # They also seem to require RETS-Version even when it's not required by RETS-UA-Authorization.
            # Others, such as Offut/Innovia pass the header, but without a version attached.
            if response.header["rets-version"] and response.header["rets-version"] != ""
              @headers["RETS-Version"] = response.header["rets-version"]
            else
              @headers["RETS-Version"] = "RETS/1.7"
            end

            if !@headers["RETS-UA-Authorization"] and @headers["RETS-Version"] and @config[:useragent] and @config[:useragent][:password]
              login = Digest::MD5.hexdigest("#{@config[:useragent][:name]}:#{@config[:useragent][:password]}")
              @headers.merge!("RETS-UA-Authorization" => "Digest #{Digest::MD5.hexdigest("#{login}:::#{@headers["RETS-Version"]}")}")
            end

            args[:block] = block

          elsif response.code != "200"
            if response.body =~ /<RETS/i
              rets = Nokogiri::XML(response.body).xpath("//RETS")
              code = rets.attr("ReplyCode").value
              text = rets.attr("ReplyText").value
              raise RETS::ServerError.new("#{code}: #{text}", code, text)
            else
              raise RETS::HTTPError.new("#{response.code}: #{response.message}", response.code, response.message)
            end

          # We just tried to auth and don't have access to the original block in yieldable form
          elsif args[:block]
            args.delete(:block).call(response)

          elsif block_given?
            yield response
          end

          # Save cookies for session ids and such
          if response.header["set-cookie"]
            cookies = response.header.get_fields("set-cookie").map do |cookie|
              cookie.split(";").first.strip
            end

            @headers.merge!(:Cookie => cookies.join("; "))
          end
        end
      end

      # Something failed, let's try that one more time
      self.request(args) if args[:block]
    end
  end
end