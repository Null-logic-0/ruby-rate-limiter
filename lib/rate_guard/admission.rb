# frozen_string_literal: true

module RateGuard
  # Result of adding an item to a queue limiter.

  # accepted    - true if the item was queued
  # position    - place in the queue, from 1 (nil if rejected)
  # wait        - seconds until the item is released (nil if rejected)
  # retry_after - seconds until the queue has room (0.0 if accepted)
  Admission = Data.define(:accepted, :position, :wait, :retry_after) do
    def accepted? = accepted
  end
end
