# frozen_string_literal: true

module RateGuard
  module Clock
    # Seconds since some fixed point. Never goes backwards: use it to measure time.
    module Monotonic
      def self.now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end

    # Seconds since 1970 (real time). Needed for calendar windows.
    # It can jump when the system clock changes.
    module Wall
      def self.now
        Process.clock_gettime(Process::CLOCK_REALTIME)
      end
    end
  end
end
