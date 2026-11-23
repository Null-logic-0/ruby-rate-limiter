# frozen_string_literal: true

require 'rack'
require_relative 'middleware/client_ip'

module RateLimiter
  # Rack middleware that decides which requests are rate limited and who sent them.
  class Middleware
    CLIENT_KEY = 'rate_limiter.client_key'

    def initialize(app, paths:, client_ip: ClientIp.new)
      @app = app
      @paths = paths.map { |path| normalize(path) }.freeze
      @client_ip = client_ip
    end

    def call(env)
      env[CLIENT_KEY] = "ip:#{@client_ip.call(env)}" if limited?(env)
      @app.call(env)
    end

    private

    def limited?(env)
      @paths.include?(normalize(env['PATH_INFO'].to_s))
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
