# Reading the Help Center

`Coolhand::HelpCenterService` reads Coolhand's help center: the articles served at
`coolhandlabs.com/help/:slug` and the posts at `/updates/:slug`. "Help center" is the user-facing name;
on the wire the resource is `public_content` (`GET /api/v2/public_content`, `/:slug` and `/categories`).
It is read-only. Creating, updating and archiving articles is Coolhand-internal and not wrapped.

**Auth:** none required. Unlike every other service, no API key is needed:

```ruby
require "coolhand"

help_center = Coolhand.help_center_service # works with Coolhand.configure never called
```

- No key configured: no `X-API-Key` header is sent, and the calls work. Anonymous callers are limited to
  **30 requests per minute per IP**; beyond that the server answers `429`.
- A configured `config.api_key` is sent as `X-API-Key` and callers with a valid key are not rate limited.
  This gem reads the key from configuration only, not from the environment.
- A key the server does not recognise is a `401` (`{"error":"Invalid API key."}`) even though the endpoint is
  public. It is raised, not retried anonymously.

## `search_help_articles`

```ruby
result = help_center.search_help_articles(query: "match rate", category: "feedback-and-prompts", per_page: 10)

result.articles.each { |a| puts "#{a[:title]}: #{a[:search_headline]}" }
result.pagination.total_count
```

### Keywords

All optional.

| keyword | type | notes |
|---|---|---|
| `query` | String | Relevance search (Postgres full text, the same as the website's). Supports quoted phrases, `-exclusions` and `or`. Omit for a full listing. A blank string counts as omitted. |
| `category` | String | Restrict to one section by slug (see `list_help_categories`). A blank string counts as omitted. |
| `page` | Integer | 1-based. |
| `per_page` | Integer | Default 25, max 100, both enforced server-side. |

The endpoint has no `category` parameter. `category` is sent in its structured form instead, which also
moves the relevance search to a different key; the plain `q=...` string and the `q[...]` form cannot be
mixed:

| `query` | `category` | Sent |
|---|---|---|
| set | unset | `q=<query>` |
| unset | set | `q[help_category_slug_eq]=<category>` |
| set | set | `q[help_category_slug_eq]=<category>&q[full_text]=<query>` |

### Return value

A `Coolhand::HelpArticleSearchResult` with `articles` (an Array of Symbol-keyed Hashes) and `pagination`.
Each article is a summary; the markdown `:body` is omitted from lists:

```ruby
{
  slug: "what-is-feedback-match-rate",
  title: "What is feedback match rate?",
  answer: "Match rate is the share of ...",       # String or nil
  article_kind: "concept",   # reference | concept | how_to | troubleshooting | faq_answer | release_note
  tags: ["feedback", "matching"],
  category: "feedback-and-prompts",               # section slug
  url: "https://coolhandlabs.com/help/what-is-feedback-match-rate",
  markdown_url: "https://coolhandlabs.com/help/what-is-feedback-match-rate.md",
  reading_time_minutes: 10,                       # Integer or nil
  search_headline: "<mark>Match</mark> rate ...", # nil on a plain listing
  published_at: "2026-08-30T13:57:52Z",           # String or nil
  updated_content_at: "2026-08-30T13:57:52Z"      # String or nil
}
```

`:search_headline` is the matching passage with `<mark>` tags around the matched terms, so you can see
why something matched without fetching the body.

`pagination` is a `Coolhand::Pagination`, the same as the other read methods, built from the `X-Page`,
`X-Per-Page`, `X-Total-Count` and `X-Total-Pages` response headers (`current_page`, `per_page`,
`total_count`, `total_pages`, `has_next_page`, `has_prev_page`).

## `get_help_article(slug)`

```ruby
article = help_center.get_help_article("what-is-feedback-match-rate")
article[:body] # full markdown
article[:toc]  # [{ id:, text:, level:, children: }]
```

Returns a Hash: the summary fields minus `:search_headline`, plus `:body` (full markdown), `:noindex`
(Boolean) and `:toc` (the heading structure, h3s nested under their h2). The slug is escaped as a single
path segment. Raises `Coolhand::Error` before any request if `slug` is blank or a bare `.`/`..`. An unknown
or unpublished slug raises `Coolhand::HttpError` with `status` 404.

## `list_help_categories`

```ruby
help_center.list_help_categories
# [{ slug: "providers", name: "Provider guides", description: "...", url_prefix: "/help", allowed_tags: nil }, ...]
```

Returns an Array of Hashes: `:slug` (the `category` filter above), `:name`, `:description`, `:url_prefix`
(`/help` or `/updates`) and `:allowed_tags` (the only tags the section accepts; `nil` means any tag).

## Errors

These are read methods, so they raise where the logging writes log and return `nil`. A network failure or
a non-JSON body raises `Coolhand::Error`. A non-2xx response raises `Coolhand::HttpError`, whose `status`
holds the HTTP status code and `body` the (truncated) response body: `401` for an invalid key, `404` for an
unknown slug, `429` when the anonymous rate limit is exceeded.

## Verifying against a live server

`spec/live/coolhand_help_center_live_spec.rb` runs against a real server with no key:

```bash
COOLHAND_SPEC_LIVE_BASE_URL=http://127.0.0.1:3000/api bundle exec rspec spec/live/coolhand_help_center_live_spec.rb
```

It makes about nine anonymous requests, so running it repeatedly within a minute can hit the `429`.
