# frozen_string_literal: true

require_relative '../middleware/client_ip'

module RateLimiter
  module Identifiers
    # Identifies a request by the client's IP address: "ip:<address>".
    # ClientIp decides which address that is (REMOTE_ADDR, or X-Forwarded-For
    # only behind trusted proxies).
    class Ip
      def initialize(client_ip: Middleware::ClientIp.new)
        @client_ip = client_ip
      end

      def call(env)
        address = @client_ip.call(env).to_s
        address.empty? ? nil : "ip:#{address}"
      end
    end
  end
end
