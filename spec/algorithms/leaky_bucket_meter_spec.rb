# frozen_string_literal: true

RSpec.describe RateGuard::Algorithms::LeakyBucketMeter do
  subject(:bucket) { described_class.new(capacity: 10, leak_rate: 1, clock: clock) }

  let(:clock) { FakeClock.new }
  let(:key) { 'ip:203.0.113.7' }

  def fill(limiter, consumer = key)
    limiter.acquire(consumer, cost: limiter.capacity)
  end

  describe 'a new consumer' do
    it 'starts with an empty bucket' do
      expect(bucket.level(key)).to eq(0.0)
    end

    it 'allows a burst of `capacity` requests, then rejects' do
      outcomes = Array.new(11) { bucket.acquire(key).allowed? }

      expect(outcomes).to eq([true] * 10 + [false])
    end
  end

  describe 'results' do
    it 'reports the remaining headroom after each request' do
      remaining = Array.new(10) { bucket.acquire(key).remaining }

      expect(remaining).to eq([9, 8, 7, 6, 5, 4, 3, 2, 1, 0])
    end

    it 'reports how long to wait when rejected' do
      fill(bucket)

      expect(bucket.acquire(key)).to have_attributes(allowed?: false, remaining: 0, retry_after: 1.0)
    end
  end

  describe 'leaking' do
    it 'leaks one unit per second' do
      fill(bucket)
      clock.advance(1)

      expect(bucket.acquire(key)).to be_allowed
      expect(bucket.acquire(key)).not_to be_allowed
    end

    it 'leaks fractional units for partial seconds' do
      fill(bucket)
      clock.advance(0.4)

      expect(bucket.level(key)).to be_within(1e-9).of(9.6)
    end

    it 'keeps the water level across a rejection' do
      fill(bucket)
      clock.advance(0.4)

      rejected = bucket.acquire(key)
      expect(rejected).not_to be_allowed
      expect(rejected.retry_after).to be_within(1e-9).of(0.6)

      clock.advance(0.6)
      expect(bucket.acquire(key)).to be_allowed
    end

    it 'never drains below empty' do
      bucket.acquire(key, cost: 3)
      clock.advance(1_000)

      expect(bucket.level(key)).to eq(0.0)
    end

    it 'supports leak rates below one unit per second' do
      slow = described_class.new(capacity: 1, leak_rate: 0.5, clock: clock)
      fill(slow)
      clock.advance(1)

      expect(slow.acquire(key)).to have_attributes(allowed?: false, retry_after: 1.0)

      clock.advance(1)
      expect(slow.acquire(key)).to be_allowed
    end

    it 'ignores a clock that moves backwards' do
      fill(bucket)

      clock.advance(-5)
      expect(bucket.level(key)).to eq(10.0)

      clock.advance(5)
      expect(bucket.level(key)).to eq(10.0)

      clock.advance(1)
      expect(bucket.level(key)).to eq(9.0)
    end

    it 'absorbs floating-point drift' do
      drifting = described_class.new(capacity: 1, leak_rate: 0.1, clock: clock)
      fill(drifting)
      10.times do
        clock.advance(1)
        drifting.level(key)
      end

      expect(drifting.level(key)).to be > 0.0
      expect(drifting.acquire(key)).to be_allowed
    end
  end

  describe 'request costs' do
    it 'adds `cost` units of water' do
      expect(bucket.acquire(key, cost: 3).remaining).to eq(7)
    end

    it 'rejects a request that would overflow without adding any water' do
      bucket.acquire(key, cost: 8)

      expect(bucket.acquire(key, cost: 3)).to have_attributes(allowed?: false, remaining: 2, retry_after: 1.0)
      expect(bucket.acquire(key, cost: 2)).to be_allowed
    end

    it 'waits longer for larger costs' do
      fill(bucket)

      expect(bucket.acquire(key, cost: 4).retry_after).to eq(4.0)
    end
  end

  describe 'multiple consumers' do
    it 'keeps a separate bucket per key' do
      fill(bucket, 'ip:198.51.100.1')

      expect(bucket.acquire('ip:198.51.100.2')).to be_allowed
      expect(bucket.acquire('ip:198.51.100.1')).not_to be_allowed
    end

    it 'handles many consumers' do
      admitted = 10_000.times.count { |i| bucket.acquire("ip:#{i}").allowed? }

      expect(admitted).to eq(10_000)
    end
  end

  describe 'sustained traffic' do
    it 'admits floor(capacity + rate × elapsed) requests' do
      admitted = 0
      240.times do
        admitted += 1 if bucket.acquire(key).allowed?
        clock.advance(0.25)
      end

      # Last request at 59.75 s: floor(10 + 59.75 × 1) = 69
      expect(admitted).to eq(69)
    end
  end

  describe 'equivalence with TokenBucket' do
    it 'makes the same decisions as a token bucket with the same settings' do
      token_bucket = RateGuard::Algorithms::TokenBucket.new(capacity: 10, refill_rate: 2, clock: clock)
      meter = described_class.new(capacity: 10, leak_rate: 2, clock: clock)
      random = Random.new(42)
      decisions = []

      2_000.times do
        clock.advance(random.rand(0.0..0.6))
        cost = random.rand(1..4)

        expected = token_bucket.acquire(key, cost: cost)
        actual = meter.acquire(key, cost: cost)

        expect(actual.allowed?).to eq(expected.allowed?)
        expect(actual.remaining).to eq(expected.remaining)
        expect(actual.retry_after).to be_within(1e-9).of(expected.retry_after)
        decisions << actual.allowed?
      end

      expect(decisions).to include(true, false)
    end
  end

  describe 'validation' do
    [0, -1, '10', nil, Float::INFINITY].each do |capacity|
      it "rejects capacity #{capacity.inspect}" do
        expect { described_class.new(capacity: capacity, leak_rate: 1) }
          .to raise_error(ArgumentError, /capacity/)
      end
    end

    [0, -0.5].each do |rate|
      it "rejects leak_rate #{rate}" do
        expect { described_class.new(capacity: 10, leak_rate: rate) }
          .to raise_error(ArgumentError, /leak_rate/)
      end
    end

    [0, -1].each do |cost|
      it "rejects cost #{cost}" do
        expect { bucket.acquire(key, cost: cost) }.to raise_error(ArgumentError, /cost/)
      end
    end

    it 'rejects a cost that exceeds capacity' do
      expect { bucket.acquire(key, cost: 11) }.to raise_error(ArgumentError, /exceeds capacity/)
    end
  end

  describe 'concurrency' do
    it 'never admits more than capacity, however many threads compete' do
      shared = described_class.new(capacity: 100, leak_rate: 1, clock: clock)
      start = Queue.new
      outcomes = Queue.new

      threads = Array.new(20) do
        Thread.new do
          start.pop
          50.times { outcomes << shared.acquire(key).allowed? }
        end
      end
      threads.size.times { start << :go }
      threads.each(&:join)

      admitted = Array.new(outcomes.size) { outcomes.pop }.count(true)
      expect(admitted).to eq(100)
      expect(shared.level(key)).to eq(100.0)
    end
  end

  it 'uses the monotonic clock by default' do
    expect(described_class.new(capacity: 1, leak_rate: 1).acquire(key)).to be_allowed
  end
end
