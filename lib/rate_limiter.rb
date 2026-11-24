# frozen_string_literal: true

require_relative 'rate_limiter/version'
require_relative 'rate_limiter/clock'
require_relative 'rate_limiter/result'
require_relative 'rate_limiter/algorithms/token_bucket'
require_relative 'rate_limiter/algorithms/leaky_bucket_meter'

module RateLimiter
  class Error < StandardError; end
end
