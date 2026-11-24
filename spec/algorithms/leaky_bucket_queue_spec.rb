# frozen_string_literal: true

RSpec.describe RateLimiter::Algorithms::LeakyBucketQueue do
  subject(:queue) { described_class.new(capacity: 3, leak_rate: 2, clock: clock) }

  let(:clock) { FakeClock.new }
  let(:key) { 'ip:203.0.113.7' }

  def fill(limiter = queue, consumer = key)
    Array.new(limiter.capacity) { |i| limiter.enqueue(consumer, "job-#{i + 1}") }
  end

  describe '#enqueue' do
    it 'accepts items while there is room' do
      admissions = fill

      expect(admissions.map(&:accepted?)).to eq([true, true, true])
      expect(admissions.map(&:position)).to eq([1, 2, 3])
    end

    it "estimates each item's wait from its position" do
      expect(fill.map(&:wait)).to eq([0.0, 0.5, 1.0])
    end

    it 'rejects items when the queue is full' do
      fill

      expect(queue.enqueue(key, 'job-4')).to have_attributes(accepted?: false, position: nil, wait: nil)
      expect(queue.size(key)).to eq(3)
    end

    it 'follows the worked example' do
      fill
      queue.dequeue(key)
      clock.advance(0.2)

      accepted = queue.enqueue(key, 'job-4')
      expect(accepted).to have_attributes(accepted?: true, position: 3)
      expect(accepted.wait).to be_within(1e-9).of(1.3)

      rejected = queue.enqueue(key, 'job-5')
      expect(rejected).not_to be_accepted
      expect(rejected.retry_after).to be_within(1e-9).of(0.3)
    end

    it 'rejects nil items' do
      expect { queue.enqueue(key, nil) }.to raise_error(ArgumentError, /nil/)
    end
  end

  describe '#dequeue' do
    it 'releases the first item immediately' do
      fill

      expect(queue.dequeue(key)).to eq('job-1')
    end

    it 'releases at most one item per interval' do
      fill
      queue.dequeue(key)

      expect(queue.dequeue(key)).to be_nil
      clock.advance(0.25)
      expect(queue.dequeue(key)).to be_nil
      clock.advance(0.25)
      expect(queue.dequeue(key)).to eq('job-2')
    end

    it 'releases items in FIFO order' do
      fill

      released = Array.new(3) do
        item = queue.dequeue(key)
        clock.advance(0.5)
        item
      end

      expect(released).to eq(%w[job-1 job-2 job-3])
    end

    it 'returns nil when the queue is empty' do
      expect(queue.dequeue(key)).to be_nil
    end

    it 'does not let idle time build up a burst' do
      fill
      clock.advance(100)

      expect(queue.dequeue(key)).to eq('job-1')
      expect(queue.dequeue(key)).to be_nil
    end

    it 'frees a place for a new item' do
      fill
      queue.dequeue(key)

      expect(queue.enqueue(key, 'job-4')).to be_accepted
    end
  end

  describe '#next_release_in' do
    it 'is nil for an empty queue' do
      expect(queue.next_release_in(key)).to be_nil
    end

    it 'is zero when an item is ready' do
      fill

      expect(queue.next_release_in(key)).to eq(0.0)
    end

    it 'counts down to the next slot' do
      fill
      queue.dequeue(key)

      expect(queue.next_release_in(key)).to eq(0.5)
      clock.advance(0.25)
      expect(queue.next_release_in(key)).to eq(0.25)
    end
  end

  describe '#size' do
    it 'tracks items as they are queued and released' do
      fill
      expect(queue.size(key)).to eq(3)

      queue.dequeue(key)
      expect(queue.size(key)).to eq(2)
    end
  end

  describe 'rates' do
    it 'spaces items 1 / leak_rate seconds apart' do
      slow = described_class.new(capacity: 3, leak_rate: 0.5, clock: clock)

      expect(fill(slow).map(&:wait)).to eq([0.0, 2.0, 4.0])
    end

    it 'releases at a constant rate however many items are waiting' do
      busy = described_class.new(capacity: 100, leak_rate: 2, clock: clock)
      100.times { |i| busy.enqueue(key, i) }

      released = []
      81.times do
        item = busy.dequeue(key)
        released << item unless item.nil?
        clock.advance(0.125)
      end

      # Polled from 0.0 s to 10.0 s; releases at 0.0, 0.5, ..., 10.0 = 21 items
      expect(released).to eq((0..20).to_a)
    end
  end

  describe 'multiple consumers' do
    it 'keeps a separate queue and schedule per key' do
      fill(queue, 'ip:198.51.100.1')
      queue.dequeue('ip:198.51.100.1')

      expect(queue.enqueue('ip:198.51.100.2', 'other')).to have_attributes(position: 1, wait: 0.0)
      expect(queue.dequeue('ip:198.51.100.2')).to eq('other')
    end
  end

  describe 'validation' do
    [0, -1, 2.5, '3', nil].each do |capacity|
      it "rejects capacity #{capacity.inspect}" do
        expect { described_class.new(capacity: capacity, leak_rate: 1) }
          .to raise_error(ArgumentError, /capacity/)
      end
    end

    [0, -0.5].each do |rate|
      it "rejects leak_rate #{rate}" do
        expect { described_class.new(capacity: 3, leak_rate: rate) }
          .to raise_error(ArgumentError, /leak_rate/)
      end
    end
  end

  describe 'concurrency' do
    it 'never accepts more than capacity from competing producers' do
      shared = described_class.new(capacity: 100, leak_rate: 1, clock: clock)
      start = Queue.new
      outcomes = Queue.new

      threads = Array.new(20) do |thread|
        Thread.new do
          start.pop
          50.times { |i| outcomes << shared.enqueue(key, [thread, i]).accepted? }
        end
      end
      threads.size.times { start << :go }
      threads.each(&:join)

      accepted = Array.new(outcomes.size) { outcomes.pop }.count(true)
      expect(accepted).to eq(100)
      expect(shared.size(key)).to eq(100)
    end

    it 'releases only one item per interval to competing consumers' do
      fill
      start = Queue.new
      released = Queue.new

      threads = Array.new(10) do
        Thread.new do
          start.pop
          5.times do
            item = queue.dequeue(key)
            released << item unless item.nil?
          end
        end
      end
      threads.size.times { start << :go }
      threads.each(&:join)

      expect(released.size).to eq(1)
      expect(queue.size(key)).to eq(2)
    end
  end

  it 'uses the monotonic clock by default' do
    expect(described_class.new(capacity: 1, leak_rate: 1).enqueue(key, 'job')).to be_accepted
  end
end
