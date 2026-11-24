# frozen_string_literal: true

# A clock tests control: time only moves when the test calls #advance.
class FakeClock
  attr_reader :now

  def initialize(now = 0.0)
    @now = now
  end

  def advance(seconds)
    @now += seconds
  end
end
