# frozen_string_literal: true

RSpec.describe RateGuard::Tiers do
  let(:free) { Object.new }
  let(:premium) { Object.new }
  let(:tiers) { described_class.new(free: free, premium: premium) { |key, env| env.fetch(:plans)[key] } }

  it 'picks the limiter for the tier the block names' do
    expect(tiers.select('user:1', plans: { 'user:1' => :premium })).to equal(premium)
  end

  it 'falls back to the first tier when the block returns an unknown or nil tier' do
    expect(tiers.select('user:2', plans: { 'user:2' => :gold })).to equal(free)
    expect(tiers.select('user:3', plans: {})).to equal(free)
  end

  it 'lists its limiters' do
    expect(tiers.limiters).to eq([free, premium])
  end

  it 'needs at least one tier' do
    expect { described_class.new({}) { :free } }.to raise_error(ArgumentError, /at least one tier/)
  end

  it 'needs a block that picks the tier' do
    expect { described_class.new(free: free) }.to raise_error(ArgumentError, /block/)
  end
end
