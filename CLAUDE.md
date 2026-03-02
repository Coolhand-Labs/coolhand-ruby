# Development Guidelines

## Optional Provider Dependencies

Coolhand supports multiple LLM providers (OpenAI, Anthropic, Google Gemini, etc.). These provider gems should **never** be required at gem load time, as clients may not use all providers and shouldn't be forced to install unnecessary dependencies.

**Rules**:
1. Don't `require_relative` provider-specific files from the main `coolhand.rb`
2. Any require for provider SDKs must be inside the methods that use them, not at module level
3. Wrap provider requires in error handling to give helpful messages if gems are missing
4. Don't declare provider SDKs as hard dependencies in coolhand-ruby.gemspec

**Example pattern**:
```ruby
# ❌ DON'T: At module level in batch_result_processor.rb
require "openai"

module Coolhand
  module OpenAi
    class BatchResultProcessor
      # ...
    end
  end
end

# ✅ DO: Inside the method that uses it
module Coolhand
  module OpenAi
    class BatchResultProcessor
      def client
        @client ||= begin
          require "openai"
          OpenAI::Client.new
        rescue LoadError => e
          raise LoadError, "The 'openai' gem is required. Install it with: gem 'openai'"
        end
      end
    end
  end
end
```

This ensures:
- Gem loads cleanly in any application, regardless of installed providers
- Apps using path gems (local development) don't break from missing optional dependencies
- Users only need gems for providers they actually use
- Clear error messages if a provider SDK is needed but not installed
