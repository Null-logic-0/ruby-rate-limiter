# frozen_string_literal: true

require_relative '../utils/numeric_utils'

module RateLimiter
  module Validators
    # Provides reusable cost validation, ensuring costs are positive, have the correct numeric type, and do not 
    # exceed configured limits.
    module CostValidator
      module_function

      def validate!(cost:, maximum:, type:, maximum_name: 'limit')
        valid = case type
                when :number
                  Utils::NumericUtils.positive_number?(cost)
                when :integer
                  Utils::NumericUtils.positive_integer?(cost)
                else
                  raise ArgumentError, "Unknown cost type: #{type}"
                end

        raise ArgumentError, "cost must be a positive #{type}" unless valid

        return unless cost > maximum

        raise ArgumentError, "cost #{cost} exceeds #{maximum_name} #{maximum}"
      end
    end
  end
end
