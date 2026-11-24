# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.1.0] - 2026-11-24

First release.

### Added

- Algorithms behind one interface (`acquire(key, cost:, reserve:)` returning a
  `Result`): token bucket, leaky bucket meter, fixed window, sliding window
  log and sliding window counter; a leaky bucket queue (`enqueue`/`dequeue`)
  for work that should wait instead of failing.
- A sliding window counter in Redis, atomic through a Lua script, shared by
  every application server, with a fail-open or fail-closed policy and an
  `on_redis_error` hook.
- `RateGuard.configure`, `RateGuard.limiter` (with per-limiter overrides),
  `RateGuard.queue`, and a registry for adding algorithms by name.
- `RateGuard::Middleware` for Rack 3: per-route policies (`Policy`,
  `PolicySet`), request cost, priority reserve, plan tiers (`Tiers`) and
  trusted-client bypass (`Bypass`).
- Identifiers: client IP (`X-Forwarded-For` only behind trusted proxies), API
  key (stored only as a digest, optionally verified), authenticated user,
  first-of and global.
- `RateLimit-Limit`, `RateLimit-Remaining`, `RateLimit-Reset` and
  `Retry-After` headers; a customizable rejection response.
- JSON log lines for rejections (`JsonLogFormatter`), a throttled Redis error
  reporter, and a metrics interface (`Metrics::Null`, `Metrics::InMemory`).
- Benchmarks comparing speed, memory and contention for every algorithm.

### Changed

- Renamed from `rate_limiter` to `rate_guard`, because `rate_limiter` is an
  existing gem on RubyGems: `require 'rate_guard'` and `RateGuard` replace
  `require 'rate_limiter'` and `RateLimiter`. Rack env keys, metric names and
  the default Redis namespace now start with `rate_guard`.

[Unreleased]: https://github.com/Null-logic-0/ruby-rate-limiter/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/Null-logic-0/ruby-rate-limiter/releases/tag/v0.1.0
