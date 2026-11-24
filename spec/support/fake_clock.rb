# frozen_string_literal: true

# A test clock: time moves only on #advance.
class FakeClock
  attr_reader :now

  def initialize(now = 0.0)
    @now = now
  end

  def advance(seconds)
    @now += seconds
  end
end
