# frozen_string_literal: true

RSpec.describe RateLimiter do
  before { described_class.reset_configuration! }
  after { described_class.reset_configuration! }

  def configure(algorithm: :token_bucket, limit: 10, window: 10)
    described_class.configure do |config|
      config.algorithm = algorithm
      config.limit = limit
      config.window = window
    end
  end

  describe '.configure' do
    it 'stores a validated, frozen configuration' do
      configure(algorithm: :fixed_window_counter)

      expect(described_class.configuration).to have_attributes(algorithm: :fixed_window_counter, limit: 10, window: 10)
      expect(described_class.configuration).to be_frozen
    end

    it 'raises when asked for the configuration before configure is called' do
      expect { described_class.configuration }
        .to raise_error(RateLimiter::ConfigurationError, /configure has not been called/)
    end

    it 'keeps the previous configuration when the new one is invalid' do
      configure

      expect { configure(limit: 0) }.to raise_error(RateLimiter::ConfigurationError)
      expect(described_class.configuration.limit).to eq(10)
    end

    it 'prevents changing the configuration afterwards' do
      configure

      expect { described_class.configuration.limit = 99 }.to raise_error(FrozenError)
    end
  end

  describe '.limiter' do
    it 'builds the configured algorithm' do
      configure

      expect(described_class.limiter)
        .to be_a(RateLimiter::Algorithms::TokenBucket).and have_attributes(capacity: 10, refill_rate: 1.0)
    end

    it 'builds a new limiter, with empty state, on every call' do
      configure

      expect(described_class.limiter).not_to equal(described_class.limiter)
    end

    it 'refuses a queue algorithm and points to .queue' do
      configure(algorithm: :leaky_bucket_queue)

      expect { described_class.limiter }.to raise_error(RateLimiter::ConfigurationError, /RateLimiter\.queue/)
    end

    it 'accepts an explicit configuration instead of the global one' do
      config = RateLimiter::Configuration.new
      config.algorithm = :sliding_window_log
      config.limit = 5
      config.window = 30

      expect(described_class.limiter(config)).to be_a(RateLimiter::Algorithms::SlidingWindowLog)
      expect { described_class.configuration }.to raise_error(RateLimiter::ConfigurationError)
    end
  end

  describe '.queue' do
    it 'builds the queue algorithm' do
      configure(algorithm: :leaky_bucket_queue, window: 20)

      expect(described_class.queue)
        .to be_a(RateLimiter::Algorithms::LeakyBucketQueue).and have_attributes(capacity: 10, leak_rate: 0.5)
    end

    it 'refuses an immediate algorithm and points to .limiter' do
      configure

      expect { described_class.queue }.to raise_error(RateLimiter::ConfigurationError, /RateLimiter\.limiter/)
    end
  end
end
