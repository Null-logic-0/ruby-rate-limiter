# frozen_string_literal: true

require 'rack'
require_relative 'clock'
require_relative 'metrics'
require_relative 'middleware/client_ip'
require_relative 'identifiers'
require_relative 'request'
require_relative 'policy_set'

module RateLimiter
  # The HTTP layer. Turns the Rack env into a Request (method, normalized
  # path), lets a PolicySet decide, and turns the decision into HTTP:
  # RateLimit-* headers, a rejection response, and the decision in the env.
  # It also reports each decision: metrics for all of them, a log line for
  # each rejection. Everything else is decided by the policies.
  class Middleware
    CLIENT_KEY = 'rate_limiter.client_key'
    RESULT_KEY = 'rate_limiter.result'
    POLICY_KEY = 'rate_limiter.policy'
    DECISION_KEY = 'rate_limiter.decision'
    BYPASSED_KEY = 'rate_limiter.bypassed'

    UNIDENTIFIED_KEY = Policy::UNIDENTIFIED_KEY

    # Float arithmetic on timestamps can leave a result a hair above a whole
    # number (10.000000000000002). Rounding up must not turn that into 11.
    ROUNDING_TOLERANCE = 1e-9

    # The standard rejection. Rate limit headers and retry-after are added to
    # whatever a responder returns, so a custom one never has to.
    DEFAULT_RESPONDER = lambda do |_env, _result, _policy|
      [429, { 'content-type' => 'text/plain' }, ["Too Many Requests\n"]]
    end

    # policies   - a PolicySet; or, for one limit on some paths, the shorthand:
    # limiter    - an immediate limiter
    # paths      - the paths it covers (any spelling; normalized here)
    # identifier - who requests count against (default: client IP)
    # client_ip  - kept for compatibility: identifier: Identifiers::Ip.new(client_ip:)
    # responder  - callable(env, result, policy) -> Rack response for rejections
    # logger     - a Logger (ideally with JsonLogFormatter), or nil for no logs
    # metrics    - see RateLimiter::Metrics
    # clock      - measures how long decisions take
    def initialize(app, policies: nil, limiter: nil, paths: nil, identifier: nil, client_ip: nil,
                   responder: DEFAULT_RESPONDER, logger: nil, metrics: Metrics::Null.new, clock: Clock::Monotonic)
      @app = app
      @policies = policies || single_policy(limiter, paths, identifier, client_ip)
      raise ArgumentError, 'pass policies: or limiter:/paths:, not both' if policies && (limiter || paths)
      raise ArgumentError, 'policies must be a RateLimiter::PolicySet' unless @policies.is_a?(PolicySet)
      raise ArgumentError, 'responder must respond to #call' unless responder.respond_to?(:call)

      @responder = responder
      @logger = logger
      @metrics = metrics
      @clock = clock
    end

    def call(env)
      request = Request.new(http_method: env['REQUEST_METHOD'].to_s.upcase,
                            path: normalize(env['PATH_INFO'].to_s), env: env)
      started = @clock.now
      decision = @policies.decide(request)
      return @app.call(env) unless decision.matched?
      return bypass(env) if decision.bypassed?

      reported = record(env, decision)
      report(request, decision, reported, @clock.now - started)
      return reject(env, reported) unless decision.allowed?

      status, headers, body = @app.call(env)
      [status, headers.merge(rate_limit_headers(reported)), body]
    end

    private

    def single_policy(limiter, paths, identifier, client_ip)
      raise ArgumentError, 'pass policies:, or limiter: and paths:' if limiter.nil? || paths.nil?
      raise ArgumentError, 'pass identifier: or client_ip:, not both' if identifier && client_ip

      identifier ||= Identifiers::Ip.new(client_ip: client_ip || ClientIp.new)
      raise ArgumentError, "identifier must respond to #call (got #{identifier.class})" unless
        identifier.respond_to?(:call)

      PolicySet.new(Policy.new(name: 'default', limiter:, identifier:, paths: paths.map { |path| normalize(path) }))
    end

    # Trusted clients: no limiting, and no RateLimit-* headers, since no
    # quota applies to them.
    def bypass(env)
      env[BYPASSED_KEY] = true
      @metrics.increment('rate_limiter.bypassed')
      @app.call(env)
    end

    def record(env, decision)
      reported = decision.reported
      env[DECISION_KEY] = decision
      env[POLICY_KEY] = reported.policy.name
      env[CLIENT_KEY] = reported.key
      env[RESULT_KEY] = reported.result
      reported
    end

    # Metrics for every decision; a log line only for rejections, which are
    # the ones someone may need to investigate. Keys are identifiers' output
    # (digests for API keys), so no secret reaches the log.
    def report(request, decision, outcome, elapsed)
      tags = { policy: outcome.policy.name, algorithm: outcome.algorithm }
      @metrics.timing('rate_limiter.decision', elapsed, tags)
      @metrics.increment(decision.allowed? ? 'rate_limiter.allowed' : 'rate_limiter.rejected', tags)
      return if decision.allowed? || @logger.nil?

      @logger.warn(event: 'rate_limited', policy: outcome.policy.name, key: outcome.key, path: request.path,
                   method: request.http_method, limit: outcome.limit, remaining: outcome.result.remaining,
                   retry_after: outcome.result.retry_after.round(3), algorithm: outcome.algorithm)
    end

    def reject(env, outcome)
      status, headers, body = @responder.call(env, outcome.result, outcome.policy)
      retry_after = { 'retry-after' => whole_seconds(outcome.result.retry_after) }

      [status, headers.merge(retry_after, rate_limit_headers(outcome)), body]
    end

    # A new Hash for every response, so no two responses ever share one.
    # ratelimit-reset is left out when the limiter doesn't report it.
    def rate_limit_headers(outcome)
      result = outcome.result
      headers = {
        'ratelimit-limit' => outcome.limit.to_s,
        'ratelimit-remaining' => result.remaining.to_s
      }
      headers['ratelimit-reset'] = whole_seconds(result.reset_after) unless result.reset_after.nil?
      headers
    end

    # Headers carry whole seconds. Round up, so a client that waits the
    # advertised time is never early, but ignore float noise below a nanosecond.
    def whole_seconds(seconds)
      (seconds - ROUNDING_TOLERANCE).ceil.to_s
    end

    def normalize(path)
      decoded = Rack::Utils.unescape_path(path.b).tr('\\', '/')

      segments = decoded.split('/').each_with_object([]) do |segment, kept|
        next if segment.empty? || segment == '.'

        segment == '..' ? kept.pop : kept << segment
      end

      "/#{segments.join('/')}"
    end
  end
end
