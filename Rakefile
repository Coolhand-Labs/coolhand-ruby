# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec)

require "rubocop/rake_task"

RuboCop::RakeTask.new

namespace :examples do
  desc "Run every live script in examples/ against real provider keys (loads keys via zsh -ic)"
  task :live do
    sh RbConfig.ruby, File.expand_path("bin/live-examples", __dir__)
  end
end

task default: %i[spec rubocop]
