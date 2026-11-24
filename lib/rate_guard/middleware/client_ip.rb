# frozen_string_literal: true

require 'ipaddr'

module RateGuard
  class Middleware
    # Finds the real client IP.
    # Uses REMOTE_ADDR unless the request came from a trusted proxy;
    # then reads X-Forwarded-For right to left and takes the first
    # untrusted address. Clients can't fake it.
    class ClientIp
      def initialize(trusted_proxies: [])
        # Bad proxy addresses raise here, at boot.
        @trusted_proxies = trusted_proxies.map { |proxy| IPAddr.new(proxy) }.freeze
      end

      def call(env)
        remote_addr = env['REMOTE_ADDR'].to_s
        return remote_addr unless trusted?(remote_addr)

        chain = env['HTTP_X_FORWARDED_FOR'].to_s.split(',').map(&:strip).reject(&:empty?)
        return remote_addr if chain.empty?

        chain.reverse_each { |addr| return addr unless trusted?(addr) }

        # All hops were trusted proxies: use the furthest one.
        chain.first
      end

      private

      def trusted?(addr)
        ip = IPAddr.new(addr)
        @trusted_proxies.any? { |range| range.family == ip.family && range.include?(ip) }
      rescue IPAddr::Error
        false
      end
    end
  end
end
