# frozen_string_literal: true

module RateGuard
  # Different limits per plan. Picks a limiter for each request:
  #
  #   Tiers.new(free: free_limiter, premium: premium_limiter) { |key, env| plan_of(key) }
  #
  # An unknown plan uses the first tier, never no limit.
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
