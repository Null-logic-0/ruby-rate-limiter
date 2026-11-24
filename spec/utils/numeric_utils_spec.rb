# frozen_string_literal: true

RSpec.describe RateGuard::Utils::NumericUtils do
  describe '.positive_number?' do
    [1, 0.5, 1e-9, Rational(1, 3), 2**64, Float::MAX].each do |value|
      it "is true for #{value.inspect}" do
        expect(described_class.positive_number?(value)).to be(true)
      end
    end

    it 'is false for zero, in any numeric type' do
      expect([0, 0.0, -0.0, Rational(0, 1)].map { |zero| described_class.positive_number?(zero) })
        .to all(be(false))
    end

    [-1, -0.5, -Float::INFINITY].each do |value|
      it "is false for the negative #{value.inspect}" do
        expect(described_class.positive_number?(value)).to be(false)
      end
    end

    it 'is false for infinity and NaN, which are not usable rates' do
      expect(described_class.positive_number?(Float::INFINITY)).to be(false)
      expect(described_class.positive_number?(Float::NAN)).to be(false)
    end

    it 'is false for a complex number, even one with no imaginary part' do
      expect(described_class.positive_number?(Complex(1, 0))).to be(false)
    end

    ['1', nil, true, :one, [1]].each do |value|
      it "is false for the non-number #{value.inspect}" do
        expect(described_class.positive_number?(value)).to be(false)
      end
    end
  end

  describe '.positive_integer?' do
    [1, 42, 2**64].each do |value|
      it "is true for #{value}" do
        expect(described_class.positive_integer?(value)).to be(true)
      end
    end

    [0, -1, -(2**64)].each do |value|
      it "is false for #{value}" do
        expect(described_class.positive_integer?(value)).to be(false)
      end
    end

    [1.0, 2.5, Rational(2, 1), Float::INFINITY].each do |value|
      it "is false for the non-Integer #{value.inspect}, even if it looks whole" do
        expect(described_class.positive_integer?(value)).to be(false)
      end
    end

    ['1', nil, true].each do |value|
      it "is false for the non-number #{value.inspect}" do
        expect(described_class.positive_integer?(value)).to be(false)
      end
    end
  end

  it 'can be called on the module or mixed into a class' do
    host = Class.new { include RateGuard::Utils::NumericUtils }.new

    expect(host.send(:positive_number?, 2)).to be(true)
    expect(described_class.positive_integer?(2)).to be(true)
  end
end
