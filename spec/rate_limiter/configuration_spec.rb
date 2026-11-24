# frozen_string_literal: true

RSpec.describe RateLimiter::Configuration do
  subject(:config) { described_class.new }

  def fill_in(algorithm: :token_bucket, limit: 10, window: 60)
    config.algorithm = algorithm
    config.limit = limit
    config.window = window
    config
  end

  it 'defaults to the token bucket' do
    expect(config.algorithm).to eq(:token_bucket)
  end

  it 'accepts algorithm names as strings' do
    config.algorithm = 'fixed_window_counter'

    expect(config.algorithm).to eq(:fixed_window_counter)
  end

  it 'returns itself when valid' do
    expect(fill_in.validate!).to equal(config)
  end

  describe 'validation' do
    it 'rejects an unknown algorithm and lists the available ones' do
      fill_in(algorithm: :nope)

      expect { config.validate! }
        .to raise_error(RateLimiter::ConfigurationError, /:nope is not registered \(available: :token_bucket/)
    end

    [0, -1, 2.5, nil, '10'].each do |limit|
      it "rejects limit #{limit.inspect}" do
        fill_in(limit: limit)

        expect { config.validate! }.to raise_error(RateLimiter::ConfigurationError, /limit must be a positive integer/)
      end
    end

    [0, -1, nil, Float::INFINITY].each do |window|
      it "rejects window #{window.inspect}" do
        fill_in(window: window)

        expect { config.validate! }.to raise_error(RateLimiter::ConfigurationError, /window must be a positive number/)
      end
    end

    it 'rejects a clock without #now' do
      fill_in.clock = Object.new

      expect { config.validate! }.to raise_error(RateLimiter::ConfigurationError, /clock must respond to #now/)
    end

    it 'reports every problem at once' do
      fill_in(algorithm: :nope, limit: 0, window: nil)

      expect { config.validate! }
        .to raise_error(RateLimiter::ConfigurationError, /algorithm .* limit .* window/)
    end
  end
end
