# Google Vertex AI Batch Result Logging

Log completed Google Vertex AI batch prediction job results the same way regular synchronous calls are logged. Unlike the [OpenAI batch handler](openai.md), this is not webhook-driven — you call `Coolhand::Vertex::BatchResultProcessor` directly from your own batch-job callback/polling code.

For monitoring regular (non-batch) Vertex AI calls, no extra setup is required beyond `Coolhand.configure` — `aiplatform.googleapis.com` is intercepted by default.

Requires Rails — `Coolhand::Vertex::BatchResultProcessor` logs via `Rails.logger` internally. `config.capture = false` and `Coolhand.without_capture` do not suppress these logs: unlike the passive Net::HTTP interceptor, calling this processor is an explicit, deliberate act, so it always sends.

## Usage

```ruby
require "coolhand/vertex/batch_result_processor"
```

- Call the `Coolhand::Vertex::BatchResultProcessor` service with `batch_info` and the downloaded batch results.
- Optionally pass `model:` to populate the logged `model` field. It falls back to a `"model"` key in `batch_info` if present, and is omitted from the payload entirely when neither is available. If the value (from either source) looks like a Vertex model resource path (`publishers/<publisher>/models/<id>` or `projects/<project>/locations/<location>/models/<id>`), it's normalized down to just the trailing id/version before being logged; any other string is sent as-is.
- `batch_info["name"]` must be the exact Vertex job resource name (`projects/<project>/locations/<location>/batchPredictionJobs/<job-id>`), and `batch_info["startTime"]`/`["endTime"]` must be valid ISO 8601 timestamps — a batch with a missing or malformed resource name or timestamps is skipped entirely (logged as an error) rather than sent with a broken URL.
- If `endTime` precedes `startTime` (e.g. clock skew), the batch is still logged — `duration_ms` is clamped to `0` and a warning is logged — rather than dropping the results.
- Each element of the `batch_results` array passed to `.call` must be a `Hash` with a `"request"` and/or `"response"` key (the request/response body to log for that item — either key alone is accepted). Any other shape is treated as malformed and skipped, with the skip counted in a `Rails.logger.warn` summary rather than raised.

## Minimal example

Only the key lines are shown — wire this into your own batch callback service.

```ruby
class Vertex::BatchCallbackProcessor < BaseService
  option :batch_request, model: BatchApiRequest
  option :batch_info

  def call
    case batch_info["state"]
    when "JOB_STATE_PENDING"
      nil
    when "JOB_STATE_RUNNING", "JOB_STATE_QUEUED"
      batch_request.update!(status: "processing")

      Coolhand::Vertex::BatchResultProcessor.new(batch_info:).call
    when "JOB_STATE_SUCCEEDED"
      output_file_id = batch_info["outputInfo"]["gcsOutputDirectory"]
      results = download_batch_results(output_file_id)
      results.each { |batch_item| process_batch_result(batch_item) }

      batch_request.update!(status: "completed", completed_at: Time.current, output_file_id:)

      Coolhand::Vertex::BatchResultProcessor.new(batch_info:, model: batch_request.llm_model).call(results)

      # Clean up GCS files after successful processing
      cleanup_gcs_files(output_file_id)
    when "JOB_STATE_FAILED"
      handle_failed_batch(batch_info["error"]["message"])
    end
  end
end
```
