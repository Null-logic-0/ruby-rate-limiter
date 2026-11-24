# frozen_string_literal: true

module RateGuard
  # A request as policies see it: upper-case method, normalized path,
  # and the raw env for your own callables.
  Request = Data.define(:http_method, :path, :env)
end
