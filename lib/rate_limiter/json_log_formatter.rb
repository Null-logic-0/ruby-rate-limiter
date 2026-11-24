# frozen_string_literal: true

require 'json'
require 'time'

module RateLimiter
  # A Logger formatter that writes one JSON object per line, so log tools can
  # search and count fields (event, policy, key, ...) instead of parsing text.
  #
  #   logger.warn(event: 'rate_limited', policy: 'login', key: 'ip:203.0.113.7')
  #   # => {"time":"2026-11-24T13:20:01.512Z","level":"warn","event":"rate_limited",...}
  #
  # Messages that aren't a Hash are logged under "message".
  class JsonLogFormatter
    # A Logger writing JSON lines to `io`. Logger is required only here: it's a
    # bundled gem on Ruby 4.0, and the rest of the library works without it.
    #
    # The stream is made unbuffered: when stdout is a pipe (Docker, systemd),
    # Ruby otherwise holds output in an 8 KB buffer, so lines arrive minutes
    # late, and are lost if the process is killed.
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
