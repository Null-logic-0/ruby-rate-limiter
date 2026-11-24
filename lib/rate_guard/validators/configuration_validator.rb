# frozen_string_literal: true

require_relative '../utils/numeric_utils'

module RateGuard
  # Validation shared by the algorithms.
  module Validators
    # Checks algorithm settings: types and ranges.
    module ConfigurationValidator
      module_function

      def validate!(**attributes)
        attributes.each do |name, (value, type)|
          valid = case type
                  when :integer
                    value.is_a?(Integer) && value.positive?
                  when :number
                    Utils::NumericUtils.positive_number?(value)
                  else
                    raise ArgumentError, "Unknown validation type: #{type}"
                  end

          raise ArgumentError, "#{name} must be a positive #{type}" unless valid
        end
      end
    end
  end
end
