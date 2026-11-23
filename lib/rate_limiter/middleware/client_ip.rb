# frozen_string_literal: true

require 'ipaddr'

module RateLimiter
  class Middleware
    # Works out the real client address for a request.
    #
    # REMOTE_ADDR is the only value a client cannot forge, so it is used by
    # default. X-Forwarded-For is consulted only when the request arrived from
    # a trusted proxy, and then it is read right to left: each trusted proxy
    # appends the address it saw, so the first untrusted entry from the right
    # is the client. Anything further left was supplied by the client itself.
    class ClientIp
      def initialize(trusted_proxies: [])
        # IPAddr.new raises IPAddr::InvalidAddressError on bad config, so a
        # typo in TRUSTED_PROXIES fails at boot instead of silently.
        @trusted_proxies = trusted_proxies.map { |proxy| IPAddr.new(proxy) }.freeze
      end

      def call(env)
        remote_addr = env['REMOTE_ADDR'].to_s
        return remote_addr unless trusted?(remote_addr)

        chain = env['HTTP_X_FORWARDED_FOR'].to_s.split(',').map(&:strip).reject(&:empty?)
        return remote_addr if chain.empty?

        chain.reverse_each { |addr| return addr unless trusted?(addr) }

        # Every hop was a trusted proxy: the leftmost one is the furthest out.
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
