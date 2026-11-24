# frozen_string_literal: true

# Every immediate algorithm must behave the same way, so the middleware
# can use any of them. Limit 10 per 10 s, clock frozen at 600.0.
RSpec.describe 'Immediate algorithm contract' do
  # Seconds until fully reset after one request at 600.0.
  expected_reset_after = {
    token_bucket: 1.0,            # refills 10/10 = 1 token per second, and 1 token is missing
    leaky_bucket_meter: 1.0,      # leaks 10/10 = 1 unit per second, and holds 1 unit
    fixed_window: 10.0,           # 600.0 starts a window (600 / 10 = 60), which ends at 610.0
    sliding_window_log: 10.0,     # the one entry, logged at 600.0, expires at 610.0
    sliding_window_counter: 20.0  # counted in window [600, 610), still weighted in [610, 620)
  }.freeze

  it 'covers every registered immediate algorithm' do
    immediate = RateGuard::Registry.names.select do |name|
      RateGuard::Registry.fetch(name).kind == :immediate
    end

    expect(expected_reset_after.keys).to match_array(immediate)
  end

  expected_reset_after.each do |algorithm, expected|
    describe algorithm.to_s do
      subject(:limiter) { RateGuard::Registry.build(config) }

      let(:clock) { FakeClock.new(600.0) }
      let(:key) { 'ip:203.0.113.7' }
      let(:config) do
        RateGuard::Configuration.new.tap do |settings|
          settings.algorithm = algorithm
          settings.limit = 10
          settings.window = 10
          settings.clock = clock
        end
      end

      it 'reports its limit' do
        expect(limiter.limit).to eq(10)
      end

      it "reports reset_after #{expected} after one request" do
        result = limiter.acquire(key)

        expect(result).to be_allowed
        expect(result.reset_after).to eq(expected)
      end

      it 'reports a non-negative Float reset_after on every result, allowed or rejected' do
        results = Array.new(12) { limiter.acquire(key) }

        expect(results.map(&:allowed?)).to eq([true] * 10 + [false] * 2)
        expect(results.map(&:reset_after)).to all(be_a(Float).and(be >= 0))
      end

      describe 'reserve:' do
        it 'admits a request only while cost + reserve units are available' do
          statuses = Array.new(8) { limiter.acquire(key, reserve: 3).allowed? }

          expect(statuses).to eq([true] * 7 + [false])
        end

        it 'leaves the reserved units to requests without a reserve' do
          7.times { limiter.acquire(key, reserve: 3) }

          expect(Array.new(4) { limiter.acquire(key).allowed? }).to eq([true, true, true, false])
        end

        it 'spends only the cost, and reports a positive retry_after when it rejects' do
          results = Array.new(8) { limiter.acquire(key, reserve: 3) }

          expect(results[6].remaining).to eq(3)
          expect(results[7]).to have_attributes(allowed?: false, remaining: 3)
          expect(results[7].retry_after).to be > 0
        end

        it 'refuses a reserve that leaves no room for the cost' do
          expect { limiter.acquire(key, cost: 2, reserve: 9) }.to raise_error(ArgumentError, /plus reserve 9 exceeds/)
        end
      end
    end
  end
end
