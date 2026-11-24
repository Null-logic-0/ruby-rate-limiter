# frozen_string_literal: true

# Runs every benchmark and prints one comparison table.
#
#   bundle exec ruby benchmark/compare.rb          # or: bundle exec rake benchmark
#   BENCH_OPS=10000 BENCH_ROUNDS=3 bundle exec ruby benchmark/compare.rb   # quicker
#   RUBY_YJIT_ENABLE=1 bundle exec ruby benchmark/compare.rb               # with YJIT
#
# The numbers depend on the machine, the Ruby build, YJIT and (for Redis) the
# network: compare rows with each other, not with another machine's run.

require_relative 'single_thread'
require_relative 'memory'
require_relative 'concurrency'

Bench.banner('Rate limiter benchmarks')

sections = {
  'Single thread' => [Bench::SingleThread, Bench::SingleThread.run],
  "Memory (#{Bench.number(Bench::Memory::CLIENTS)} clients x #{Bench::Memory::REQUESTS} requests)" =>
    [Bench::Memory, Bench::Memory.run],
  'Concurrency' => [Bench::Concurrency, Bench::Concurrency.run]
}
sections.each do |title, (section, results)|
  puts "#{title}\n\n"
  section.print(results)
  puts
end

single = sections['Single thread'].last
memory = sections.values[1].last
concurrent = sections['Concurrency'].last

rows = concurrent.map do |name, c|
  s = single[name]
  [name,
   s ? Bench.number(s[:ops_per_sec]) : '-',
   s ? format('%.2f', s[:us_per_op]) : '-',
   s ? format('%.2f', s[:cpu_us_per_op]) : '-',
   memory[name] ? Bench.number(memory[name]) : '-',
   Bench.number(c[:throughput][16]),
   c[:exact] ? 'yes' : 'NO']
end

puts "Comparison\n\n"
puts Bench.table(['algorithm', 'decisions/s', 'µs/decision', 'CPU µs', 'bytes/client', '16 threads/s', 'exact'],
                 rows)
puts "\nQueue: one decision = enqueue + dequeue. Redis rows: #{Bench.number(Bench::REDIS_OPS)} ops per round."
abort "\nAn algorithm admitted more than its limit under concurrency." unless concurrent.values.all? { |c| c[:exact] }
