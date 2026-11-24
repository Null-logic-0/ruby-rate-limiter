# frozen_string_literal: true

require 'digest'
require 'ipaddr'
require_relative 'middleware/client_ip'

module RateLimiter
  # Trusted clients that are never rate limited: by IP range (your own
  # monitoring, internal services) or by API key (partners).
  #
  # The IP comes from ClientIp, so X-Forwarded-For only counts behind trusted
  # proxies and a client can't claim a trusted address. API keys are kept
  # only as SHA-256 digests and compared by digest.
  class Bypass
    def initialize(ip_ranges: [], api_keys: [], client_ip: Middleware::ClientIp.new, header: 'X-API-Key')
      @ranges = ip_ranges.map { |range| IPAddr.new(range) }.freeze
      @key_digests = api_keys.map { |key| Digest::SHA256.hexdigest(key) }.to_set.freeze
      @client_ip = client_ip
      @env_key = "HTTP_#{header.upcase.tr('-', '_')}"
    end

    def call(env)
      trusted_ip?(env) || trusted_key?(env)
    end

    private

    def trusted_ip?(env)
      return false if @ranges.empty?

      address = IPAddr.new(@client_ip.call(env).to_s)
      @ranges.any? { |range| range.family == address.family && range.include?(address) }
    rescue IPAddr::Error
      false
    end

    def trusted_key?(env)
      api_key = env[@env_key].to_s.strip
      !api_key.empty? && @key_digests.include?(Digest::SHA256.hexdigest(api_key))
    end
  end
end
