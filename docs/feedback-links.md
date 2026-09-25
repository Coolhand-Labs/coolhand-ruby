# Linking feedback to an optimization

Attach feedback to an optimization as supporting evidence. `Coolhand::OptimizationFeedbackLinkService`
wraps `POST /api/v2/optimizations/{optimization_id}/feedback_links` (single and bulk share the route,
chosen by the body) and `DELETE /api/v2/optimizations/{optimization_id}/feedback_links/{id}`.

These methods require your **private** API key; the public key gets a `401`.

```ruby
require "coolhand"

Coolhand.configure do |config|
  config.api_key = ENV.fetch("COOLHAND_PRIVATE_API_KEY")
end

links = Coolhand.optimization_feedback_link_service

# One feedback. link[:id] is the link's hashid, not the feedback's.
link = links.link_feedback("optimizationHashid", "feedbackHashid", note: "why")

# Many feedbacks.
result = links.bulk_link_feedback("optimizationHashid", %w[fb1 fb2 fb3])
result # => { linked: 2, already_linked: 1, errored: 0, not_found: [] }

# Remove a link.
links.unlink_feedback("optimizationHashid", link[:id])
```

## Bulk behavior

- The server accepts at most 100 ids per request. `bulk_link_feedback` splits longer lists into
  batches of 100, sums `linked` / `already_linked` / `errored` and concatenates `not_found`.
- Already-linked ids count as `already_linked`, not errors. Unknown, malformed and other-client ids
  are all reported in `not_found`.
- If a batch fails, the call raises and earlier batches stay applied. Repeating the call is safe.
- An empty list or a blank id raises `Coolhand::Error` before any request is made.
- Ids are not de-duplicated client-side.

## Errors

Unlike the logging writes, all three methods raise. A non-2xx response raises `Coolhand::HttpError`
whose `status` is the HTTP code: `401` missing or public key, `404` unknown optimization, feedback or
link, `422` invalid input, an already-linked feedback (single mode) or a `note` that is too long.
Client-side validation and transport failures raise `Coolhand::Error`.
