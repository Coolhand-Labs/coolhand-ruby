# frozen_string_literal: true

require "spec_helper"
require "webmock/rspec"

# Read-only calls against a running Coolhand server. Not part of the default run: set
#   COOLHAND_SPEC_LIVE_BASE_URL=http://127.0.0.1:3000/api  COOLHAND_SPEC_LIVE_API_KEY=<private key>
# to exercise it. Creates and mutates nothing.
LIVE = %w[COOLHAND_SPEC_LIVE_BASE_URL COOLHAND_SPEC_LIVE_API_KEY].all? { |name| !ENV.fetch(name, "").strip.empty? }

RSpec.describe Coolhand, if: LIVE do
  let(:window) { { since: "2020-01-01", until: Time.now.utc } }
  let(:metrics_window) { { since: Time.now.utc - (90 * 86_400), until: Time.now.utc } }
  let(:private_key) { ENV.fetch("COOLHAND_SPEC_LIVE_API_KEY") }

  before do
    WebMock.allow_net_connect!
    Coolhand.configure do |config|
      config.api_key = private_key
      config.base_url = ENV.fetch("COOLHAND_SPEC_LIVE_BASE_URL")
      config.silent = true
      config.enabled = false
    end
  end

  after { WebMock.disable_net_connect! }

  describe "workloads" do
    it "returns metrics for an explicit window, with days_back null and the new counters" do
      result = Coolhand.workload_service.search_workloads(include_metrics: true, per: 3, **metrics_window)

      expect(result.workloads).to all(include(:id, :name, :metrics))
      expect(result.workloads.first[:id]).to be_a(String)
      expect(result.workloads.first[:metrics]).to include(
        :since, :until, :failure_count, :priced_request_count, :long_context_request_count,
        :total_input_tokens, :total_output_tokens, days_back: nil
      )
      expect(result.pagination.total_count).to be_a(Integer)
    end

    it "raises a 422 carrying the errors body for a malformed since" do
      expect { Coolhand.workload_service.search_workloads(include_metrics: true, since: "bad") }
        .to raise_error(Coolhand::HttpError) { |e|
          expect(e.status).to eq(422)
          expect(JSON.parse(e.body)["errors"]).to have_key("since")
        }
    end

    it "accepts a + UTC offset in a String window" do
      expect do
        Coolhand.workload_service.search_workloads(include_metrics: true, per: 1, since: "2026-01-01T00:00:00+02:00")
      end.not_to raise_error
    end

    it "raises 401 for an invalid key" do
      Coolhand.configuration.api_key = "not-a-real-key"

      expect { Coolhand.workload_service.search_workloads }
        .to raise_error(Coolhand::HttpError) { |e| expect(e.status).to eq(401) }
    end
  end

  describe "templates" do
    it "lists metrics for a days_back window and shows one for an explicit window" do
      list = Coolhand.template_service.search_templates(include_metrics: true, days_back: 365, per: 3)
      expect(list.templates.first[:metrics]).to include(:failure_count, days_back: 365)

      detail = Coolhand.template_service.get_template(list.templates.first[:id], **metrics_window)
      expect(detail[:metrics]).to include(:total_input_tokens, days_back: nil)
    end

    it "omits metrics on show with include_metrics: false, even for a bad window" do
      id = Coolhand.template_service.search_templates(per: 1).templates.first[:id]

      detail = Coolhand.template_service.get_template(id, include_metrics: false, since: "bad")

      expect(detail).not_to have_key(:metrics)
    end

    it "raises 422 on a bad window for show" do
      id = Coolhand.template_service.search_templates(per: 1).templates.first[:id]

      expect { Coolhand.template_service.get_template(id, since: "bad") }
        .to raise_error(Coolhand::HttpError) { |e| expect(e.status).to eq(422) }
    end
  end

  describe "logs" do
    it "orders by cost descending above min_cost, with cost as a number" do
      logs = Coolhand.log_service.search_logs(order: "cost_desc", min_cost: 0, per: 5, **window).logs

      costs = logs.map { |l| l[:cost] }
      expect(costs).to all(be_a(Numeric))
      expect(costs).to eq(costs.sort.reverse)
    end

    it "returns cost and cost_breakdown from get_log" do
      id = Coolhand.log_service.search_logs(order: "cost_desc", per: 1, **window).logs.first[:id]

      expect(Coolhand.log_service.get_log(id, max_chars: 10)).to include(:cost, :cost_breakdown)
    end

    it "raises 422 for an unknown order and for a negative min_cost" do
      expect { Coolhand.log_service.search_logs(order: "bogus") }
        .to raise_error(Coolhand::HttpError) { |e| expect(e.status).to eq(422) }
      expect { Coolhand.log_service.search_logs(min_cost: -1) }
        .to raise_error(Coolhand::HttpError) { |e| expect(e.status).to eq(422) }
    end

    it "returns page info by default and a total_count of at least 1 with include_total" do
      expect(Coolhand.log_service.search_logs(per: 1).pagination).to have_attributes(current_page: 1, per_page: 1)
      expect(Coolhand.log_service.search_logs(per: 1, include_total: true).pagination.total_count).to be >= 1
    end
  end
end
