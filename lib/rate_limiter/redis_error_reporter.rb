# frozen_string_literal: true

require_relative 'clock'
require_relative 'metrics'

module RateLimiter
  # Makes Redis outages visible without flooding the log. Give it to the
  # configuration as on_redis_error:
  #
  #   config.on_redis_error = RedisErrorReporter.new(logger:, metrics:, failure_policy: :allow)
  #
  # Every failure is counted (rate_limiter.redis_errors). The first one is
  # logged at once; during a long outage, one line per `interval` seconds
  # follows, saying how many failures it left out ("suppressed"). Thousands
  # of requests a second would otherwise mean thousands of identical lines.
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
      @metrics.increment('rate_limiter.redis_errors', error: error.class.name)
      suppressed = due_for_a_log_line
      return if suppressed.nil? || @logger.nil?

      @logger.error(event: 'redis_unavailable', action: @action, error: error.class.name,
                    message: error.message, suppressed: suppressed)
    end

    private

    # nil while within the interval; otherwise how many failures went unlogged.
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
