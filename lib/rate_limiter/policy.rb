# frozen_string_literal: true

require_relative 'identifiers'
require_relative 'tiers'

module RateLimiter
  # One rule: WHICH requests it covers (methods and paths, or a matcher), WHO
  # they count against (identifier), HOW MUCH each costs, and the limiter
  # that decides. Knows nothing about HTTP: it sees a Request, and the env
  # only through the callables you give it.
  class Policy
    # Requests the identifier can't attribute to anyone share this one key, so
    # leaving out a header never means escaping the limit.
    UNIDENTIFIED_KEY = 'anonymous'

    PRIORITIES = %i[high low].freeze

    # The outcome of applying a policy to one request. algorithm names the
    # limiter's class, e.g. "token_bucket", for logs and metrics.
    Outcome = Data.define(:policy, :key, :limit, :cost, :algorithm, :result) do
      def allowed? = result.allowed?
    end

    # "token_bucket" for Algorithms::TokenBucket; "custom" for anonymous classes.
    def self.algorithm_name(limiter)
      name = limiter.class.name.to_s.split('::').last.to_s
      name.empty? ? 'custom' : name.gsub(/([a-z\d])([A-Z])/, '\\1_\\2').downcase
    end

    attr_reader :name

    # name       - unique within a PolicySet; also names the policy in logs
    # limiter    - an immediate limiter (#acquire, #limit), or a Tiers
    # methods    - e.g. %w[GET]; nil matches every method
    # paths      - normalized paths, e.g. %w[/login]; nil matches every path
    # match      - callable(request) -> true/false, instead of methods/paths
    # identifier - callable(env) -> key or nil; defaults to the client IP
    # cost       - positive Integer, or callable(env) -> positive Integer;
    #              capped at the limit, so a request can cost at most all of it
    # priority   - callable(env) -> :high or :low; nil makes everything :high
    # reserve    - units a :low request may not use, kept for :high ones
    def initialize(name:, limiter:, methods: nil, paths: nil, match: nil, identifier: Identifiers::Ip.new,
                   cost: 1, priority: nil, reserve: 0)
      @name = name.to_s
      @selector = limiter.is_a?(Tiers) ? limiter : Tiers.new(name => limiter) { name }
      @matcher = build_matcher(methods, paths, match)
      @identifier = callable!(identifier, 'identifier')
      @cost = cost.respond_to?(:call) ? cost : fixed_cost!(cost)
      @priority = priority.nil? ? nil : callable!(priority, 'priority')
      @reserve = reserve
      validate_limiters!
    end

    def matches?(request) = @matcher.call(request)

    def apply(request)
      env = request.env
      key = identify(env)
      limiter = @selector.select(key, env)
      cost = [@cost.respond_to?(:call) ? @cost.call(env) : @cost, limiter.limit].min
      reserve = low_priority?(env) ? [@reserve, limiter.limit - cost].min : 0
      result = reserve.zero? ? limiter.acquire(key, cost:) : limiter.acquire(key, cost:, reserve:)

      Outcome.new(policy: self, key:, limit: limiter.limit, cost:, algorithm: Policy.algorithm_name(limiter), result:)
    end

    private

    def identify(env)
      key = @identifier.call(env)
      key.nil? || key.empty? ? UNIDENTIFIED_KEY : key
    end

    def low_priority?(env)
      return false if @priority.nil? || @reserve.zero?

      priority = @priority.call(env)
      raise ArgumentError, "priority must return one of #{PRIORITIES.inspect} (got #{priority.inspect})" unless
        PRIORITIES.include?(priority)

      priority == :low
    end

    def build_matcher(methods, paths, match)
      if match
        raise ArgumentError, 'pass match: or methods:/paths:, not both' if methods || paths

        return callable!(match, 'match')
      end

      verbs = methods&.map { |verb| verb.to_s.upcase }&.freeze
      routes = paths&.map { |path| canonical_path!(path) }&.freeze

      lambda do |request|
        (verbs.nil? || verbs.include?(request.http_method)) && (routes.nil? || routes.include?(request.path))
      end
    end

    # Requests are matched by their normalized path, so a policy path must be
    # written the same way, or it would silently never match.
    def canonical_path!(path)
      path = path.to_s
      segments = path.split('/').drop(1)
      return path if path == '/' || (path.match?(%r{\A(/[^/%\\]+)+\z}) && (segments & %w[. ..]).empty?)

      raise ArgumentError, "policy #{@name}: write the path #{path.inspect} normalized, like \"/login\""
    end

    def fixed_cost!(cost)
      return cost if cost.is_a?(Integer) && cost.positive?

      raise ArgumentError, "policy #{@name}: cost must be a positive Integer or respond to #call"
    end

    def validate_limiters!
      raise ArgumentError, 'reserve must be a non-negative Integer' unless @reserve.is_a?(Integer) && @reserve >= 0

      @selector.limiters.each do |limiter|
        unless limiter.respond_to?(:acquire) && limiter.respond_to?(:limit)
          raise ArgumentError,
                "limiter must respond to #acquire and #limit (got #{limiter.class}): " \
                'queue algorithms delay work instead of answering allow-or-reject immediately, ' \
                'so build the limiter with RateLimiter.limiter'
        end
        raise ArgumentError, "policy #{@name}: reserve must be below the limit" if @reserve >= limiter.limit
      end
    end

    def callable!(object, what)
      return object if object.respond_to?(:call)

      raise ArgumentError, "#{what} must respond to #call (got #{object.class})"
    end
  end
end
