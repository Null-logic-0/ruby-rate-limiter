# frozen_string_literal: true

RSpec.describe RateLimiter::Validators::CostValidator do
  def validate(cost, maximum: 10, type: :integer, **options)
    described_class.validate!(cost: cost, maximum: maximum, type: type, **options)
  end

  describe ':integer costs' do
    [1, 5, 10].each do |cost|
      it "accepts #{cost} when the maximum is 10" do
        expect { validate(cost) }.not_to raise_error
      end
    end

    [0, -1, 2.0, 1.5, '1', nil].each do |cost|
      it "rejects #{cost.inspect}" do
        expect { validate(cost) }.to raise_error(ArgumentError, 'cost must be a positive integer')
      end
    end
  end

  describe ':number costs' do
    [1, 0.25, 2.5, Rational(1, 2), 10.0].each do |cost|
      it "accepts #{cost.inspect} when the maximum is 10" do
        expect { validate(cost, type: :number) }.not_to raise_error
      end
    end

    [0, -0.5, Float::INFINITY, Float::NAN, Complex(1, 0), '1', nil].each do |cost|
      it "rejects #{cost.inspect}" do
        expect { validate(cost, type: :number) }.to raise_error(ArgumentError, 'cost must be a positive number')
      end
    end
  end

  describe 'maximum' do
    it 'accepts a cost equal to the maximum' do
      expect { validate(10) }.not_to raise_error
    end

    it 'rejects a cost above the maximum, naming it "limit" by default' do
      expect { validate(11) }.to raise_error(ArgumentError, 'cost 11 exceeds limit 10')
    end

    it 'uses the given maximum_name in the error' do
      expect { validate(11, maximum_name: 'capacity') }
        .to raise_error(ArgumentError, 'cost 11 exceeds capacity 10')
    end

    it 'compares fractional costs against the maximum' do
      expect { validate(10.5, type: :number) }.to raise_error(ArgumentError, 'cost 10.5 exceeds limit 10')
    end

    it 'checks the type before comparing, so a bad cost never reaches the comparison' do
      expect { validate('11') }.to raise_error(ArgumentError, 'cost must be a positive integer')
    end
  end

  it 'rejects an unknown cost type' do
    expect { validate(1, type: :string) }.to raise_error(ArgumentError, 'Unknown cost type: string')
  end
end
