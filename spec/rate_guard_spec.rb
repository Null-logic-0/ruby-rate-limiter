# frozen_string_literal: true

require 'open3'
require 'rbconfig'

RSpec.describe RateGuard do
  it 'has a semantic version number' do
    expect(RateGuard::VERSION).to match(/\A\d+\.\d+\.\d+\z/)
  end

  it 'defines a base error class that inherits from StandardError' do
    expect(RateGuard::Error).to be < StandardError
  end

  describe 'bin/rate_guard' do
    it 'loads the library and prints the version' do
      script = File.expand_path('../bin/rate_guard', __dir__)

      stdout, stderr, status = Open3.capture3(RbConfig.ruby, script)

      expect(status).to be_success
      expect(stderr).to be_empty
      expect(stdout).to eq("RateGuard #{RateGuard::VERSION} (Ruby #{RUBY_VERSION})\n")
    end
  end
end
