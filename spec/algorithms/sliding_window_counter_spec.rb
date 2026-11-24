# frozen_string_literal: true

RSpec.describe RateLimiter::Algorithms::SlidingWindowCounter do
  subject(:limiter) { described_class.new(limit: 10, window: 60, clock: clock) }

  # 600 s is the start of a window (600-659); 660 starts the next one.
  let(:clock) { FakeClock.new(600.0) }
  let(:key) { 'ip:203.0.113.7' }

  # Runs a limiter against seeded random traffic averaging `per_minute`.
  # Returns how many requests it admitted and the most within any 60 s span.
  def simulate(limiter_class, limit:, per_minute:, minutes: 120, seed: 1)
    sim_clock = FakeClock.new(0.0)
    sim = limiter_class.new(limit: limit, window: 60, clock: sim_clock)
    random = Random.new(seed)
    max_step = (120.0 / per_minute / 0.25).round
    live = []
    admitted = 0
    busiest = 0

    until sim_clock.now >= minutes * 60
      sim_clock.advance(random.rand(0..max_step) * 0.25)
      live.shift while live.any? && live.first + 60 <= sim_clock.now
      next unless sim.acquire(key).allowed?

      admitted += 1
      live << sim_clock.now
      busiest = [busiest, live.size].max
    end

    [admitted, busiest]
  end

  describe 'weighting' do
    it 'follows the worked example' do
      8.times { limiter.acquire(key) }
      clock.advance(75) # 675: 15 s (25%) into the window 660-719
      3.times { limiter.acquire(key) }

      expect(limiter.estimate(key)).to eq(9.0)
      expect(limiter.acquire(key)).to have_attributes(allowed?: true, remaining: 0)
      expect(limiter.acquire(key)).to have_attributes(allowed?: false, remaining: 0, retry_after: 7.5)

      clock.advance(7.5)
      expect(limiter.acquire(key)).to be_allowed
    end

    it 'weights the previous window by the unelapsed fraction' do
      large = described_class.new(limit: 100, window: 60, clock: clock)
      50.times { large.acquire(key) }
      clock.advance(84) # 684: 40% into the next window
      20.times { large.acquire(key) }

      expect(large.estimate(key)).to be_within(1e-9).of(50.0) # 20 + 50 × 0.6
    end

    it "decays the previous window's count linearly" do
      8.times { limiter.acquire(key) }

      estimates = [60, 30, 30].map do |step|
        clock.advance(step)
        limiter.estimate(key)
      end

      expect(estimates).to eq([8.0, 4.0, 0.0])
    end
  end

  describe 'counting' do
    it 'allows `limit` requests in a fresh window, then rejects' do
      outcomes = Array.new(11) { limiter.acquire(key).allowed? }

      expect(outcomes).to eq([true] * 10 + [false])
    end

    it 'reports the requests remaining' do
      remaining = Array.new(3) { limiter.acquire(key).remaining }

      expect(remaining).to eq([9, 8, 7])
    end

    it 'keeps separate counters per key' do
      10.times { limiter.acquire('ip:198.51.100.1') }

      expect(limiter.acquire('ip:198.51.100.2')).to be_allowed
      expect(limiter.acquire('ip:198.51.100.1')).not_to be_allowed
    end
  end

  describe 'window transitions' do
    it 'turns the current count into the previous count when a window ends' do
      5.times { limiter.acquire(key) }
      clock.advance(60)

      expect(limiter.estimate(key)).to eq(5.0)
    end

    it 'forgets both counts when a whole window is skipped' do
      5.times { limiter.acquire(key) }
      clock.advance(120)

      expect(limiter.estimate(key)).to eq(0.0)
    end
  end

  describe 'boundary behaviour' do
    let(:clock) { FakeClock.new(659.5) }

    it "blocks the fixed window's boundary burst" do
      before_boundary = 10.times.count { limiter.acquire(key).allowed? }
      clock.advance(0.5) # 660.0: the previous window still has full weight
      after_boundary = 10.times.count { limiter.acquire(key).allowed? }

      expect([before_boundary, after_boundary]).to eq([10, 0])
    end

    it "admits more as the previous window's weight decays" do
      10.times { limiter.acquire(key) }
      clock.advance(30.5) # 690: halfway through the next window

      expect(10.times.count { limiter.acquire(key).allowed? }).to eq(5)
    end
  end

  describe 'retry and reset' do
    it 'waits into the next window when the current window alone is full' do
      10.times { limiter.acquire(key) }

      expect(limiter.acquire(key).retry_after).to be_within(1e-9).of(66.0)

      clock.advance(66) # 666: 10 × 0.9 = 9, so one more fits
      expect(limiter.acquire(key)).to be_allowed
    end

    it 'reports when both counters will have aged out' do
      late = described_class.new(limit: 10, window: 60, clock: FakeClock.new(615.0))

      expect(late.acquire(key).reset_after).to eq(105.0) # 600 + 120 − 615
    end
  end

  describe 'request costs' do
    it 'counts `cost` requests' do
      expect(limiter.acquire(key, cost: 3).remaining).to eq(7)
    end

    it 'rejects a cost that does not fit, without counting it' do
      limiter.acquire(key, cost: 9)

      expect(limiter.acquire(key, cost: 2)).to have_attributes(allowed?: false, remaining: 1)
      expect(limiter.estimate(key)).to eq(9.0)
    end
  end

  describe 'clock adjustments' do
    it 'keeps counting in the current window when the clock moves backwards' do
      10.times { limiter.acquire(key) }
      clock.advance(-30)

      expect(limiter.acquire(key)).not_to be_allowed
      expect(limiter.estimate(key)).to eq(10.0)
    end

    it 'uses the wall clock by default' do
      result = described_class.new(limit: 1, window: 60).acquire(key)

      expect(result).to be_allowed
      expect(result.reset_after).to be_between(60, 120)
    end
  end

  describe 'accuracy against the exact log' do
    let(:log_class) { RateLimiter::Algorithms::SlidingWindowLog }

    it 'matches the log exactly when traffic stays under the limit' do
      counter = simulate(described_class, limit: 100, per_minute: 50)
      log = simulate(log_class, limit: 100, per_minute: 50)

      expect(counter).to eq(log)
    end

    it 'stays within a few percent of the log under sustained overload' do
      counter_admitted, counter_peak = simulate(described_class, limit: 100, per_minute: 200)
      log_admitted, = simulate(log_class, limit: 100, per_minute: 200)

      expect(counter_admitted).to be_within(log_admitted * 0.02).of(log_admitted)
      expect(counter_peak).to be <= 110
    end

    it 'can be pushed toward twice the limit by a burst timed at a boundary' do
      adversary_clock = FakeClock.new(659.75)
      adversary = described_class.new(limit: 10, window: 60, clock: adversary_clock)

      admitted = 10.times.count { adversary.acquire(key).allowed? }
      238.times do
        adversary_clock.advance(0.25) # steady requests until 719.25
        admitted += 1 if adversary.acquire(key).allowed?
      end

      # All of these fall within one 60-second span (659.75 .. 719.25).
      expect(admitted).to eq(19)
      expect(admitted).to be < 2 * 10
    end
  end

  describe 'memory' do
    it 'prunes consumers whose counters have both aged out' do
      100.times { |i| limiter.acquire("ip:#{i}") }
      clock.advance(60)
      limiter.acquire('ip:fresh')
      clock.advance(60)

      expect(limiter.prune).to eq(100)
      expect(limiter.tracked_keys).to eq(1)
    end

    it 'does not store anything when estimating an unknown key' do
      expect(limiter.estimate('ip:unknown')).to eq(0.0)
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
        expect { described_class.new(limit: 10, window: window) }.to raise_error(ArgumentError, /window/)
      end
    end

    [0, -1, 1.5].each do |cost|
      it "rejects cost #{cost}" do
        expect { limiter.acquire(key, cost: cost) }.to raise_error(ArgumentError, /cost/)
      end
    end

    it 'rejects a cost that exceeds the limit' do
      expect { limiter.acquire(key, cost: 11) }.to raise_error(ArgumentError, /exceeds limit/)
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
      expect(shared.estimate(key)).to eq(100.0)
    end
  end
end
