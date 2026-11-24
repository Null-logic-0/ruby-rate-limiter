# frozen_string_literal: true

RSpec.describe RateLimiter::Validators::ConfigurationValidator do
  def validate(**attributes)
    described_class.validate!(**attributes)
  end

  describe ':integer' do
    [1, 10, 2**64].each do |value|
      it "accepts #{value}" do
        expect { validate(capacity: [value, :integer]) }.not_to raise_error
      end
    end

    [0, -1, 2.0, 1.5, Rational(3, 1), '10', nil, Float::INFINITY].each do |value|
      it "rejects #{value.inspect}" do
        expect { validate(capacity: [value, :integer]) }
          .to raise_error(ArgumentError, 'capacity must be a positive integer')
      end
    end
  end

  describe ':number' do
    [1, 0.5, 1e-9, Rational(1, 3), 2**64].each do |value|
      it "accepts #{value.inspect}" do
        expect { validate(rate: [value, :number]) }.not_to raise_error
      end
    end

    [0, 0.0, -0.5, Float::INFINITY, -Float::INFINITY, Float::NAN, Complex(1, 0), '1', nil].each do |value|
      it "rejects #{value.inspect}" do
        expect { validate(rate: [value, :number]) }
          .to raise_error(ArgumentError, 'rate must be a positive number')
      end
    end
  end

  it 'accepts several valid attributes at once' do
    expect { validate(limit: [60, :integer], window: [0.5, :number]) }.not_to raise_error
  end

  it 'names the first invalid attribute in the error' do
    expect { validate(limit: [60, :integer], window: [0, :number], extra: [0, :integer]) }
      .to raise_error(ArgumentError, 'window must be a positive number')
  end

  it 'does nothing when given no attributes' do
    expect { validate }.not_to raise_error
  end

  it 'rejects an unknown validation type, even for a valid value' do
    expect { validate(limit: [60, :string]) }
      .to raise_error(ArgumentError, 'Unknown validation type: string')
  end
end
