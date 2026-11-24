# rate_guard

Rate limiting for Ruby and Rack apps.

- 6 algorithms: token bucket, leaky bucket (meter and queue), fixed window, sliding window log, sliding window counter
- Rack middleware with rules per route, client, and plan
- Standard `RateLimit-*` and `Retry-After` headers
- Optional Redis, so many servers share one limit
- Thread-safe

Needs Ruby 4.0 or newer.

## Install

<!-- readme: gemfile -->
```ruby
gem 'rate_guard', '~> 0.1'
```

Add these too if you need them:

<!-- readme: gemfile -->
```ruby
gem 'redis', '~> 6.1'   # to share limits between servers
gem 'logger', '~> 1.7'  # for JSON logs
```

## Plain Ruby

```ruby
require 'rate_guard'

RateGuard.configure do |config|
  config.algorithm = :token_bucket
  config.limit = 3   # 3 requests...
  config.window = 60 # ...per 60 seconds
end

limiter = RateGuard.limiter

4.times do |n|
  result = limiter.acquire('user:42')
  if result.allowed?
    puts "request #{n + 1}: allowed, #{result.remaining} left"
  else
    puts "request #{n + 1}: rejected, retry in #{result.retry_after.ceil}s"
  end
end
```

```text
request 1: allowed, 2 left
request 2: allowed, 1 left
request 3: allowed, 0 left
request 4: rejected, retry in 20s
```

Each key (here `'user:42'`) has its own counter.

## Rack

Limit one path per client IP:

<!-- readme: file config.ru -->
```ruby
# config.ru
require 'rate_guard'
require 'rate_guard/middleware'

RateGuard.configure do |config|
  config.algorithm = :sliding_window_log
  config.limit = 2
  config.window = 60
end

use RateGuard::Middleware, limiter: RateGuard.limiter, paths: ['/hello']
run ->(_env) { [200, { 'content-type' => 'text/plain' }, ["Hello\n"]] }
```

The third request to `/hello` within a minute gets `429 Too Many Requests`. Other paths are not limited.

## Several rules

A `PolicySet` holds several rules. A request must pass all rules that match it.

```ruby
require 'rack'
require 'rate_guard'
require 'rate_guard/middleware'

RateGuard.configure do |config|
  config.algorithm = :sliding_window_log
  config.limit = 100
  config.window = 60
end

policies = RateGuard::PolicySet.new(
  [
    # 3 login attempts per minute, per IP
    RateGuard::Policy.new(name: 'login', methods: %w[POST], paths: %w[/login],
                          limiter: RateGuard.limiter(limit: 3)),
    # 1000 requests per minute for everyone together
    RateGuard::Policy.new(name: 'global', identifier: RateGuard::Identifiers::Global.new,
                          limiter: RateGuard.limiter(limit: 1000))
  ]
)

app = Rack::Builder.app do
  use RateGuard::Middleware, policies: policies
  run ->(_env) { [200, {}, ['ok']] }
end

client = Rack::MockRequest.new(app)
4.times do
  response = client.post('/login', 'REMOTE_ADDR' => '203.0.113.7')
  puts "#{response.status} remaining=#{response.headers['ratelimit-remaining']}"
end
```

```text
200 remaining=2
200 remaining=1
200 remaining=0
429 remaining=0
```

Each `Policy` can set:

| Option | What it does |
| --- | --- |
| `name:` | A unique name, used in logs |
| `limiter:` | The limiter that decides |
| `methods:`, `paths:` | Which requests it covers (`nil` means all) |
| `identifier:` | Who requests count against (default: client IP) |
| `cost:` | How much one request costs (default: 1) |

Identifiers: `Identifiers::Ip`, `Identifiers::ApiKey`, `Identifiers::User`, `Identifiers::Global`, and `Identifiers::FirstOf` to try several in order. API keys are stored only as hashes, never as plain text.

## Algorithms

| Name | Good for |
| --- | --- |
| `:token_bucket` | Allowing short bursts |
| `:leaky_bucket_meter` | Smooth, steady traffic |
| `:fixed_window` | Lowest memory use (allows bursts at window edges) |
| `:sliding_window_log` | Exact limits (uses more memory) |
| `:sliding_window_counter` | Nearly exact, low memory, works with Redis |
| `:leaky_bucket_queue` | Making work wait instead of rejecting it |

## Redis

With Redis, all your servers share one count:

<!-- readme: redis -->
```ruby
require 'redis'
require 'rate_guard'

redis = Redis.new(url: ENV.fetch('REDIS_URL', 'redis://127.0.0.1:6379'))
redis.scan_each(match: 'rate_guard:readme:*') { |key| redis.del(key) } # start fresh

RateGuard.configure do |config|
  config.algorithm = :sliding_window_counter
  config.limit = 3
  config.window = 60
  config.redis = redis
  config.namespace = 'rate_guard:readme'
end

server_a = RateGuard.limiter
server_b = RateGuard.limiter

[server_a, server_b, server_a, server_b].each_with_index do |server, n|
  puts "request #{n + 1}: #{server.acquire('user:42').allowed? ? 'allowed' : 'rejected'}"
end
```

```text
request 1: allowed
request 2: allowed
request 3: allowed
request 4: rejected
```

If Redis goes down, `config.redis_failure_policy` decides what happens:
`:allow` lets all requests through (the default), `:reject` blocks them.

## Logs

Rejected requests can be logged as JSON (`…` marks values that change each time):

```ruby
require 'rack'
require 'rate_guard'
require 'rate_guard/middleware'

logger = RateGuard::JsonLogFormatter.logger($stdout)
limiter = RateGuard::Algorithms::SlidingWindowLog.new(limit: 1, window: 60)

app = Rack::Builder.app do
  use RateGuard::Middleware, limiter: limiter, paths: ['/search'], logger: logger
  run ->(_env) { [200, {}, ['ok']] }
end

client = Rack::MockRequest.new(app)
2.times { client.get('/search', 'REMOTE_ADDR' => '203.0.113.7') }
```

```text
{"time":"…","level":"warn","event":"rate_limited","policy":"default","key":"ip:203.0.113.7","path":"/search","method":"GET","limit":1,"remaining":0,"retry_after":…,"algorithm":"sliding_window_log"}
```

## Settings

| Setting | Meaning |
| --- | --- |
| `algorithm` | Which algorithm (default `:token_bucket`) |
| `limit` | Requests allowed per window |
| `window` | Window length in seconds |
| `redis` | A Redis client, to share limits |
| `redis_failure_policy` | `:allow` or `:reject` when Redis is down |
| `namespace` | Prefix for Redis keys |

`RateGuard.limiter(limit: 5)` builds a limiter with some settings changed.

## Development

```sh
bundle install
bundle exec rspec          # tests (Redis tests are skipped without Redis)
bundle exec rake benchmark # speed and memory of each algorithm
docker compose up --build  # demo API with two servers and Redis
```

## License

MIT
