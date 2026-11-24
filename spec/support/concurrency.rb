# frozen_string_literal: true

# Runs the block in `threads` threads that all start at the same moment and
# returns every value the blocks returned. The block receives the thread's
# index (0 ... threads - 1).
module Concurrency
  def run_concurrently(threads:)
    start = Queue.new
    results = Queue.new

    workers = Array.new(threads) do |index|
      Thread.new do
        start.pop
        results << yield(index)
      end
    end

    threads.times { start << :go }
    workers.each(&:join)

    Array.new(results.size) { results.pop }
  end
end

RSpec.configure { |config| config.include Concurrency }
