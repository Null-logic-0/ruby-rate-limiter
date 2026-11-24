# frozen_string_literal: true

require_relative '../utils/numeric_utils'

module RateLimiter
  module Validators
    # Provides reusable cost validation, ensuring costs are positive, have the correct numeric type, and do not
    # exceed configured limits.
    #
    # reserve - units a request must leave untouched (see the algorithms'
    #           acquire): cost plus reserve must still fit the maximum.
    module CostValidator
      module_function

      def validate!(cost:, maximum:, type:, maximum_name: 'limit', reserve: 0)
        valid = case type
                when :number
                  Utils::NumericUtils.positive_number?(cost)
                when :integer
                  Utils::NumericUtils.positive_integer?(cost)
                else
                  raise ArgumentError, "Unknown cost type: #{type}"
                end

        raise ArgumentError, "cost must be a positive #{type}" unless valid
        raise ArgumentError, "cost #{cost} exceeds #{maximum_name} #{maximum}" if cost > maximum

        validate_reserve!(reserve, cost, maximum, maximum_name)
      end

      def validate_reserve!(reserve, cost, maximum, maximum_name)
        raise ArgumentError, 'reserve must be a non-negative integer' unless reserve.is_a?(Integer) && reserve >= 0
        return unless cost + reserve > maximum

        raise ArgumentError, "cost #{cost} plus reserve #{reserve} exceeds #{maximum_name} #{maximum}"
      end
    end
  end
end
