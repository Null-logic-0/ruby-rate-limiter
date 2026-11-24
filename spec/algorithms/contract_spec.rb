# frozen_string_literal: true

# Every immediate algorithm (one whose #acquire answers allow-or-reject right
# away) must keep the same promises, so the HTTP middleware can treat them all
# alike. Each is built by name, exactly as an application would build it:
# limit 10 per window of 10 seconds, on a clock frozen at t = 600.0.
RSpec.describe 'Immediate algorithm contract' do
  # Seconds until the consumer's limit has fully reset, after ONE request at 600.0.
  expected_reset_after = {
    token_bucket: 1.0,            # refills 10/10 = 1 token per second, and 1 token is missing
    leaky_bucket_meter: 1.0,      # leaks 10/10 = 1 unit per second, and holds 1 unit
    fixed_window_counter: 10.0,   # 600.0 starts a window (600 / 10 = 60), which ends at 610.0
    sliding_window_log: 10.0,     # the one entry, logged at 600.0, expires at 610.0
    sliding_window_counter: 20.0  # counted in window [600, 610), still weighted in [610, 620)
  }.freeze

  it 'covers every registered immediate algorithm' do
    immediate = RateLimiter::Registry.names.select do |name|
      RateLimiter::Registry.fetch(name).kind == :immediate
    end

    expect(expected_reset_after.keys).to match_array(immediate)
  end

  expected_reset_after.each do |algorithm, expected|
    describe algorithm.to_s do
      subject(:limiter) { RateLimiter::Registry.build(config) }

      let(:clock) { FakeClock.new(600.0) }
      let(:key) { 'ip:203.0.113.7' }
      let(:config) do
        RateLimiter::Configuration.new.tap do |settings|
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
    end
  end
end
