# frozen_string_literal: true

module RateLimiter
  # What the policy layer knows about a request. The HTTP layer (Middleware)
  # builds it: http_method upper-cased, path already normalized. env is the
  # raw Hash, handed only to the callables you configure (identifier, cost,
  # priority, tier), never parsed by the library itself.
  Request = Data.define(:http_method, :path, :env)
end
