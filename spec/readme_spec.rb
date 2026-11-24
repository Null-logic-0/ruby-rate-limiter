# frozen_string_literal: true

require 'open3'
require 'rbconfig'
require 'tmpdir'

# Runs the Ruby samples in README.md so the docs stay correct.
#
# - ```ruby block: run as a script; output must match the next ```text
#   block (… matches anything on a line).
# - <!-- readme: file NAME -->: saved as NAME for later samples.
# - <!-- readme: gemfile -->: checked as Gemfile lines.
# - <!-- readme: redis -->: needs Redis; skipped without it.
# - ```sh blocks are not run.
module ReadmeSamples
  Block = Data.define(:lang, :code, :directive, :line)
  DIRECTIVE = /\A<!-- readme: (.+?) -->\z/
  FENCE = /\A```(\w*)\z/

  def self.parse(text)
    blocks = []
    directive = nil
    lines = text.lines(chomp: true)
    index = 0
    while index < lines.size
      line = lines[index]
      if (match = DIRECTIVE.match(line))
        directive = match[1]
      elsif (match = FENCE.match(line)) && !match[1].empty?
        closing = ((index + 1)...lines.size).find { |i| lines[i] == '```' } or
          raise "unclosed ``` block at README.md:#{index + 1}"
        blocks << Block.new(lang: match[1], code: "#{lines[(index + 1)...closing].join("\n")}\n",
                            directive: directive, line: index + 1)
        directive = nil
        index = closing
      elsif !line.strip.empty?
        directive = nil # a directive applies only to the block right after it
      end
      index += 1
    end
    blocks
  end

  # `…` in expected output matches anything on that line.
  def self.pattern(expected)
    parts = expected.chomp.split('…', -1).map { |part| Regexp.escape(part) }
    /\A#{parts.join('[^\n]*')}\n?\z/
  end
end

RSpec.describe 'README.md' do
  root = File.expand_path('..', __dir__)
  blocks = ReadmeSamples.parse(File.read(File.join(root, 'README.md'), encoding: Encoding::UTF_8))
  files = blocks.select { |block| block.directive.to_s.start_with?('file ') }

  # Child processes inherit bundler from `bundle exec`.
  def run_ruby(*args, dir:, env: {})
    Open3.capture3(env, RbConfig.ruby, '-I', File.join(File.expand_path('..', __dir__), 'lib'), *args, chdir: dir)
  end

  around do |example|
    Dir.mktmpdir('readme') do |dir|
      @dir = dir
      files.each { |block| File.write(File.join(dir, block.directive.delete_prefix('file ')), block.code) }
      example.run
    end
  end

  it 'has Ruby samples to check' do
    expect(blocks.count { |block| block.lang == 'ruby' }).to be >= 5
  end

  blocks.each_with_index do |block, position|
    next unless block.lang == 'ruby'

    case block.directive
    when 'gemfile'
      it "has valid Gemfile lines (line #{block.line})" do
        require 'bundler'
        dsl = Bundler::Dsl.new
        expect { dsl.instance_eval(block.code) }.not_to raise_error
        expect(dsl.dependencies.map(&:name)).not_to be_empty
      end
    when /\Afile (.+\.ru)\z/
      name = Regexp.last_match(1)
      it "builds #{name} (line #{block.line})" do
        check = "app = Rack::Builder.parse_file(#{name.dump}); exit(app.respond_to?(:call))"
        _out, err, status = run_ruby('-rrack', '-e', check, dir: @dir)
        expect([status.success?, err]).to eq([true, ''])
      end
    when /\Afile /
      next # used by the scripts that follow it
    when nil, 'redis'
      following = blocks[position + 1]
      expected = following&.lang == 'text' ? following.code : nil
      metadata = block.directive == 'redis' ? [:redis] : []

      it "runs the sample at line #{block.line}", *metadata do
        env = block.directive == 'redis' ? { 'REDIS_URL' => redis_url } : {}
        File.write(File.join(@dir, 'sample.rb'), block.code)
        out, err, status = run_ruby('sample.rb', dir: @dir, env: env)

        expect([status.success?, err]).to eq([true, '']), "README.md:#{block.line} failed:\n#{err}"
        expect(out.force_encoding(Encoding::UTF_8)).to match(ReadmeSamples.pattern(expected)) if expected
      end
    else
      raise "unknown README directive #{block.directive.inspect} at line #{block.line}"
    end
  end

  describe ReadmeSamples do
    it 'pairs each block with the directive right before it, and only that one' do
      text = "<!-- readme: file a.rb -->\n```ruby\nx\n```\n<!-- readme: redis -->\nprose\n```ruby\ny\n```\n"

      expect(described_class.parse(text).map { |block| [block.directive, block.code] })
        .to eq([['file a.rb', "x\n"], [nil, "y\n"]])
    end

    it 'treats … as any text within one line' do
      pattern = described_class.pattern("{\"time\":\"…\",\"level\":\"warn\"}\n")

      expect("{\"time\":\"2026-11-24T13:20:01Z\",\"level\":\"warn\"}\n").to match(pattern)
      expect("{\"time\":\"x\",\"level\":\"error\"}\n").not_to match(pattern)
      expect("{\"time\":\"a\nb\",\"level\":\"warn\"}\n").not_to match(pattern)
    end
  end
end
