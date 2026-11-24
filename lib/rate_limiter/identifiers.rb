# frozen_string_literal: true

module RateLimiter
  # Identifiers decide WHO a request counts against.
  #
  # An identifier is any object with #call(env) that returns a namespaced
  # String key ("ip:203.0.113.7", "user:42", ...) or nil when it can't
  # identify the request. The namespace keeps different kinds of consumer
  # apart: user 42 and the IP "42" must never share a counter.
  #
  # Keys end up in limiter state, in Redis and in logs, so they must never
  # contain secrets.
  module Identifiers
  end
end

require_relative 'identifiers/ip'
require_relative 'identifiers/api_key'
require_relative 'identifiers/user'
require_relative 'identifiers/first_of'
require_relative 'identifiers/global'
