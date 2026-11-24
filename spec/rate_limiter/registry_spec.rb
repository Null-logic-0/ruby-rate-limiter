# frozen_string_literal: true

RSpec.describe RateLimiter::Registry do
  def config_for(algorithm, limit: 10, window: 20, clock: nil)
    RateLimiter::Configuration.new.tap do |config|
      config.algorithm = algorithm
      config.limit = limit
      config.window = window
      config.clock = clock
    end.validate!
  end

  it 'registers the six built-in algorithms' do
    expect(described_class.names).to include(
      :token_bucket, :leaky_bucket_meter, :leaky_bucket_queue,
      :fixed_window, :sliding_window_log, :sliding_window_counter
    )
  end

  it 'marks only the leaky bucket queue as a queue algorithm' do
    queues = described_class.names.select { |name| described_class.fetch(name).kind == :queue }

    expect(queues).to eq([:leaky_bucket_queue])
  end

  describe 'mapping `limit` per `window` onto each algorithm' do
    {
      token_bucket: [RateLimiter::Algorithms::TokenBucket, { capacity: 10, refill_rate: 0.5 }],
      leaky_bucket_meter: [RateLimiter::Algorithms::LeakyBucketMeter, { capacity: 10, leak_rate: 0.5 }],
      leaky_bucket_queue: [RateLimiter::Algorithms::LeakyBucketQueue, { capacity: 10, leak_rate: 0.5 }],
      fixed_window: [RateLimiter::Algorithms::FixedWindowCounter, { limit: 10, window: 20 }],
      sliding_window_log: [RateLimiter::Algorithms::SlidingWindowLog, { limit: 10, window: 20 }],
      sliding_window_counter: [RateLimiter::Algorithms::SlidingWindowCounter, { limit: 10, window: 20 }]
    }.each do |name, (klass, attributes)|
      it "builds #{name.inspect} with #{attributes}" do
        expect(described_class.build(config_for(name))).to be_a(klass).and have_attributes(attributes)
      end
    end
  end

  it 'passes a configured clock through to the algorithm' do
    clock = FakeClock.new
    limiter = described_class.build(config_for(:token_bucket, clock: clock))
    10.times { limiter.acquire('ip:203.0.113.7') }
    expect(limiter.acquire('ip:203.0.113.7')).not_to be_allowed

    clock.advance(2) # refills 0.5 tokens per second

    expect(limiter.acquire('ip:203.0.113.7')).to be_allowed
  end

  describe '.register' do
    after { described_class.unregister(:allow_all) }

    it 'adds a custom algorithm that the library can build' do
      allow_all = Class.new do
        attr_reader :limit

        def initialize(limit:)
          @limit = limit
        end

        def acquire(_key, cost: 1)
          RateLimiter::Result.new(allowed: true, remaining: @limit - cost, retry_after: 0.0, reset_after: 0.0)
        end
      end
      described_class.register(:allow_all) { |config| allow_all.new(limit: config.limit) }

      limiter = RateLimiter.limiter(config_for(:allow_all))

      expect(limiter.acquire('ip:203.0.113.7')).to be_allowed
    end

    it 'refuses to replace an existing algorithm' do
      expect { described_class.register(:token_bucket) { nil } }
        .to raise_error(RateLimiter::ConfigurationError, /already registered/)
    end

    it 'requires a builder block' do
      expect { described_class.register(:allow_all) }.to raise_error(ArgumentError, /builder/)
    end

    it 'rejects an unknown kind' do
      expect { described_class.register(:allow_all, kind: :later) { nil } }.to raise_error(ArgumentError, /kind/)
    end
  end

  describe '.fetch' do
    it 'raises a ConfigurationError that lists the available names' do
      expect { described_class.fetch(:nope) }
        .to raise_error(RateLimiter::ConfigurationError, /unknown algorithm :nope \(available: /)
    end
  end
end
