# frozen_string_literal: true

require 'rate_guard/algorithms/redis_sliding_window_counter'

RSpec.describe RateGuard::Algorithms::RedisSlidingWindowCounter do
  let(:key) { 'ip:203.0.113.7' }

  # A stand-in for a Redis client that fails every call with `error`.
  def failing_redis(error)
    Object.new.tap do |fake|
      fake.define_singleton_method(:evalsha) { |*, **| raise error }
      fake.define_singleton_method(:eval) { |*, **| raise error }
    end
  end

  describe 'against a real Redis', :redis do
    subject(:limiter) { build }

    let(:clock) { FakeClock.new(600.0) }

    def build(clock: self.clock, connection: redis)
      described_class.new(redis: connection, limit: 10, window: 60, namespace: redis_namespace, clock: clock)
    end

    it 'allows `limit` requests in a fresh window, then rejects' do
      expect(Array.new(11) { limiter.acquire(key).allowed? }).to eq([true] * 10 + [false])
    end

    it 'keeps a reserve for requests without one, decided atomically in the script' do
      low = Array.new(8) { limiter.acquire(key, reserve: 3).allowed? }
      normal = Array.new(4) { limiter.acquire(key).allowed? }

      expect(low).to eq([true] * 7 + [false])
      expect(normal).to eq([true, true, true, false])
    end

    it 'follows the Phase 8 worked example' do
      8.times { limiter.acquire(key) }
      clock.advance(75) # 15 s (25%) into the next window: estimate 3 + 8 × 0.75 = 9
      3.times { limiter.acquire(key) }

      expect(limiter.acquire(key)).to have_attributes(allowed?: true, remaining: 0)
      expect(limiter.acquire(key)).to have_attributes(allowed?: false, remaining: 0, retry_after: 7.5)

      clock.advance(7.5)
      expect(limiter.acquire(key)).to be_allowed
    end

    it 'turns the current count into the previous count when a window ends' do
      5.times { limiter.acquire(key) }
      clock.advance(60)

      expect(limiter.acquire(key).remaining).to eq(4) # 5 × 1.0 + 1
    end

    it 'forgets both counts when a whole window is skipped' do
      5.times { limiter.acquire(key) }
      clock.advance(120)

      expect(limiter.acquire(key).remaining).to eq(9)
    end

    it 'keeps separate counters per key' do
      10.times { limiter.acquire('ip:198.51.100.1') }

      expect(limiter.acquire('ip:198.51.100.2')).to be_allowed
      expect(limiter.acquire('ip:198.51.100.1')).not_to be_allowed
    end

    it 'stores one small hash per consumer under a namespaced key' do
      limiter.acquire(key)

      expect(limiter.redis_key(key)).to eq("#{redis_namespace}:w60:#{key}")
      expect(redis.hgetall(limiter.redis_key(key))).to eq('index' => '10', 'current' => '1', 'previous' => '0')
    end

    it 'expires the hash when both windows have passed' do
      limiter.acquire(key)

      expect(redis.pttl(limiter.redis_key(key))).to be_within(1_000).of(120_000)
    end

    it 'shares one limit between two servers' do
      server_a = build(connection: Redis.new(url: redis_url))
      server_b = build(connection: Redis.new(url: redis_url))

      10.times { server_a.acquire(key) }

      expect(server_b.acquire(key)).not_to be_allowed
    end

    it "stays exact when both servers' threads compete" do
      server_a = build(connection: Redis.new(url: redis_url))
      server_b = build(connection: Redis.new(url: redis_url))

      outcomes = run_concurrently(threads: 50) { |i| (i.even? ? server_a : server_b).acquire(key).allowed? }

      expect(outcomes.count(true)).to eq(10)
    end

    it 'reloads the script when Redis has forgotten it' do
      limiter.acquire(key)
      redis.script(:flush) # also clears other clients' cached scripts in this Redis

      expect(limiter.acquire(key)).to be_allowed
    end

    it "uses the Redis server's clock when none is injected" do
      result = build(clock: nil).acquire(key)

      expect(result).to be_allowed
      expect(result.reset_after).to be_between(60, 120)
    end

    it 'makes exactly the same decisions as the in-memory counter' do
      sim_clock = FakeClock.new(0.0)
      in_memory = RateGuard::Algorithms::SlidingWindowCounter.new(limit: 10, window: 60, clock: sim_clock)
      shared = build(clock: sim_clock)
      random = Random.new(3)

      pairs = Array.new(2_000) do
        sim_clock.advance(random.rand(0..24) * 0.25)
        [in_memory.acquire(key), shared.acquire(key)]
      end
      differences = pairs.reject do |expected, actual|
        actual.allowed? == expected.allowed? && actual.remaining == expected.remaining &&
          (actual.retry_after - expected.retry_after).abs < 1e-6 &&
          (actual.reset_after - expected.reset_after).abs < 1e-6
      end

      expect(differences).to be_empty
      expect(pairs.map { |expected, _| expected.allowed? }).to include(true, false)
    end
  end

  describe 'when Redis is unreachable' do
    let(:unreachable) { failing_redis(Redis::CannotConnectError.new('Connection refused')) }

    it 'fails open by default: the request is allowed' do
      limiter = described_class.new(redis: unreachable, limit: 10, window: 60)

      expect(limiter.acquire(key)).to have_attributes(allowed?: true, remaining: 10, reset_after: nil)
    end

    it 'fails closed with failure_policy: :reject' do
      limiter = described_class.new(redis: unreachable, limit: 10, window: 60, failure_policy: :reject)

      expect(limiter.acquire(key)).to have_attributes(allowed?: false, remaining: 0, retry_after: 1.0)
    end

    it 'reports the error to on_error' do
      errors = []
      limiter = described_class.new(redis: unreachable, limit: 10, window: 60, on_error: ->(e) { errors << e })

      limiter.acquire(key)

      expect(errors.map(&:class)).to eq([Redis::CannotConnectError])
    end

    it 'raises errors that are not about connectivity' do
      broken = failing_redis(Redis::CommandError.new('ERR something is wrong'))
      limiter = described_class.new(redis: broken, limit: 10, window: 60)

      expect { limiter.acquire(key) }.to raise_error(Redis::CommandError, /something is wrong/)
    end
  end

  describe 'validation' do
    let(:client) { failing_redis(Redis::CannotConnectError.new('unused')) }

    it 'rejects an unknown failure policy' do
      expect { described_class.new(redis: client, limit: 10, window: 60, failure_policy: :maybe) }
        .to raise_error(ArgumentError, /failure_policy/)
    end

    it 'rejects a limit that is not a positive integer' do
      expect { described_class.new(redis: client, limit: 0, window: 60) }.to raise_error(ArgumentError, /limit/)
    end

    it 'rejects a window that is not a positive number' do
      expect { described_class.new(redis: client, limit: 10, window: 0) }.to raise_error(ArgumentError, /window/)
    end

    it 'rejects an object that is not a Redis client' do
      expect { described_class.new(redis: Object.new, limit: 10, window: 60) }
        .to raise_error(ArgumentError, /evalsha/)
    end

    it 'rejects a cost above the limit before calling Redis' do
      limiter = described_class.new(redis: client, limit: 10, window: 60)

      expect { limiter.acquire(key, cost: 11) }.to raise_error(ArgumentError, /exceeds limit/)
    end
  end
end
