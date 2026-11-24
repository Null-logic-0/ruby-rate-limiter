# frozen_string_literal: true

RSpec.describe RateGuard::Metrics do
  describe RateGuard::Metrics::Null do
    it 'accepts every call and reports nothing' do
      metrics = described_class.new

      expect(metrics.increment('rate_guard.allowed', policy: 'x')).to be_nil
      expect(metrics.timing('rate_guard.decision', 0.001)).to be_nil
    end
  end

  describe RateGuard::Metrics::InMemory do
    subject(:metrics) { described_class.new }

    it 'counts by name, optionally narrowed by tags' do
      2.times { metrics.increment('rate_guard.rejected', policy: 'login', algorithm: 'token_bucket') }
      metrics.increment('rate_guard.rejected', policy: 'public', algorithm: 'token_bucket')

      expect(metrics.count('rate_guard.rejected')).to eq(3)
      expect(metrics.count('rate_guard.rejected', policy: 'login')).to eq(2)
      expect(metrics.count('rate_guard.rejected', policy: 'upload')).to eq(0)
      expect(metrics.count('rate_guard.allowed')).to eq(0)
    end

    it 'records timings' do
      metrics.timing('rate_guard.decision', 0.002, policy: 'login')
      metrics.timing('rate_guard.decision', 0.004, policy: 'public')

      expect(metrics.timings('rate_guard.decision')).to contain_exactly(0.002, 0.004)
      expect(metrics.timings('rate_guard.decision', policy: 'login')).to eq([0.002])
    end

    it 'loses no increments when many threads count at once' do
      run_concurrently(threads: 20) { 100.times { metrics.increment('rate_guard.allowed') } }

      expect(metrics.count('rate_guard.allowed')).to eq(2000)
    end
  end
end
