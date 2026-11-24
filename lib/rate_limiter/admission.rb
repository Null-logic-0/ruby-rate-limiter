# frozen_string_literal: true

module RateLimiter
  # The outcome of offering an item to a queue-based limiter.

  # accepted    - true if the item joined the queue
  # position    - 1-based place in the queue (nil if rejected)
  # wait        - estimated seconds until the item is released (nil if rejected)
  # retry_after - estimated seconds until the queue has room (0.0 if accepted)
  Admission = Data.define(:accepted, :position, :wait, :retry_after) do
    def accepted? = accepted
  end
end
