# frozen_string_literal: true

module RateLimiter
  module Clock
    # Seconds since an arbitrary starting point. Never jumps backwards,
    # so it is safe for measuring elapsed time (but not for telling the time).
    module Monotonic
      def self.now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end

    # Seconds since the Unix epoch (wall-clock time). Needed when limits are
    # tied to calendar boundaries such as "the 17:47 minute". It can jump when
    # the system clock is adjusted, so algorithms using it must tolerate that.
    module Wall
      def self.now
        Process.clock_gettime(Process::CLOCK_REALTIME)
      end
    end
  end
end
