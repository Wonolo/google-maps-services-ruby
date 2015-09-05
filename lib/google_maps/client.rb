require 'uri'
require 'hurley'
require 'multi_json'

module GoogleMaps
  class Client
    USER_AGENT = "GoogleGeoApiClientRuby/#{GoogleMaps::VERSION}"
    DEFAULT_BASE_URL = "https://maps.googleapis.com"
    RETRIABLE_STATUSES = [500, 503, 504]

    include GoogleMaps::Geocoding

    attr_reader :key, :client_id, :client_secret

    def initialize(options={})
      @key = options[:key] || GoogleMaps.key
      @client_id = options[:client_id] || GoogleMaps.client_id
      @client_secret = options[:key] || GoogleMaps.client_secret
    end

    # Get the current HTTP client
    # @return [Hurley::Client]
    def client
      @client ||= new_client
    end

    protected

    # Create a new HTTP client
    # @return [Hurley::Client]
    def new_client
      client = Hurley::Client.new
      client.request_options.query_class = Hurley::Query::Flat
      client.header[:user_agent] = USER_AGENT
      client
    end

    def get(path, params, base_url=DEFAULT_BASE_URL, accepts_client_id=true, extract_body=nil)
      url = base_url + generate_auth_url(path, params, accepts_client_id)
      response = client.get url

      if (extract_body)
        return extract_body(response)
      end
      return default_extract_body(response)
    end

    def default_extract_body(response)
      case response.status_code
      when 200..300
        # Do-nothing
      when 301, 302, 303, 307
        message ||= sprintf('Redirect to %s', response.header[:location])
        raise GoogleMaps::RedirectError.new(response), message
      when 401
        message ||= 'Unauthorized'
        raise GoogleMaps::AuthorizationError.new(response)
      when 304, 400, 402...500
        message ||= 'Invalid request'
        raise GoogleMaps::ClientError.new(response)
      when 500..600
        message ||= 'Server error'
        raise GoogleMaps::ServerError.new(response)
      else
        message ||= 'Unknown error'
        raise GoogleMaps::TransmissionError.new(response)
      end

      body = MultiJson.load(response.body, :symbolize_keys => true)

      api_status = body[:status]
      if api_status == "OK" or api_status == "ZERO_RESULTS"
        return body
      end

      if api_status == "OVER_QUERY_LIMIT"
        raise GoogleMaps::RateLimitError.new(response), body[:error_message]
      end

      if api_status == "REQUEST_DENIED"
        message ||= 'Unauthorized'
        raise GoogleMaps::AuthorizationError.new(response), body[:error_message]
      end

      if body[:error_message]
        raise GoogleMaps::ApiError.new(response), body[:error_message]
      else
        raise GoogleMaps::ApiError.new(response)
      end
    end

    # Returns the path and query string portion of the request URL,
    # first adding any necessary parameters.
    #
    # @param [String] path The path portion of the URL.
    # @param [Hash] params URL parameters.
    #
    # @return [String]
    def generate_auth_url(path, params, accepts_client_id)
      # Deterministic ordering through sorting by key.
      # Useful for tests, and in the future, any caching.
      if params.kind_of?(Hash)
        params = params.sort
      else
        params = params.dup
      end

      if accepts_client_id and @client_id and @client_secret
        params << ["client", @client_id]

        path = [path, self.class.urlencode_params(params)].join("?")
        sig = sign_hmac(@client_secret, path)
        return path + "&signature=" + sig
      end

      if @key
        params << ["key", @key]
        return path + "?" + self.class.urlencode_params(params)
      end

      raise ArgumentError, "Must provide API key for this API. It does not accept enterprise credentials."
    end

    # Returns a base64-encoded HMAC-SHA1 signature of a given string.
    #
    # @param [String] secret The key used for the signature, base64 encoded.
    # @param [String] payload The payload to sign.
    #
    # @return [String]
    def self.sign_hmac(secret, payload)
      require 'base64'
      require 'hmac'
      require 'hmac-sha1'

      secret = secret.encode('ASCII')
      payload = payload.encode('ASCII')

      # Decode the private key
      raw_key = Base64.urlsafe_decode64(secret)

      # Create a signature using the private key and the URL
      sha1 = HMAC::SHA1.new(raw_key)
      sha1 << payload
      raw_signature = sha1.digest()

      # Encode the signature into base64 for url use form.
      signature =  Base64.urlsafe_encode64(raw_signature)
      return signature
    end

    # URL encodes the parameters.
    # @param [Hash, Array<Array>] params The parameters
    # @return [String]
    def self.urlencode_params(params)
      unquote_unreserved(URI.encode_www_form(params))
    end

    # The unreserved URI characters (RFC 3986)
    UNRESERVED_SET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"

    # Un-escape any percent-escape sequences in a URI that are unreserved
    # characters. This leaves all reserved, illegal and non-ASCII bytes encoded.
    #
    # @param [String] uri
    #
    # @return [String]
    def self.unquote_unreserved(uri)
      parts = uri.split('%')

      (1..parts.length-1).each do |i|
        h = parts[i][0..1]

        if h.length == 2 and !h.match(/[^A-Za-z0-9]/)
          c = h.to_i(16).chr

          if UNRESERVED_SET.include?(c)
            parts[i] = c + parts[i][2..-1]
          else
            parts[i] = "%#{parts[i]}"
          end
        else
          parts[i] = "%#{parts[i]}"
        end
      end

      return parts.join
    end

  end
end