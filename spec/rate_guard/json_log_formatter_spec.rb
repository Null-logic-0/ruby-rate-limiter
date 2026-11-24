# frozen_string_literal: true

require 'json'
require 'logger'
require 'stringio'

RSpec.describe RateGuard::JsonLogFormatter do
  let(:io) { StringIO.new }
  let(:logger) { described_class.logger(io) }
  let(:lines) { io.string.lines.map { |line| JSON.parse(line) } }

  it 'writes one JSON object per line, with time and level first' do
    logger.warn(event: 'rate_limited', policy: 'login', remaining: 0)
    logger.error(event: 'redis_unavailable')

    expect(lines.size).to eq(2)
    expect(lines.first.keys.first(2)).to eq(%w[time level])
    expect(lines.first).to include('level' => 'warn', 'event' => 'rate_limited', 'policy' => 'login', 'remaining' => 0)
    expect(lines.first['time']).to match(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z\z/)
  end

  it 'logs a message that is not a Hash under "message"' do
    logger.info('booted')

    expect(lines.first).to include('level' => 'info', 'message' => 'booted')
  end

  it 'escapes anything that would break the line, like newlines and quotes' do
    logger.warn(event: 'odd', path: "/a\"b\nc")

    expect(io.string.lines.size).to eq(1)
    expect(lines.first['path']).to eq("/a\"b\nc")
  end

  it 'makes the stream unbuffered, so lines reach a pipe as they happen' do
    reader, writer = IO.pipe
    writer.sync = false # like $stdout redirected to a pipe: buffered by default
    described_class.logger(writer).warn(event: 'rate_limited')

    expect(writer.sync).to be(true)
    expect(JSON.parse(reader.read_nonblock(1024))).to include('event' => 'rate_limited')
  ensure
    [reader, writer].each(&:close)
  end

  it 'respects the log level' do
    quiet = described_class.logger(io, level: :error)

    quiet.warn(event: 'rate_limited')

    expect(io.string).to be_empty
  end
end
