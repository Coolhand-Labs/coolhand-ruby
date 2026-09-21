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

## Changelog and versioning

Do not add `CHANGELOG.md` entries or bump `lib/coolhand/version.rb` on feature/fix branches or in PRs. The `/prep-release` skill is the sole owner of both — it writes changelog entries for the PRs actually shipping in a release and bumps the version once, at release time.

Per-PR changelog edits create merge conflicts across concurrent branches for no benefit, since the entries get rewritten from the final, user-approved set of merged PRs anyway. Leave `CHANGELOG.md` and `version.rb` alone in your PR.

## README and docs philosophy

The README is a landing page — install, quick start, what it supports, where to go next. Keep it scannable. When in doubt, link rather than expand.

**Three rules:**
- **Config**: the basic `Coolhand.configure` snippet belongs in the README. Anything requiring more than one code block (self-hosted `base_url`, custom intercept addresses) goes in `docs/configuration.md`.
- **Feedback**: the basic `create_feedback` snippet belongs in the README. The full field table, matching strategies, and sentiment conversion details go in `docs/feedback.md`.
- **Integrations**: each integration gets its own `docs/<name>.md` file. The README links to them from the Documentation section.

**Align with coolhand-node.** When adding a section that exists in the Node README, match its structure and tone. The two READMEs should feel like siblings.

**Discoverability (SEO / AEO).** Write headings, the package description, and the supported-libraries list with search engines and AI agents in mind: use full provider/framework names (e.g. "OpenAI", "Anthropic", "Google Gemini", "Cohere") rather than abbreviations. The goal is that searches for "Ruby LLM monitoring", "Anthropic Ruby logging", or "OpenAI Ruby observability" surface this gem.
