# frozen_string_literal: true

module RateLimiter
  module Utils
    # Reusable numeric checks shared by every algorithm.
    module NumericUtils
      module_function

      def positive_number?(value)
        value.is_a?(Numeric) &&
          value.real? &&
          value.finite? &&
          value.positive?
      end
    end
  end
end
