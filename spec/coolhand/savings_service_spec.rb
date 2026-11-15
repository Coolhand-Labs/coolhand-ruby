# frozen_string_literal: true

require "spec_helper"
require "webmock/rspec"

RSpec.describe Coolhand::SavingsService do
  let(:endpoint) { "https://coolhandlabs.com/api/v2/savings" }
  let(:config) do
    instance_double(Coolhand::Configuration,
      api_key: "test-private-key",
      base_url: "https://coolhandlabs.com/api",
      silent: true,
      environment: "production",
      debug_mode: false)
  end
  let(:service) { described_class.new }
  let(:savings) do
    {
      total: 4.5372,
      cost_at_previous_versions: 5.6912,
      percent: 79.7,
      workloads: [
        {
          id: "xwjm0lgsdmy4",
          name: "Help Center Article Suggester",
          savings: 2.0437,
          cost_at_previous_versions: 3.0402,
          active_requests: 182
        }
      ]
    }
  end

  before do
    allow(Coolhand).to receive(:configuration).and_return(config)
  end

  def stub_savings(body:, status: 200)
    stub_request(:get, endpoint).to_return(
      status: status,
      body: body.is_a?(String) ? body : JSON.generate(body),
      headers: { "Content-Type" => "application/json" }
    )
  end

  describe "#initialize" do
    it "targets the savings singleton on the configured base_url" do
      expect(service.api_endpoint).to eq(endpoint)
    end

    it "is reachable from Coolhand.savings_service" do
      expect(Coolhand.savings_service).to be_a(described_class)
    end
  end

  describe "#get_realized_savings" do
    it "GETs the endpoint with no query string, the private key and an Accept header" do
      stub_savings(body: savings)

      service.get_realized_savings

      expect(WebMock).to have_requested(:get, endpoint)
        .with(headers: { "X-API-Key" => "test-private-key", "Accept" => "application/json" }, query: {})
    end

    it "returns the body as a Symbol-keyed Hash, with money as numbers and the workload id as a string" do
      stub_savings(body: savings)

      result = service.get_realized_savings

      expect(result).to eq(savings)
      expect(result[:total]).to be_a(Float)
      expect(result[:workloads].first[:id]).to be_a(String)
    end

    it "returns zeros and an empty workloads array as real zero savings" do
      zero = { total: 0.0, cost_at_previous_versions: 0.0, percent: 0.0, workloads: [] }
      stub_savings(body: zero)

      expect(service.get_realized_savings).to eq(zero)
    end

    it "raises an HttpError carrying 503, never zeros, when the comparison could not be computed" do
      body = { errors: { system: ["Realized savings could not be computed right now. Please retry."] } }
      stub_savings(body: body, status: 503)

      expect { service.get_realized_savings }
        .to raise_error(Coolhand::HttpError, /could not be computed/) { |e|
          expect(e.status).to eq(503)
          expect(JSON.parse(e.body)["errors"]).to have_key("system")
        }
    end

    it "raises an HttpError carrying 401 for a missing or public key" do
      stub_savings(body: { error: "Invalid API key" }, status: 401)

      expect { service.get_realized_savings }.to raise_error(Coolhand::HttpError) { |e| expect(e.status).to eq(401) }
    end

    it "raises Coolhand::Error for a body that is not valid JSON" do
      stub_savings(body: "<html>502 Bad Gateway</html>")

      expect { service.get_realized_savings }.to raise_error(Coolhand::Error, /not valid JSON/)
    end

    it "raises Coolhand::Error for a body that is not a JSON object" do
      stub_savings(body: [])

      expect { service.get_realized_savings }.to raise_error(Coolhand::Error, /not a JSON object/)
    end

    it "raises when no API key is configured, before any request" do
      allow(config).to receive(:api_key).and_return(nil)

      expect { service.get_realized_savings }.to raise_error(Coolhand::Error, /API key is required/)
      expect(WebMock).not_to have_requested(:get, /savings/)
    end

    it "does not follow a redirect, so the key is never replayed at another host" do
      stub_request(:get, endpoint).to_return(status: 302, headers: { "Location" => "https://evil.example/savings" })

      expect { service.get_realized_savings }.to raise_error(Coolhand::HttpError) { |e| expect(e.status).to eq(302) }
      expect(WebMock).not_to have_requested(:get, "https://evil.example/savings")
    end
  end
end
