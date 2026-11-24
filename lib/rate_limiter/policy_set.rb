# frozen_string_literal: true

require_relative 'policy'

module RateLimiter
  # Decides a request against every policy that matches it.
  #
  # - A request must pass ALL matching policies. They are applied in the
  #   order given, and the first rejection stops the rest: later policies are
  #   neither checked nor charged. Earlier ones stay charged, because undoing
  #   a spend is impossible to do atomically across limiters (or across
  #   servers sharing Redis). So list the policies most likely to reject
  #   first, and broad ones (a global limit) last.
  # - The client is told about ONE policy: the one that rejected, or else the
  #   most restrictive (fewest requests remaining; on a tie, the longest wait
  #   until it fully resets).
  # - A bypass (trusted clients) skips every policy.
  class PolicySet
    # What deciding one request produced.
    Decision = Data.define(:outcomes, :bypassed) do
      def matched? = bypassed || !outcomes.empty?
      def bypassed? = bypassed
      def allowed? = outcomes.all?(&:allowed?)

      # The outcome reported to the client.
      def reported
        outcomes.find { |outcome| !outcome.allowed? } ||
          outcomes.min_by { |outcome| [outcome.result.remaining, -(outcome.result.reset_after || 0.0)] }
      end
    end

    UNMATCHED = Decision.new(outcomes: [].freeze, bypassed: false)
    BYPASSED = Decision.new(outcomes: [].freeze, bypassed: true)

    attr_reader :policies

    # bypass - optional callable(env) -> true for clients that are never
    #          limited (see RateLimiter::Bypass)
    def initialize(policies, bypass: nil)
      policies = Array(policies)
      raise ArgumentError, 'a PolicySet needs at least one policy' if policies.empty?
      raise ArgumentError, 'policies must be RateLimiter::Policy objects' unless policies.all?(Policy)

      duplicates = policies.map(&:name).tally.select { |_name, count| count > 1 }.keys
      raise ArgumentError, "policy names must be unique (repeated: #{duplicates.join(', ')})" if duplicates.any?
      raise ArgumentError, 'bypass must respond to #call' unless bypass.nil? || bypass.respond_to?(:call)

      @policies = policies.freeze
      @bypass = bypass
    end

    def decide(request)
      matching = @policies.select { |policy| policy.matches?(request) }
      return UNMATCHED if matching.empty?
      return BYPASSED if @bypass&.call(request.env)

      outcomes = []
      matching.each do |policy|
        outcomes << policy.apply(request)
        break unless outcomes.last.allowed?
      end

      Decision.new(outcomes: outcomes.freeze, bypassed: false)
    end
  end
end
