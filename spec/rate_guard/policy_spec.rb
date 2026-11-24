# frozen_string_literal: true

RSpec.describe RateGuard::Policy do
  let(:clock) { FakeClock.new(600.0) }
  let(:limiter) { RateGuard::Algorithms::FixedWindowCounter.new(limit: 10, window: 60, clock: clock) }

  def request(http_method: 'GET', path: '/public', **env)
    env = { 'REMOTE_ADDR' => '203.0.113.7' }.merge(env.transform_keys(&:to_s))
    RateGuard::Request.new(http_method:, path:, env:)
  end

  def policy(**options) = described_class.new(name: 'public', limiter: limiter, **options)

  describe 'matching' do
    it 'matches the given methods and paths' do
      login = policy(methods: %w[post], paths: %w[/login])

      expect(login.matches?(request(http_method: 'POST', path: '/login'))).to be(true)
      expect(login.matches?(request(http_method: 'GET', path: '/login'))).to be(false)
      expect(login.matches?(request(http_method: 'POST', path: '/logout'))).to be(false)
    end

    it 'matches every method and path when none are given' do
      expect(policy.matches?(request(http_method: 'DELETE', path: '/anything'))).to be(true)
    end

    it 'accepts a custom matcher' do
      api = policy(match: ->(req) { req.path.start_with?('/api/') })

      expect(api.matches?(request(path: '/api/users'))).to be(true)
      expect(api.matches?(request(path: '/health'))).to be(false)
    end

    it 'refuses a custom matcher together with methods or paths' do
      expect { policy(match: ->(_req) { true }, paths: %w[/x]) }.to raise_error(ArgumentError, /not both/)
    end

    ['/login/', '//login', 'login', '/a/../login', '/%6Cogin'].each do |path|
      it "refuses #{path.inspect}, which a normalized request path can never equal" do
        expect { policy(paths: [path]) }.to raise_error(ArgumentError, /normalized/)
      end
    end
  end

  describe 'applying' do
    it 'counts the request against the identified consumer' do
      outcome = policy.apply(request)

      expect(outcome).to have_attributes(allowed?: true, key: 'ip:203.0.113.7', limit: 10, cost: 1)
      expect(limiter.count('ip:203.0.113.7')).to eq(1)
    end

    it 'counts unidentified requests against one shared "anonymous" key' do
      outcome = policy(identifier: ->(_env) {}).apply(request)

      expect(outcome.key).to eq('anonymous')
    end

    it 'charges a fixed cost' do
      expect(policy(cost: 3).apply(request).result.remaining).to eq(7)
    end

    it 'charges a cost computed from the env' do
      by_size = ->(env) { env['CONTENT_LENGTH'].to_i > 1000 ? 4 : 1 }

      expect(policy(cost: by_size).apply(request(CONTENT_LENGTH: '5000')).cost).to eq(4)
    end

    it 'caps the cost at the limit, so an oversized request costs everything instead of raising' do
      outcome = policy(cost: ->(_env) { 50 }).apply(request)

      expect(outcome).to have_attributes(cost: 10, allowed?: true)
      expect(outcome.result.remaining).to eq(0)
    end
  end

  describe 'tiers' do
    let(:free) { RateGuard::Algorithms::FixedWindowCounter.new(limit: 2, window: 60, clock: clock) }
    let(:premium) { RateGuard::Algorithms::FixedWindowCounter.new(limit: 50, window: 60, clock: clock) }
    let(:tiered) do
      tiers = RateGuard::Tiers.new(free: free, premium: premium) { |key, _env| key == 'user:1' ? :premium : :free }
      described_class.new(name: 'api', limiter: tiers, identifier: ->(env) { "user:#{env['user']}" })
    end

    it "uses the limiter for the consumer's tier" do
      expect(tiered.apply(request(user: 1)).limit).to eq(50)
      expect(tiered.apply(request(user: 2)).limit).to eq(2)
    end

    it 'keeps tiers apart: a free user running out does not affect premium' do
      3.times { tiered.apply(request(user: 2)) }

      expect(tiered.apply(request(user: 2))).not_to be_allowed
      expect(tiered.apply(request(user: 1))).to be_allowed
    end
  end

  describe 'priority and reserve' do
    let(:prioritized) do
      policy(priority: ->(env) { env['priority'] == 'low' ? :low : :high }, reserve: 3)
    end

    it 'stops low-priority requests while fewer than the reserve would remain' do
      statuses = Array.new(8) { prioritized.apply(request(priority: 'low')).allowed? }

      expect(statuses).to eq([true] * 7 + [false])
    end

    it 'keeps the reserved requests for high priority' do
      7.times { prioritized.apply(request(priority: 'low')) }

      expect(Array.new(4) { prioritized.apply(request).allowed? }).to eq([true, true, true, false])
    end

    it 'treats everything as high priority without a priority callable' do
      expect(Array.new(10) { policy(reserve: 3).apply(request).allowed? }).to all(be(true))
    end

    it 'refuses a priority callable that returns something else' do
      odd = policy(priority: ->(_env) { :urgent }, reserve: 3)

      expect { odd.apply(request) }.to raise_error(ArgumentError, /priority must return/)
    end
  end

  describe 'validation' do
    it 'refuses a queue algorithm' do
      queue = RateGuard::Algorithms::LeakyBucketQueue.new(capacity: 2, leak_rate: 1)

      expect { described_class.new(name: 'q', limiter: queue) }.to raise_error(ArgumentError, /queue algorithms/)
    end

    it 'refuses a reserve that is not below the limit' do
      expect { policy(reserve: 10) }.to raise_error(ArgumentError, /reserve must be below the limit/)
    end

    it 'refuses a cost that is neither a positive Integer nor callable' do
      expect { policy(cost: 0) }.to raise_error(ArgumentError, /cost must be a positive Integer/)
    end

    it 'refuses an identifier that cannot be called' do
      expect { policy(identifier: 'ip') }.to raise_error(ArgumentError, /identifier must respond to #call/)
    end
  end
end
