# Reading Realized Savings

`Coolhand::SavingsService#get_realized_savings` returns the saving your client has realized by
switching templates or models: what the requests served by the current templates cost, versus what the
same requests would have cost on the deprecated versions they replaced. It is the figure the dashboard
shows. It wraps `GET /api/v2/savings` and is read-only.

**Auth:** requires your **private** API key. The public key is rejected exactly like an invalid key.

**Scoping:** the client is always derived from your API key. There is deliberately no `client_id`
keyword, and no keyword of any kind.

**Window:** the comparison covers deprecations from the last three months, fixed server-side. It is
not tied to a request window, so there is no `days_back`. The result is cached server-side for an hour.

```ruby
require "coolhand"

Coolhand.configure do |config|
  config.api_key = ENV.fetch("COOLHAND_PRIVATE_API_KEY")
end

savings = Coolhand.savings_service.get_realized_savings
savings[:total]   # => 4.5372 (USD)
savings[:percent] # => 79.7
```

## Return value

A Symbol-keyed Hash:

```ruby
{
  total: 4.5372,                     # the saving, USD
  cost_at_previous_versions: 5.6912, # the baseline the saving is measured against, USD
  percent: 79.7,                     # total as a share of the baseline, one decimal; 0.0 when the baseline is 0
  workloads: [
    {
      id: "xwjm0lgsdmy4",            # workload hashid, same as search_workloads
      name: "Help Center Article Suggester",
      savings: 2.0437,
      cost_at_previous_versions: 3.0402,
      active_requests: 182
    }
  ]
}
```

Money values are USD floats rounded to 4 decimals. `workloads` lists only workloads with a template
deprecated in the last three months, and every row always carries all five keys. A client with nothing
to compare gets `{ total: 0.0, cost_at_previous_versions: 0.0, percent: 0.0, workloads: [] }`, which is
real zero savings.

## Errors

`Coolhand::HttpError` carries `#status` and `#body` on a non-2xx response.

| status | when |
|---|---|
| `401` | No API key, an invalid key, or the public key. |
| `503` | The comparison could not be computed right now. Retryable. |

**A `503` is not zero savings.** Do not map it to zeros; show it as an error and retry.
`Coolhand::Error` covers no API key configured, a transport failure, and a body that is not a JSON
object.

## Combining it with workload metrics

`savings` is **not windowed**, but a workload's `metrics` from
`search_workloads(include_metrics: true, days_back: N)` are. A workload's `savings` can therefore exceed
its windowed `metrics[:total_cost]`; do not read the two as a ratio over the same period. Join the two
on `id` to build a per-workload ROI view:

```ruby
# Archived and system workloads can still carry realized savings, so include them or their rows go unmatched.
workloads = Coolhand.workload_service.search_workloads(
  include_metrics: true, days_back: 30, include_archived: true, include_system: true, per: 100
).workloads
savings = Coolhand.savings_service.get_realized_savings

savings_by_id = savings[:workloads].to_h { |row| [row[:id], row] }

roi = workloads.map do |workload|
  {
    id: workload[:id],
    name: workload[:name],
    spend_last_30_days: workload.dig(:metrics, :total_cost), # windowed
    realized_savings: savings_by_id.dig(workload[:id], :savings) || 0 # not windowed
  }
end
```

This reads one page of up to 100 workloads; `search_workloads` is paged (`page`, `per`), so repeat the
call while `pagination.has_next_page` is true for a client with more. The `get_client_roi_summary` MCP
tool performs the same join over the two endpoints.
