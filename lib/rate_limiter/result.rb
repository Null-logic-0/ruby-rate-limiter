# frozen_string_literal: true

module RateLimiter
  # The outcome of asking a limiter to admit one request.
  #
  # allowed     - true if the request may proceed
  # remaining   - whole requests (of cost 1) still available afterwards
  # retry_after - seconds until the same request could succeed (0.0 if allowed)
  Result = Data.define(:allowed, :remaining, :retry_after) do
    def allowed? = allowed
  end
end
