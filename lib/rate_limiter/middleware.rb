# frozen_string_literal: true

require 'rack'
require_relative 'middleware/client_ip'

module RateLimiter
  # Rack middleware that decides which requests are rate limited and who sent them.
  class Middleware
    CLIENT_KEY = 'rate_limiter.client_key'

    def initialize(app, limiter:, paths:, client_ip: ClientIp.new)
      @app = app
      @limiter = limiter
      @paths = paths.map { |path| normalize(path) }.freeze
      @client_ip = client_ip
    end

    def call(env)
      return @app.call(env) unless limited?(env)

      key = "ip:#{@client_ip.call(env)}"
      env[CLIENT_KEY] = key

      result = @limiter.acquire(key)
      return too_many_requests(result) unless result.allowed?

      @app.call(env)
    end

    private

    def limited?(env)
      @paths.include?(normalize(env['PATH_INFO'].to_s))
    end

    def too_many_requests(result)
      headers = {
        'content-type' => 'text/plain',
        'retry-after' => result.retry_after.ceil.to_s
      }

      [429, headers, ["Too Many Requests\n"]]
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
