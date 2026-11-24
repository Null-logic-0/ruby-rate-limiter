# frozen_string_literal: true

require_relative 'policy'

module RateGuard
  # Checks a request against every matching policy, in order.
  # - All must allow it. The first rejection stops the rest.
  # - Policies already checked stay charged, so put strict ones first.
  # - The client sees one policy: the one that rejected, or the one
  #   with the fewest requests left.
  # - A bypassed client skips every policy.
  class PolicySet
    # The result of checking one request.
    Decision = Data.define(:outcomes, :bypassed) do
      def matched? = bypassed || !outcomes.empty?
      def bypassed? = bypassed
      def allowed? = outcomes.all?(&:allowed?)

      # The outcome shown to the client.
      def reported
        outcomes.find { |outcome| !outcome.allowed? } ||
          outcomes.min_by { |outcome| [outcome.result.remaining, -(outcome.result.reset_after || 0.0)] }
      end
    end

    UNMATCHED = Decision.new(outcomes: [].freeze, bypassed: false)
    BYPASSED = Decision.new(outcomes: [].freeze, bypassed: true)

    attr_reader :policies

    # bypass - optional callable(env) -> true to skip limiting (see Bypass)
    def initialize(policies, bypass: nil)
      policies = Array(policies)
      raise ArgumentError, 'a PolicySet needs at least one policy' if policies.empty?
      raise ArgumentError, 'policies must be RateGuard::Policy objects' unless policies.all?(Policy)

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
