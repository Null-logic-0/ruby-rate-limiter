# frozen_string_literal: true

RSpec.describe RateGuard::PolicySet do
  let(:clock) { FakeClock.new(600.0) }
  let(:env) { { 'REMOTE_ADDR' => '203.0.113.7' } }

  def counter(limit) = RateGuard::Algorithms::FixedWindowCounter.new(limit:, window: 60, clock:)
  def request(path = '/public') = RateGuard::Request.new(http_method: 'GET', path:, env:)

  let(:endpoint_limiter) { counter(5) }
  let(:global_limiter) { counter(20) }
  let(:endpoint) { RateGuard::Policy.new(name: 'public', paths: %w[/public], limiter: endpoint_limiter) }
  let(:global) do
    RateGuard::Policy.new(name: 'global', limiter: global_limiter, identifier: RateGuard::Identifiers::Global.new)
  end
  let(:set) { described_class.new([endpoint, global]) }

  it 'leaves requests no policy matches alone' do
    only_public = described_class.new([endpoint])

    expect(only_public.decide(request('/other'))).not_to be_matched
  end

  it 'admits a request only when every matching policy admits it' do
    decisions = Array.new(6) { set.decide(request) }

    expect(decisions.map(&:allowed?)).to eq([true] * 5 + [false])
    expect(decisions.last.reported.policy.name).to eq('public')
  end

  it 'stops at the first rejection, so later policies are not charged for it' do
    6.times { set.decide(request) }

    expect(global_limiter.count('global')).to eq(5)
  end

  it 'keeps earlier policies charged when a later one rejects' do
    strict_last = described_class.new([global, RateGuard::Policy.new(name: 'tiny', limiter: counter(1))])

    2.times { strict_last.decide(request) }

    expect(global_limiter.count('global')).to eq(2)
  end

  describe 'the reported policy' do
    it 'is the most restrictive one: fewest requests remaining' do
      expect(set.decide(request).reported.policy.name).to eq('public') # 4 left vs 19
    end

    it 'switches when another policy becomes more restrictive' do
      tight_global = RateGuard::Policy.new(name: 'global', limiter: counter(3),
                                             identifier: RateGuard::Identifiers::Global.new)

      expect(described_class.new([endpoint, tight_global]).decide(request).reported.policy.name).to eq('global')
    end

    it 'breaks a tie on remaining by the longer wait until reset' do
      resetting_in = lambda do |seconds|
        Struct.new(:limit) do
          define_method(:acquire) do |_key, **|
            RateGuard::Result.new(allowed: true, remaining: 2, retry_after: 0.0, reset_after: seconds)
          end
        end.new(10)
      end
      tied = described_class.new([RateGuard::Policy.new(name: 'soon', limiter: resetting_in.call(5.0)),
                                  RateGuard::Policy.new(name: 'late', limiter: resetting_in.call(50.0))])

      expect(tied.decide(request).reported.policy.name).to eq('late')
    end
  end

  describe 'bypass' do
    let(:set) { described_class.new([endpoint, global], bypass: ->(env) { env['REMOTE_ADDR'] == '10.0.0.1' }) }

    it 'skips every policy for trusted clients, charging nothing' do
      env['REMOTE_ADDR'] = '10.0.0.1'

      decisions = Array.new(10) { set.decide(request) }

      expect(decisions).to all(be_bypassed)
      expect(global_limiter.count('global')).to eq(0)
    end

    it 'limits everyone else as usual' do
      expect(set.decide(request)).to have_attributes(bypassed?: false, allowed?: true)
    end

    it 'is only consulted for requests some policy matches' do
      consulted = []
      only_public = described_class.new([endpoint], bypass: ->(env) { consulted << env && true })

      expect(only_public.decide(request('/other'))).not_to be_matched
      expect(consulted).to be_empty
    end
  end

  describe 'validation' do
    it 'needs at least one policy' do
      expect { described_class.new([]) }.to raise_error(ArgumentError, /at least one/)
    end

    it 'refuses things that are not policies' do
      expect { described_class.new([endpoint_limiter]) }.to raise_error(ArgumentError, /Policy objects/)
    end

    it 'refuses two policies with the same name' do
      expect { described_class.new([endpoint, endpoint]) }.to raise_error(ArgumentError, /unique.*public/)
    end

    it 'refuses a bypass that cannot be called' do
      expect { described_class.new([endpoint], bypass: true) }.to raise_error(ArgumentError, /bypass/)
    end
  end
end
