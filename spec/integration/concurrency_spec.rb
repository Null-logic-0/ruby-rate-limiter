# frozen_string_literal: true

require 'rate_guard/middleware'
require_relative '../../app/api'

# Many threads through the full stack at once, like Puma.
RSpec.describe 'Concurrent requests through the HTTP stack' do
  registry = RateGuard::Registry
  immediate = registry.names.select { |name| registry.fetch(name).kind == :immediate }

  # 10 requests per minute, frozen clock: nothing refills.
  def build_stack(algorithm)
    config = RateGuard::Configuration.new.tap do |c|
      c.algorithm = algorithm
      c.limit = 10
      c.window = 60
      c.clock = FakeClock.new(600.0)
    end
    limiter = RateGuard.limiter(config)

    Rack::Builder.new do
      use RateGuard::Middleware, limiter: limiter, paths: ['/limited']
      run Api
    end.to_app
  end

  def get(stack, path, ip = '203.0.113.7')
    Rack::MockRequest.new(stack).get(path, 'REMOTE_ADDR' => ip)
  end

  immediate.each do |algorithm|
    describe algorithm.inspect do
      it 'admits exactly the limit when 50 requests arrive at once' do
        stack = build_stack(algorithm)

        statuses = run_concurrently(threads: 50) { get(stack, '/limited').status }

        expect(statuses.tally).to eq(200 => 10, 429 => 40)
      end

      it 'hands out each remaining count exactly once' do
        stack = build_stack(algorithm)

        responses = run_concurrently(threads: 50) { get(stack, '/limited') }
        remaining = responses.select(&:ok?).map { |response| response.headers['ratelimit-remaining'] }

        expect(remaining).to match_array(%w[9 8 7 6 5 4 3 2 1 0])
      end

      it 'limits 10 concurrent clients independently' do
        stack = build_stack(algorithm)
        ips = Array.new(10) { |i| "198.51.100.#{i + 1}" }

        outcomes = run_concurrently(threads: 200) do |index|
          ip = ips[index % ips.size]
          [ip, get(stack, '/limited', ip).status]
        end
        admitted = outcomes.select { |_ip, status| status == 200 }.map(&:first).tally

        expect(admitted).to eq(ips.to_h { |ip| [ip, 10] })
      end
    end
  end

  it 'never limits /unlimited, however many requests arrive at once' do
    stack = build_stack(:token_bucket)

    statuses = run_concurrently(threads: 50) { get(stack, '/unlimited').status }

    expect(statuses.uniq).to eq([200])
  end
end
