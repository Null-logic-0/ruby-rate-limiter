# frozen_string_literal: true

require_relative 'app/api'
require_relative 'lib/rate_guard'
require_relative 'lib/rate_guard/middleware'
require_relative 'lib/rate_guard/bypass'

# JSON logs on stdout. RATE_LIMIT_LOG_LEVEL=error shows only Redis errors.
logger = RateGuard::JsonLogFormatter.logger($stdout, level: ENV.fetch('RATE_LIMIT_LOG_LEVEL', 'info'))
# Swap in a StatsD/Prometheus adapter here (see RateGuard::Metrics).
metrics = RateGuard::Metrics::Null.new

# Settings from ENV. Bad values become nil and are reported at boot.
RateGuard.configure do |config|
  config.algorithm = ENV.fetch('RATE_LIMIT_ALGORITHM', 'token_bucket')
  config.limit = Integer(ENV.fetch('RATE_LIMIT', '10'), exception: false)
  config.window = Float(ENV.fetch('RATE_LIMIT_WINDOW', '10'), exception: false)

  redis_url = ENV.fetch('REDIS_URL', '')
  unless redis_url.empty?
    require 'redis'
    config.redis = Redis.new(url: redis_url, timeout: 0.25)
    config.redis_failure_policy = ENV.fetch('RATE_LIMIT_REDIS_FAILURE', 'allow')

    # Log Redis failures, so failing open is never silent.
    config.on_redis_error = RateGuard::RedisErrorReporter.new(
      logger:, metrics:, failure_policy: config.redis_failure_policy,
      interval: Float(ENV.fetch('RATE_LIMIT_REDIS_LOG_INTERVAL', '60'), exception: false) || 60
    )
  end
end

env_list = ->(name) { ENV.fetch(name, '').split(',').map(&:strip).reject(&:empty?) }
ids = RateGuard::Identifiers
policy = RateGuard::Policy

# --- Who a request counts against ---
# API key if it's one we issued, otherwise the IP.
client_ip = RateGuard::Middleware::ClientIp.new(trusted_proxies: env_list.call('TRUSTED_PROXIES'))
ip = ids::Ip.new(client_ip:)
premium_keys = env_list.call('RATE_LIMIT_PREMIUM_API_KEYS')
issued_keys = (env_list.call('RATE_LIMIT_API_KEYS') + premium_keys).to_set.freeze
api_key = ids::ApiKey.new(verify: issued_keys.method(:include?))
consumer = issued_keys.empty? ? ip : ids::FirstOf.new(api_key, ip)

# Plans by key digest, never the raw API key.
premium = premium_keys.map { |key| api_key.key_for(key) }.to_set.freeze
plan = ->(key, _env) { premium.include?(key) ? :premium : :free }

# --- One limiter per policy, each with its own Redis namespace ---
per_minute = ->(name, limit) { RateGuard.limiter(limit:, window: 60, namespace: "rate_guard:#{name}") }

# Uploads cost by size: <= 1 MB is 1, <= 10 MB is 5, bigger or unknown is all.
upload_cost = lambda do |env|
  size = Integer(env['CONTENT_LENGTH'].to_s, exception: false)
  next 10 if size.nil?

  if size <= 1_000_000 then 1
  elsif size <= 10_000_000 then 5
  else 10
  end
end

# Clients may send X-Priority: low; low requests can't use the last 20.
voluntary_priority = ->(env) { env['HTTP_X_PRIORITY'].to_s.casecmp?('low') ? :low : :high }

policies = RateGuard::PolicySet.new(
  [
    # Specific policies first, the global cap last.
    policy.new(name: 'login', methods: %w[POST], paths: %w[/login], identifier: ip, # by IP: guessing passwords
               limiter: per_minute.call('login', 5)),
    policy.new(name: 'upload', methods: %w[POST], paths: %w[/upload], identifier: consumer, cost: upload_cost,
               limiter: per_minute.call('upload', 10)),
    policy.new(name: 'premium', methods: %w[GET], paths: %w[/premium], identifier: consumer,
               limiter: RateGuard::Tiers.new(free: per_minute.call('premium:free', 20),
                                               premium: per_minute.call('premium:premium', 500), &plan)),
    policy.new(name: 'public', methods: %w[GET], paths: %w[/public], identifier: consumer,
               limiter: per_minute.call('public', 100), priority: voluntary_priority, reserve: 20),
    policy.new(name: 'limited', paths: %w[/limited], identifier: consumer, # RATE_LIMIT per RATE_LIMIT_WINDOW
               limiter: RateGuard.limiter(namespace: 'rate_guard:limited')),
    policy.new(name: 'global', paths: %w[/public /login /premium /upload /limited], identifier: ids::Global.new,
               limiter: per_minute.call('global', Integer(ENV.fetch('RATE_LIMIT_GLOBAL', '1000'), exception: false)))
  ],
  bypass: RateGuard::Bypass.new(ip_ranges: env_list.call('RATE_LIMIT_BYPASS_IPS'),
                                  api_keys: env_list.call('RATE_LIMIT_BYPASS_API_KEYS'), client_ip:)
)

# JSON 429 body. The middleware adds the headers.
json_rejection = lambda do |_env, result, policy|
  body = JSON.generate(error: 'rate_limited', policy: policy.name, retry_after: result.retry_after.ceil)
  [429, { 'content-type' => 'application/json' }, [body]]
end

use RateGuard::Middleware, policies: policies, responder: json_rejection, logger: logger, metrics: metrics

run Api
