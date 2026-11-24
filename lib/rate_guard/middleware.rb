# frozen_string_literal: true

require 'rack'
require_relative 'clock'
require_relative 'metrics'
require_relative 'middleware/client_ip'
require_relative 'identifiers'
require_relative 'request'
require_relative 'policy_set'

module RateGuard
  # Rack middleware. Asks the policies about each request, then adds
  # RateLimit-* headers, rejects with 429, logs and records metrics.
  class Middleware
    CLIENT_KEY = 'rate_guard.client_key'
    RESULT_KEY = 'rate_guard.result'
    POLICY_KEY = 'rate_guard.policy'
    DECISION_KEY = 'rate_guard.decision'
    BYPASSED_KEY = 'rate_guard.bypassed'

    UNIDENTIFIED_KEY = Policy::UNIDENTIFIED_KEY

    # Float math can give 10.000000000000002; don't round that up to 11.
    ROUNDING_TOLERANCE = 1e-9

    # Default 429 response. Headers are added to any responder's response.
    DEFAULT_RESPONDER = lambda do |_env, _result, _policy|
      [429, { 'content-type' => 'text/plain' }, ["Too Many Requests\n"]]
    end

    # policies   - a PolicySet, or use limiter + paths for a single rule
    # limiter    - an immediate limiter
    # paths      - paths it applies to
    # identifier - who a request counts against (default: client IP)
    # client_ip  - old option; prefer identifier: Identifiers::Ip.new(client_ip:)
    # responder  - callable(env, result, policy) returning the 429 response
    # logger     - a Logger, or nil for no logs
    # metrics    - see RateGuard::Metrics
    # clock      - times each decision
    def initialize(app, policies: nil, limiter: nil, paths: nil, identifier: nil, client_ip: nil,
                   responder: DEFAULT_RESPONDER, logger: nil, metrics: Metrics::Null.new, clock: Clock::Monotonic)
      @app = app
      @policies = policies || single_policy(limiter, paths, identifier, client_ip)
      raise ArgumentError, 'pass policies: or limiter:/paths:, not both' if policies && (limiter || paths)
      raise ArgumentError, 'policies must be a RateGuard::PolicySet' unless @policies.is_a?(PolicySet)
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

    # Trusted clients: not limited, so no RateLimit-* headers.
    def bypass(env)
      env[BYPASSED_KEY] = true
      @metrics.increment('rate_guard.bypassed')
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

    # Metrics for every request; a log line only for rejections.
    # Keys are digests for API keys, so no secret is logged.
    def report(request, decision, outcome, elapsed)
      tags = { policy: outcome.policy.name, algorithm: outcome.algorithm }
      @metrics.timing('rate_guard.decision', elapsed, tags)
      @metrics.increment(decision.allowed? ? 'rate_guard.allowed' : 'rate_guard.rejected', tags)
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

    # New Hash per response. ratelimit-reset only if the limiter reports it.
    def rate_limit_headers(outcome)
      result = outcome.result
      headers = {
        'ratelimit-limit' => outcome.limit.to_s,
        'ratelimit-remaining' => result.remaining.to_s
      }
      headers['ratelimit-reset'] = whole_seconds(result.reset_after) unless result.reset_after.nil?
      headers
    end

    # Whole seconds, rounded up, ignoring float noise.
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
