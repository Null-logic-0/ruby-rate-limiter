# frozen_string_literal: true

module RateGuard
  module Identifiers
    # One key for everyone: a cap on total traffic.
    class Global
      def initialize(key = 'global')
        @key = key
      end

      def call(_env) = @key
    end
  end
end
