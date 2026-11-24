# frozen_string_literal: true

require 'rack'
require_relative 'middleware/client_ip'
require_relative 'identifiers'
require_relative 'request'
require_relative 'policy_set'

module RateLimiter
  # The HTTP layer. Turns the Rack env into a Request (method, normalized
  # path), lets a PolicySet decide, and turns the decision into HTTP:
  # RateLimit-* headers, a 429 for rejections, and the decision in the env.
  # Everything else (which policies apply, who a request counts against, what
  # it costs) is decided by the policies.
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

    # policies   - a PolicySet; or, for one limit on some paths, the shorthand:
    # limiter    - an immediate limiter
    # paths      - the paths it covers (any spelling; normalized here)
    # identifier - who requests count against (default: client IP)
    # client_ip  - kept for compatibility: identifier: Identifiers::Ip.new(client_ip:)
    def initialize(app, policies: nil, limiter: nil, paths: nil, identifier: nil, client_ip: nil)
      @app = app
      @policies = policies || single_policy(limiter, paths, identifier, client_ip)
      raise ArgumentError, 'pass policies: or limiter:/paths:, not both' if policies && (limiter || paths)
      raise ArgumentError, 'policies must be a RateLimiter::PolicySet' unless @policies.is_a?(PolicySet)
    end

    def call(env)
      decision = @policies.decide(Request.new(http_method: env['REQUEST_METHOD'].to_s.upcase,
                                              path: normalize(env['PATH_INFO'].to_s), env: env))
      return @app.call(env) unless decision.matched?
      return bypass(env) if decision.bypassed?

      reported = record(env, decision)
      return too_many_requests(reported) unless decision.allowed?

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

    # The one 429 every algorithm and policy produces.
    def too_many_requests(outcome)
      headers = {
        'content-type' => 'text/plain',
        'retry-after' => whole_seconds(outcome.result.retry_after)
      }

      [429, headers.merge!(rate_limit_headers(outcome)), ["Too Many Requests\n"]]
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
