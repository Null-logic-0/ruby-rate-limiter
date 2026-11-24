# frozen_string_literal: true

require_relative 'app/api'
require_relative 'lib/rate_limiter'
require_relative 'lib/rate_limiter/middleware'
require_relative 'lib/rate_limiter/bypass'

# Settings come from the environment. A value that isn't a number becomes nil,
# so RateLimiter.configure reports every bad setting together, at boot.
RateLimiter.configure do |config|
  config.algorithm = ENV.fetch('RATE_LIMIT_ALGORITHM', 'token_bucket')
  config.limit = Integer(ENV.fetch('RATE_LIMIT', '10'), exception: false)
  config.window = Float(ENV.fetch('RATE_LIMIT_WINDOW', '10'), exception: false)

  redis_url = ENV.fetch('REDIS_URL', '')
  unless redis_url.empty?
    require 'redis'
    config.redis = Redis.new(url: redis_url, timeout: 0.25)
    config.redis_failure_policy = ENV.fetch('RATE_LIMIT_REDIS_FAILURE', 'allow')

    # Without this, failing open is silent: the API looks healthy while it
    # stops limiting. Every failure is reported in the server's log instead.
    action = config.redis_failure_policy == :reject ? 'rejecting' : 'allowing'
    config.on_redis_error = lambda do |error|
      warn "[rate_limiter] Redis unavailable, #{action} the request: #{error.class}: #{error.message}"
    end
  end
end

env_list = ->(name) { ENV.fetch(name, '').split(',').map(&:strip).reject(&:empty?) }
ids = RateLimiter::Identifiers
policy = RateLimiter::Policy

# --- Who a request counts against ------------------------------------------
# Its API key if it sends one this server issued, otherwise its IP. Unknown
# keys fall through to the IP, so inventing keys never buys a fresh limit.
client_ip = RateLimiter::Middleware::ClientIp.new(trusted_proxies: env_list.call('TRUSTED_PROXIES'))
ip = ids::Ip.new(client_ip:)
premium_keys = env_list.call('RATE_LIMIT_PREMIUM_API_KEYS')
issued_keys = (env_list.call('RATE_LIMIT_API_KEYS') + premium_keys).to_set.freeze
api_key = ids::ApiKey.new(verify: issued_keys.method(:include?))
consumer = issued_keys.empty? ? ip : ids::FirstOf.new(api_key, ip)

# Plans are looked up by the consumer's key (a digest), never the raw API key.
premium = premium_keys.map { |key| api_key.key_for(key) }.to_set.freeze
plan = ->(key, _env) { premium.include?(key) ? :premium : :free }

# --- Limiters: one per policy, each in its own Redis namespace -------------
# The algorithm, Redis and failure policy come from the configuration above.
per_minute = ->(name, limit) { RateLimiter.limiter(limit:, window: 60, namespace: "rate_limiter:#{name}") }

# Uploads cost by size: up to 1 MB is 1, up to 10 MB is 5, anything larger
# (or of unknown size) uses the whole minute's allowance.
upload_cost = lambda do |env|
  size = Integer(env['CONTENT_LENGTH'].to_s, exception: false)
  next 10 if size.nil?

  if size <= 1_000_000 then 1
  elsif size <= 10_000_000 then 5
  else 10
  end
end

# A client may lower its own priority (X-Priority: low, e.g. a background
# sync); it can never raise it. Low-priority requests can't use the last 20.
voluntary_priority = ->(env) { env['HTTP_X_PRIORITY'].to_s.casecmp?('low') ? :low : :high }

policies = RateLimiter::PolicySet.new(
  [
    # Most specific first; the global cap last, so a request another policy
    # rejects never uses up shared capacity.
    policy.new(name: 'login', methods: %w[POST], paths: %w[/login], identifier: ip, # by IP: guessing passwords
               limiter: per_minute.call('login', 5)),
    policy.new(name: 'upload', methods: %w[POST], paths: %w[/upload], identifier: consumer, cost: upload_cost,
               limiter: per_minute.call('upload', 10)),
    policy.new(name: 'premium', methods: %w[GET], paths: %w[/premium], identifier: consumer,
               limiter: RateLimiter::Tiers.new(free: per_minute.call('premium:free', 20),
                                               premium: per_minute.call('premium:premium', 500), &plan)),
    policy.new(name: 'public', methods: %w[GET], paths: %w[/public], identifier: consumer,
               limiter: per_minute.call('public', 100), priority: voluntary_priority, reserve: 20),
    policy.new(name: 'limited', paths: %w[/limited], identifier: consumer, # RATE_LIMIT per RATE_LIMIT_WINDOW
               limiter: RateLimiter.limiter(namespace: 'rate_limiter:limited')),
    policy.new(name: 'global', paths: %w[/public /login /premium /upload /limited], identifier: ids::Global.new,
               limiter: per_minute.call('global', Integer(ENV.fetch('RATE_LIMIT_GLOBAL', '1000'), exception: false)))
  ],
  bypass: RateLimiter::Bypass.new(ip_ranges: env_list.call('RATE_LIMIT_BYPASS_IPS'),
                                  api_keys: env_list.call('RATE_LIMIT_BYPASS_API_KEYS'), client_ip:)
)

use RateLimiter::Middleware, policies: policies

run Api
