# frozen_string_literal: true

SimpleCov.start do
  add_filter "/spec/"

  # `rake spec:live` drives one service against a real Coolhand server. The floor below is
  # calibrated for the full unit suite, so applying it there would fail a green live run for a
  # reason that has nothing to do with the code under test.
  minimum_coverage(ENV["COOLHAND_LIVE_SUITE"] ? 0 : 70)
end
