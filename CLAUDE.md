# Development Guidelines

## Optional Provider Dependencies

Coolhand supports multiple LLM providers (OpenAI, Anthropic, Google Gemini, etc.). These provider gems should **never** be required at gem load time, as clients may not use all providers and shouldn't be forced to install unnecessary dependencies.

**Rule**: Any require for provider SDKs (openai, anthropic, google-generativeai, etc.) must be:
1. Placed in the file where it's actually used (not in the main coolhand.rb)
2. Only executed when that provider's functionality is accessed
3. Not declared as a hard dependency in coolhand-ruby.gemspec

Example pattern:
```ruby
# ❌ DON'T: In lib/coolhand.rb (loads unconditionally)
require "openai"

# ✅ DO: In lib/coolhand/open_ai/batch_result_processor.rb (only when needed)
require "openai"

module Coolhand
  module OpenAi
    class BatchResultProcessor
      def client
        @client ||= OpenAI::Client.new
      end
    end
  end
end
```

This ensures:
- Gem loads cleanly regardless of what providers are installed
- Apps using path gems (local development) don't break from missing optional dependencies
- Users only need gems for providers they actually use
