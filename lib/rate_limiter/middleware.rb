# frozen_string_literal: true

require 'rack'
require_relative 'middleware/client_ip'
require_relative 'identifiers'

module RateLimiter
  # Rack middleware that rate limits requests to chosen paths. It identifies
  # the client, asks the limiter for a decision, reports that decision in
  # RateLimit-* headers, and answers 429 itself when the request is rejected.
  class Middleware
    CLIENT_KEY = 'rate_limiter.client_key'
    RESULT_KEY = 'rate_limiter.result'

    # Requests the identifier can't attribute to anyone share this one key, so
    # leaving out a header never means escaping the limit.
    UNIDENTIFIED_KEY = 'anonymous'

    # Float arithmetic on timestamps can leave a result a hair above a whole
    # number (10.000000000000002). Rounding up must not turn that into 11.
    ROUNDING_TOLERANCE = 1e-9

    # identifier - any #call(env) returning a namespaced key or nil
    #              (see RateLimiter::Identifiers); defaults to the client's IP.
    # client_ip  - kept for compatibility: shorthand for
    #              identifier: Identifiers::Ip.new(client_ip: client_ip).
    def initialize(app, limiter:, paths:, identifier: nil, client_ip: nil)
      ensure_immediate!(limiter)

      @app = app
      @limiter = limiter
      @paths = paths.map { |path| normalize(path) }.freeze
      @identifier = build_identifier(identifier, client_ip)
    end

    def call(env)
      return @app.call(env) unless limited?(env)

      key = identify(env)
      env[CLIENT_KEY] = key

      result = @limiter.acquire(key)
      env[RESULT_KEY] = result
      return too_many_requests(result) unless result.allowed?

      status, headers, body = @app.call(env)
      [status, headers.merge(rate_limit_headers(result)), body]
    end

    private

    # A queue algorithm answers "you're in line", not "allowed" or "rejected",
    # so it cannot decide a request that is waiting for its response.
    def ensure_immediate!(limiter)
      return if limiter.respond_to?(:acquire) && limiter.respond_to?(:limit)

      raise ArgumentError,
            "limiter must respond to #acquire and #limit (got #{limiter.class}): " \
            'queue algorithms delay work instead of answering allow-or-reject immediately, ' \
            'so build the limiter with RateLimiter.limiter'
    end

    def build_identifier(identifier, client_ip)
      raise ArgumentError, 'pass identifier: or client_ip:, not both' if identifier && client_ip

      identifier ||= Identifiers::Ip.new(client_ip: client_ip || ClientIp.new)
      return identifier if identifier.respond_to?(:call)

      raise ArgumentError, "identifier must respond to #call (got #{identifier.class})"
    end

    def identify(env)
      key = @identifier.call(env)
      key.nil? || key.empty? ? UNIDENTIFIED_KEY : key
    end

    def limited?(env)
      @paths.include?(normalize(env['PATH_INFO'].to_s))
    end

    # The one 429 every algorithm produces.
    def too_many_requests(result)
      headers = {
        'content-type' => 'text/plain',
        'retry-after' => whole_seconds(result.retry_after)
      }

      [429, headers.merge!(rate_limit_headers(result)), ["Too Many Requests\n"]]
    end

    # A new Hash for every response, so no two responses ever share one.
    # ratelimit-reset is left out when the limiter doesn't report it.
    def rate_limit_headers(result)
      headers = {
        'ratelimit-limit' => @limiter.limit.to_s,
        'ratelimit-remaining' => result.remaining.to_s
      }
      headers['ratelimit-reset'] = whole_seconds(result.reset_after) unless result.reset_after.nil?
      headers
    end

    # Headers carry whole seconds. Round up, so a client that waits the
    # advertised time is never early, but ignore float noise below a nanosecond.
    def whole_seconds(seconds)
      (seconds - ROUNDING_TOLERANCE).ceil.to_s
    end

    def normalize(path)
      decoded = Rack::Utils.unescape_path(path.b).tr('\\', '/')

      segments = decoded.split('/').each_with_object([]) do |segment, kept|
        next if segment.empty? || segment == '.'

        segment == '..' ? kept.pop : kept << segment
      end

      "/#{segments.join('/')}"
    end
  end
end
