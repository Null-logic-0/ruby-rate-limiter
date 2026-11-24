# frozen_string_literal: true

require_relative 'clock'
require_relative 'metrics'

module RateGuard
  # Logs Redis failures without flooding the log:
  #
  #   config.on_redis_error = RedisErrorReporter.new(logger:, metrics:, failure_policy: :allow)
  #
  # Counts every failure, logs the first at once, then one line per
  # `interval` with how many were skipped.
  class RedisErrorReporter
    def initialize(logger: nil, metrics: Metrics::Null.new, failure_policy: :allow, interval: 60,
                   clock: Clock::Monotonic)
      @logger = logger
      @metrics = metrics
      @action = failure_policy.to_sym == :reject ? 'rejecting' : 'allowing'
      @interval = interval
      @clock = clock
      @last_logged_at = nil
      @suppressed = 0
      @mutex = Mutex.new
    end

    def call(error)
      @metrics.increment('rate_guard.redis_errors', error: error.class.name)
      suppressed = due_for_a_log_line
      return if suppressed.nil? || @logger.nil?

      @logger.error(event: 'redis_unavailable', action: @action, error: error.class.name,
                    message: error.message, suppressed: suppressed)
    end

    private

    # nil inside the interval; otherwise how many were skipped.
    def due_for_a_log_line
      @mutex.synchronize do
        now = @clock.now
        if @last_logged_at && now - @last_logged_at < @interval
          @suppressed += 1
          next nil
        end

        @last_logged_at = now
        @suppressed.tap { @suppressed = 0 }
      end
    end
  end
end
