# frozen_string_literal: true

module RateLimiter
  # Different limits for different kinds of consumer (plans, tiers). Holds one
  # limiter per tier, built once, and picks one per request:
  #
  #   Tiers.new(free: free_limiter, premium: premium_limiter) { |key, env| plan_of(key) }
  #
  # The block gets the identified consumer's key and the env; an unknown or
  # nil tier falls back to the first one, so a lookup miss is never unlimited.
  class Tiers
    def initialize(limiters, &resolve)
      raise ArgumentError, 'Tiers needs at least one tier' if limiters.empty?
      raise ArgumentError, 'Tiers needs a block that picks the tier' if resolve.nil?

      @limiters = limiters.freeze
      @default = limiters.values.first
      @resolve = resolve
    end

    def select(key, env)
      @limiters.fetch(@resolve.call(key, env)) { @default }
    end

    def limiters = @limiters.values
  end
end
