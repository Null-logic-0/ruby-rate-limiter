# frozen_string_literal: true

RSpec.describe RateLimiter::Algorithms::SlidingWindowLog do
  subject(:limiter) { described_class.new(limit: 3, window: 60, clock: clock) }

  let(:clock) { FakeClock.new }
  let(:key) { 'ip:203.0.113.7' }

  def use_up(consumer = key)
    limiter.limit.times { limiter.acquire(consumer) }
  end

  describe 'counting' do
    it 'allows `limit` requests in a window, then rejects' do
      outcomes = Array.new(4) { limiter.acquire(key).allowed? }

      expect(outcomes).to eq([true, true, true, false])
    end

    it 'reports the requests remaining' do
      remaining = Array.new(3) { limiter.acquire(key).remaining }

      expect(remaining).to eq([2, 1, 0])
    end

    it 'reports how long until the whole log has expired' do
      limiter.acquire(key)
      clock.advance(10)
      limiter.acquire(key)
      clock.advance(10)

      expect(limiter.acquire(key).reset_after).to eq(60.0)

      clock.advance(10)
      expect(limiter.acquire(key)).to have_attributes(allowed?: false, reset_after: 50.0)
    end

    it 'keeps a separate log per key' do
      use_up('ip:198.51.100.1')

      expect(limiter.acquire('ip:198.51.100.2')).to be_allowed
      expect(limiter.acquire('ip:198.51.100.1')).not_to be_allowed
    end
  end

  describe 'sliding' do
    it 'follows the worked example' do
      timeline = [0, 10, 10, 10, 30, 5].map do |step|
        clock.advance(step)
        result = limiter.acquire(key)
        [clock.now, result.allowed?, result.retry_after]
      end

      expect(timeline).to eq([
                               [0.0, true, 0.0], [10.0, true, 0.0], [20.0, true, 0.0],
                               [30.0, false, 30.0], [60.0, true, 0.0], [65.0, false, 5.0]
                             ])
    end

    it 'expires an entry exactly `window` seconds after it was logged' do
      use_up
      clock.advance(59.75)
      expect(limiter.acquire(key)).not_to be_allowed

      clock.advance(0.25)
      expect(limiter.acquire(key)).to be_allowed
    end

    it "prevents the fixed window's boundary burst" do
      burst_clock = FakeClock.new(59.5)
      burst = described_class.new(limit: 3, window: 60, clock: burst_clock)

      before_boundary = 3.times.count { burst.acquire(key).allowed? }
      burst_clock.advance(0.5)
      after_boundary = 3.times.count { burst.acquire(key).allowed? }

      expect(before_boundary + after_boundary).to eq(3)
    end

    it 'is exact: never over the limit in any window, never rejecting when there is room' do
      exact = described_class.new(limit: 5, window: 10, clock: clock)
      random = Random.new(7)
      events = Array.new(2_000) do
        clock.advance(random.rand(0..8) * 0.25)
        [clock.now, exact.acquire(key).allowed?]
      end

      admitted = events.select { |_time, allowed| allowed }.map(&:first)
      in_window = ->(time) { admitted.count { |t| t <= time && t + 10 > time } }

      over_limit = events.select { |time, allowed| allowed && in_window.call(time) > 5 }
      wrongly_rejected = events.select { |time, allowed| !allowed && in_window.call(time) < 5 }

      expect(over_limit).to be_empty
      expect(wrongly_rejected).to be_empty
      expect(admitted.size).to be_between(1, 1_999)
    end
  end

  describe 'request costs' do
    it 'logs one entry per unit of cost' do
      expect(limiter.acquire(key, cost: 2).remaining).to eq(1)
      expect(limiter.count(key)).to eq(2)
    end

    it 'waits until enough entries expire for the whole cost' do
      limiter.acquire(key)
      clock.advance(10)
      limiter.acquire(key)
      clock.advance(10)
      limiter.acquire(key)
      clock.advance(10)

      # Log [0, 10, 20] at t=30: cost 2 needs two entries gone, so wait for t=10 to expire.
      expect(limiter.acquire(key, cost: 2)).to have_attributes(allowed?: false, retry_after: 40.0)
    end
  end

  describe 'clock adjustments' do
    it 'keeps the log ordered when the clock moves backwards' do
      backwards_clock = FakeClock.new(10.0)
      ordered = described_class.new(limit: 3, window: 60, clock: backwards_clock)
      ordered.acquire(key)
      backwards_clock.advance(-5)
      ordered.acquire(key)

      backwards_clock.advance(64) # t = 69
      expect(ordered.count(key)).to eq(2)

      backwards_clock.advance(1) # t = 70: both entries were logged at 10
      expect(ordered.count(key)).to eq(0)
    end

    it 'uses the monotonic clock by default' do
      expect(described_class.new(limit: 1, window: 60).acquire(key)).to be_allowed
    end
  end

  describe 'memory' do
    it 'stores at most `limit` entries, however many requests are rejected' do
      10_000.times { limiter.acquire(key) }

      expect(limiter.count(key)).to eq(3)
    end

    it 'prunes logs whose entries have all expired' do
      100.times { |i| limiter.acquire("ip:#{i}") }
      clock.advance(30)
      limiter.acquire('ip:fresh')
      clock.advance(30)

      expect(limiter.prune).to eq(100)
      expect(limiter.tracked_keys).to eq(1)
    end

    it 'does not create a log when counting an unknown key' do
      expect(limiter.count('ip:unknown')).to eq(0)
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
