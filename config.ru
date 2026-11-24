# frozen_string_literal: true

require_relative 'app/api'
require_relative 'lib/rate_limiter'
require_relative 'lib/rate_limiter/middleware'

# Settings come from the environment. A value that isn't a number becomes nil,
# so RateLimiter.configure reports every bad setting together, at boot.
RateLimiter.configure do |config|
  config.algorithm = ENV.fetch('RATE_LIMIT_ALGORITHM', 'token_bucket')
  config.limit = Integer(ENV.fetch('RATE_LIMIT', '10'), exception: false)
  config.window = Float(ENV.fetch('RATE_LIMIT_WINDOW', '10'), exception: false)
end

# Built once: the limiter holds every client's state, so all requests (and
# all Puma threads) must share this one instance for the life of the process.
limiter = RateLimiter.limiter

trusted_proxies = ENV.fetch('TRUSTED_PROXIES', '').split(',').map(&:strip).reject(&:empty?)

use RateLimiter::Middleware,
    limiter: limiter,
    paths: ['/limited'],
    client_ip: RateLimiter::Middleware::ClientIp.new(trusted_proxies: trusted_proxies)

run Api
