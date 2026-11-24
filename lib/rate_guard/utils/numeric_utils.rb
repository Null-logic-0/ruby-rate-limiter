# frozen_string_literal: true

module RateGuard
  module Utils
    # Number checks shared by the algorithms.
    module NumericUtils
      module_function

      def positive_number?(value)
        value.is_a?(Numeric) &&
          value.real? &&
          value.finite? &&
          value.positive?
      end

      def positive_integer?(value)
        value.is_a?(Integer) &&
          value.positive?
      end
    end
  end
end
