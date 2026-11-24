# frozen_string_literal: true

RSpec.describe RateLimiter::Algorithms::FixedWindowCounter do
  subject(:limiter) { described_class.new(limit: 3, window: 60, clock: clock) }

  # 64_033 seconds after midnight is 17:47:13; its window is 17:47:00-17:47:59.
  let(:clock) { FakeClock.new(64_033.0) }
  let(:key) { 'ip:203.0.113.7' }

  def use_up(consumer = key)
    limiter.limit.times { limiter.acquire(consumer) }
  end

  describe 'counting' do
    it 'allows `limit` requests per window, then rejects' do
      outcomes = Array.new(4) { limiter.acquire(key).allowed? }

      expect(outcomes).to eq([true, true, true, false])
    end

    it 'reports the requests remaining in the window' do
      remaining = Array.new(3) { limiter.acquire(key).remaining }

      expect(remaining).to eq([2, 1, 0])
    end

    it 'does not count rejected requests' do
      use_up
      limiter.acquire(key)

      expect(limiter.count(key)).to eq(3)
    end

    it 'keeps a separate counter per key' do
      use_up('ip:198.51.100.1')

      expect(limiter.acquire('ip:198.51.100.2')).to be_allowed
      expect(limiter.acquire('ip:198.51.100.1')).not_to be_allowed
    end
  end

  describe 'window boundaries' do
    it 'follows the worked example' do
      use_up

      expect(limiter.acquire(key))
        .to have_attributes(allowed?: false, remaining: 0, retry_after: 47.0, reset_after: 47.0)
    end

    it 'starts a fresh count in the next window' do
      use_up
      clock.advance(47)

      expect(limiter.acquire(key)).to be_allowed
    end

    it 'puts a request at the exact boundary in the next window' do
      boundary_clock = FakeClock.new(64_020.0)
      boundary = described_class.new(limit: 3, window: 60, clock: boundary_clock)
      3.times { boundary.acquire(key) }

      boundary_clock.advance(59.75)
      expect(boundary.acquire(key)).not_to be_allowed

      boundary_clock.advance(0.25) # exactly 17:48:00
      expect(boundary.acquire(key)).to be_allowed
    end

    it 'forgets counts from earlier windows, including skipped ones' do
      use_up
      clock.advance(60)
      expect(limiter.count(key)).to eq(0)

      clock.advance(3_600)
      expect(limiter.acquire(key)).to be_allowed
    end
  end

  describe 'reset' do
    it 'reports the seconds until the window resets on allowed requests too' do
      expect(limiter.acquire(key).reset_after).to eq(47.0)
    end
  end

  describe 'boundary burst' do
    it 'allows up to twice the limit across a window boundary' do
      burst_clock = FakeClock.new(64_079.5) # 17:47:59.5
      burst = described_class.new(limit: 3, window: 60, clock: burst_clock)

      before_boundary = 3.times.count { burst.acquire(key).allowed? }
      burst_clock.advance(0.5) # 17:48:00.0
      after_boundary = 3.times.count { burst.acquire(key).allowed? }

      expect(before_boundary + after_boundary).to eq(6)
    end
  end

  describe 'request costs' do
    it 'counts `cost` requests' do
      expect(limiter.acquire(key, cost: 2).remaining).to eq(1)
    end

    it 'rejects a cost that does not fit, without counting it' do
      limiter.acquire(key, cost: 2)

      expect(limiter.acquire(key, cost: 2)).to have_attributes(allowed?: false, remaining: 1)
      expect(limiter.acquire(key)).to be_allowed
    end
  end

  describe 'clock adjustments' do
    it 'keeps the current window when the clock moves backwards' do
      use_up
      clock.advance(-60)

      expect(limiter.acquire(key)).not_to be_allowed
      expect(limiter.count(key)).to eq(3)
    end

    it 'uses the wall clock by default' do
      result = described_class.new(limit: 1, window: 60).acquire(key)

      expect(result).to be_allowed
      expect(result.reset_after).to be_between(0, 60)
    end
  end

  describe 'window expiration' do
    it 'drops every counter when a new window starts' do
      1_000.times { |i| limiter.acquire("ip:#{i}") }
      expect(limiter.tracked_keys).to eq(1_000)

      clock.advance(60)
      expect(limiter.tracked_keys).to eq(0)
    end

    it 'handles many consumers' do
      admitted = 10_000.times.count { |i| limiter.acquire("ip:#{i}").allowed? }

      expect(admitted).to eq(10_000)
    end
  end

  describe 'validation' do
    [0, -1, 2.5, '3', nil].each do |limit|
      it "rejects limit #{limit.inspect}" do
        expect { described_class.new(limit: limit, window: 60) }.to raise_error(ArgumentError, /limit/)
      end
    end

    [0, -60, nil].each do |window|
      it "rejects window #{window.inspect}" do
        expect { described_class.new(limit: 3, window: window) }.to raise_error(ArgumentError, /window/)
      end
    end

    [0, -1, 1.5].each do |cost|
      it "rejects cost #{cost}" do
        expect { limiter.acquire(key, cost: cost) }.to raise_error(ArgumentError, /cost/)
      end
    end

    it 'rejects a cost that exceeds the limit' do
      expect { limiter.acquire(key, cost: 4) }.to raise_error(ArgumentError, /exceeds limit/)
    end
  end

  describe 'concurrency' do
    it 'never admits more than the limit, however many threads compete' do
      shared = described_class.new(limit: 100, window: 60, clock: clock)
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
      expect(shared.count(key)).to eq(100)
    end
  end
end
