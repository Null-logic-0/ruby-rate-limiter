# frozen_string_literal: true

require_relative '../middleware/client_ip'

module RateGuard
  module Identifiers
    # Identifies a request by client IP: "ip:<address>" (see ClientIp).
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
