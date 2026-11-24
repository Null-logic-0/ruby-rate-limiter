# frozen_string_literal: true

require 'redis'

RSpec.describe RateGuard::RedisErrorReporter do
  subject(:reporter) { described_class.new(logger: logger, metrics: metrics, interval: 60, clock: clock) }

  let(:clock) { FakeClock.new(1_000.0) }
  let(:metrics) { RateGuard::Metrics::InMemory.new }
  let(:logged) { [] }
  let(:logger) { Struct.new(:lines) { def error(fields) = lines << fields }.new(logged) }
  let(:error) { Redis::CannotConnectError.new('Connection refused') }

  it 'logs the first failure at once' do
    reporter.call(error)

    expect(logged).to eq([{ event: 'redis_unavailable', action: 'allowing', error: 'Redis::CannotConnectError',
                            message: 'Connection refused', suppressed: 0 }])
  end

  it 'stays quiet for the rest of the interval, however many failures follow' do
    100.times do
      reporter.call(error)
      clock.advance(0.5) # 100 failures over 50 seconds
    end

    expect(logged.size).to eq(1)
  end

  it 'logs again once the interval has passed, saying how many failures it left out' do
    reporter.call(error)
    9.times { reporter.call(error) }
    clock.advance(60)

    reporter.call(error)

    expect(logged.map { |line| line[:suppressed] }).to eq([0, 9])
  end

  it 'counts every failure, logged or not' do
    10.times { reporter.call(error) }

    expect(metrics.count('rate_guard.redis_errors', error: 'Redis::CannotConnectError')).to eq(10)
  end

  it 'says it is rejecting when Redis failures fail closed' do
    described_class.new(logger: logger, failure_policy: :reject, clock: clock).call(error)

    expect(logged.first).to include(action: 'rejecting')
  end

  it 'logs exactly once when many threads fail at the same moment' do
    run_concurrently(threads: 20) { reporter.call(error) }

    expect(logged.size).to eq(1)
    expect(metrics.count('rate_guard.redis_errors')).to eq(20)
  end

  it 'only counts when no logger is given' do
    described_class.new(metrics: metrics, clock: clock).call(error)

    expect(metrics.count('rate_guard.redis_errors')).to eq(1)
  end
end
