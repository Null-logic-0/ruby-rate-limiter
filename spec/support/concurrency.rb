# frozen_string_literal: true

# Runs the block in `threads` threads started together.
# Returns their results; the block gets the thread index.
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
