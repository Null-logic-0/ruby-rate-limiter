# frozen_string_literal: true

module RateGuard
  # Result of asking a limiter to allow one request.
  #
  # allowed     - true if the request may go ahead
  # remaining   - requests left afterwards
  # retry_after - seconds until a retry can succeed (0.0 if allowed)
  # reset_after - seconds until the limit is fully restored (nil if unknown)
  Result = Data.define(:allowed, :remaining, :retry_after, :reset_after) do
    def initialize(allowed:, remaining:, retry_after:, reset_after: nil)
      super(allowed:, remaining:, retry_after:, reset_after:)
    end

    def allowed? = allowed
  end
end
