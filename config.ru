# frozen_string_literal: true

require_relative 'app/api'
require_relative 'lib/rate_limiter'
require_relative 'lib/rate_limiter/middleware'

trusted_proxies = ENV.fetch('TRUSTED_PROXIES', '').split(',').map(&:strip).reject(&:empty?)

use RateLimiter::Middleware,
    limiter: RateLimiter::Algorithms::TokenBucket.new(capacity: 3, refill_rate: 0.1),
    paths: ['/limited'],
    client_ip: RateLimiter::Middleware::ClientIp.new(trusted_proxies: trusted_proxies)

run Api
