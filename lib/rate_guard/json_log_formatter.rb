# frozen_string_literal: true

require 'json'
require 'time'

module RateGuard
  # Logger formatter that writes one JSON object per line:
  #
  #   logger.warn(event: 'rate_limited', policy: 'login')
  #   # => {"time":"...","level":"warn","event":"rate_limited","policy":"login"}
  #
  # Non-Hash messages go under "message".
  class JsonLogFormatter
    # A Logger writing JSON lines to `io`. Requires the logger gem.
    # Turns off buffering so lines show up at once in Docker.
    def self.logger(io = $stdout, level: :info)
      require 'logger'
      io.sync = true if io.respond_to?(:sync=)
      Logger.new(io, level:, formatter: new)
    end

    def call(severity, time, progname, message)
      fields = message.is_a?(Hash) ? message : { message: message.to_s }
      head = { time: time.utc.iso8601(3), level: severity.downcase, progname: progname }.compact

      "#{JSON.generate(head.merge(fields))}\n"
    end
  end
end
