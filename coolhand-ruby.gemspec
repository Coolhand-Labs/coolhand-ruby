# frozen_string_literal: true

require_relative "lib/coolhand/ruby/version"

Gem::Specification.new do |spec|
  spec.name = "coolhand-ruby"
  spec.version = Coolhand::Ruby::VERSION
  spec.authors = ["YaroslavMalyk"]
  spec.email = ["ym@coolhand.io"]

  spec.summary = "Intercepts and logs OpenAI API calls from a Ruby application."
  spec.description = "A Ruby gem to automatically monitor and log requests to the OpenAI API. It patches Net::HTTP to capture request and response data."
  spec.homepage = "https://coolhand.io/"
  spec.required_ruby_version = ">= 3.0.0"

  spec.metadata["allowed_push_host"] = "TODO: Set to your gem server 'https://example.com'"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/Coolhand-Labs/coolhand-ruby"
  spec.metadata["changelog_uri"] = "https://github.com/Coolhand-Labs/coolhand-ruby"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  spec.files = Dir.chdir(__dir__) do
    `git ls-files -z`.split("\x0").reject do |f|
      (File.expand_path(f) == __FILE__) ||
        f.start_with?(*%w[bin/ test/ spec/ features/ .git appveyor Gemfile])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  # Uncomment to register a new dependency of your gem
  # spec.add_dependency "example-gem", "~> 1.0"

  # For more information and examples about making a new gem, check out our
  # guide at: https://bundler.io/guides/creating_gem.html
end
