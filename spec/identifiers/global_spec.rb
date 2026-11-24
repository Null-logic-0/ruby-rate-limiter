# frozen_string_literal: true

require 'rate_limiter/identifiers'

RSpec.describe RateLimiter::Identifiers::Global do
  it 'gives every request the same key' do
    keys = [{ 'REMOTE_ADDR' => '203.0.113.7' }, {}].map { |env| described_class.new.call(env) }

    expect(keys).to eq(%w[global global])
  end

  it 'can use another key' do
    expect(described_class.new('global:api').call({})).to eq('global:api')
  end
end
