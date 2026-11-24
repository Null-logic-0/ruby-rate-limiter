# frozen_string_literal: true

module RateGuard
  # Identifiers decide who a request counts against.
  #
  # Any object with #call(env) returning a prefixed key
  # ("ip:203.0.113.7", "user:42") or nil. The prefix keeps kinds apart.
  # Keys are stored and logged, so they must never contain secrets.
  module Identifiers
  end
end

require_relative 'identifiers/ip'
require_relative 'identifiers/api_key'
require_relative 'identifiers/user'
require_relative 'identifiers/first_of'
require_relative 'identifiers/global'
