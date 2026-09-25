# frozen_string_literal: true

require "spec_helper"
require "webmock/rspec"

RSpec.describe Coolhand::OptimizationFeedbackLinkService do
  let(:links_url) { "https://coolhandlabs.com/api/v2/optimizations/opt1/feedback_links" }
  let(:config) do
    instance_double(Coolhand::Configuration,
      api_key: "test-private-key",
      base_url: "https://coolhandlabs.com/api",
      silent: true,
      environment: "production",
      debug_mode: false)
  end
  let(:service) { described_class.new }
  let(:json_headers) { { "Content-Type" => "application/json" } }

  before do
    allow(Coolhand).to receive(:configuration).and_return(config)
  end

  it "is exposed on the top-level API" do
    expect(Coolhand.optimization_feedback_link_service).to be_a(described_class)
  end

  describe "#link_feedback" do
    let(:link) do
      { id: "lnk1", optimization_id: "opt1", feedback_id: "fb1", note: "why", created_at: "2026-09-25T00:00:00Z" }
    end

    it "posts feedback_id and note with the private key and returns the link" do
      stub = stub_request(:post, links_url)
        .with(headers: { "X-API-Key" => "test-private-key" }, body: { feedback_id: "fb1", note: "why" }.to_json)
        .to_return(status: 201, body: link.to_json, headers: json_headers)

      expect(service.link_feedback("opt1", "fb1", note: "why")).to eq(link)
      expect(stub).to have_been_requested
    end

    it "omits note when not given" do
      stub = stub_request(:post, links_url).with(body: { feedback_id: "fb1" }.to_json)
        .to_return(status: 201, body: link.to_json)

      service.link_feedback("opt1", "fb1")
      expect(stub).to have_been_requested
    end

    it "raises HttpError carrying the status on 422" do
      stub_request(:post, links_url).to_return(status: 422, body: { errors: ["already linked"] }.to_json)

      expect { service.link_feedback("opt1", "fb1") }.to raise_error(Coolhand::HttpError) { |e|
        expect(e.status).to eq(422)
        expect(e.message).to include("already linked")
      }
    end

    it "raises HttpError on 404 and 401" do
      stub_request(:post, links_url).to_return({ status: 404, body: '{"error":"nf"}' },
        { status: 401, body: '{"error":"no"}' })

      expect { service.link_feedback("opt1", "fb1") }.to raise_error(Coolhand::HttpError) { |e| expect(e.status).to eq(404) }
      expect { service.link_feedback("opt1", "fb1") }.to raise_error(Coolhand::HttpError) { |e| expect(e.status).to eq(401) }
    end

    it "rejects blank and dot-segment ids before any request" do
      expect { service.link_feedback("", "fb1") }.to raise_error(Coolhand::Error, /optimization_id/)
      expect { service.link_feedback("..", "fb1") }.to raise_error(Coolhand::Error, /optimization_id/)
      expect { service.link_feedback("opt1", " ") }.to raise_error(Coolhand::Error, /feedback_id/)
      expect { service.link_feedback("opt1", nil) }.to raise_error(Coolhand::Error, /feedback_id/)
      expect(a_request(:any, /coolhandlabs/)).not_to have_been_made
    end

    it "encodes the optimization id as a single path segment" do
      stub = stub_request(:post, "https://coolhandlabs.com/api/v2/optimizations/a%2Fb%3F/feedback_links")
        .to_return(status: 201, body: link.to_json)

      service.link_feedback("a/b?", "fb1")
      expect(stub).to have_been_requested
    end

    it "raises without an API key" do
      allow(config).to receive(:api_key).and_return(nil)

      expect { service.link_feedback("opt1", "fb1") }.to raise_error(Coolhand::Error, /API key is required/)
    end
  end

  describe "#bulk_link_feedback" do
    def result(linked: 0, already_linked: 0, errored: 0, not_found: [])
      { linked: linked, already_linked: already_linked, errored: errored, not_found: not_found }.to_json
    end

    it "posts feedback_ids and returns the counts" do
      stub = stub_request(:post, links_url)
        .with(body: { feedback_ids: %w[a b c], note: "n" }.to_json)
        .to_return(status: 200, body: result(linked: 1, already_linked: 1, not_found: ["c"]))

      expect(service.bulk_link_feedback("opt1", %w[a b c], note: "n"))
        .to eq(linked: 1, already_linked: 1, errored: 0, not_found: ["c"])
      expect(stub).to have_been_requested
    end

    it "chunks over 100 ids and sums the batches" do
      ids = (1..250).map { |i| "id#{i}" }
      sizes = []
      stub_request(:post, links_url).to_return do |request|
        batch = JSON.parse(request.body)["feedback_ids"]
        sizes << batch.size
        { status: 200, body: result(linked: batch.size - 1, already_linked: 1, errored: 0, not_found: [batch.first]) }
      end

      total = service.bulk_link_feedback("opt1", ids)

      expect(sizes).to eq([100, 100, 50])
      expect(total).to eq(linked: 247, already_linked: 3, errored: 0, not_found: %w[id1 id101 id201])
    end

    it "raises when a later batch fails, after earlier ones were sent" do
      ids = (1..150).map { |i| "id#{i}" }
      stub_request(:post, links_url).to_return({ status: 200, body: result(linked: 100) },
        { status: 500, body: "boom" })

      expect { service.bulk_link_feedback("opt1", ids) }.to raise_error(Coolhand::HttpError) { |e|
        expect(e.status).to eq(500)
      }
      expect(a_request(:post, links_url)).to have_been_made.twice
    end

    it "rejects an empty list or blank id before any request" do
      expect { service.bulk_link_feedback("opt1", []) }.to raise_error(Coolhand::Error, /non-empty array/)
      expect { service.bulk_link_feedback("opt1", nil) }.to raise_error(Coolhand::Error, /non-empty array/)
      expect { service.bulk_link_feedback("opt1", ["a", ""]) }.to raise_error(Coolhand::Error, /feedback_ids/)
      expect { service.bulk_link_feedback("", ["a"]) }.to raise_error(Coolhand::Error, /optimization_id/)
      expect(a_request(:any, /coolhandlabs/)).not_to have_been_made
    end

    it "raises HttpError on 422" do
      stub_request(:post, links_url).to_return(status: 422, body: { errors: { feedback_ids: ["too many"] } }.to_json)

      expect { service.bulk_link_feedback("opt1", ["a"]) }.to raise_error(Coolhand::HttpError) { |e|
        expect(e.status).to eq(422)
      }
    end
  end

  describe "#unlink_feedback" do
    it "deletes the link and returns true on 204" do
      stub = stub_request(:delete, "#{links_url}/lnk1").with(headers: { "X-API-Key" => "test-private-key" })
        .to_return(status: 204, body: "")

      expect(service.unlink_feedback("opt1", "lnk1")).to be(true)
      expect(stub).to have_been_requested
    end

    it "raises HttpError on 404" do
      stub_request(:delete, "#{links_url}/nope").to_return(status: 404, body: '{"error":"not found"}')

      expect { service.unlink_feedback("opt1", "nope") }.to raise_error(Coolhand::HttpError) { |e|
        expect(e.status).to eq(404)
      }
    end

    it "rejects a blank link id before any request" do
      expect { service.unlink_feedback("opt1", "") }.to raise_error(Coolhand::Error, /link_id/)
      expect(a_request(:any, /coolhandlabs/)).not_to have_been_made
    end
  end

  # Mutates data, so it only runs against a loopback server, never a remote one.
  live_local = ENV.fetch("COOLHAND_LIVE_BASE_URL", "").match?(%r{\Ahttp://(127\.0\.0\.1|localhost)[:/]}) &&
               %w[COOLHAND_LIVE_API_KEY COOLHAND_LIVE_OPTIMIZATION_ID COOLHAND_LIVE_FEEDBACK_IDS]
                 .none? { |name| ENV.fetch(name, "").empty? }

  describe "against the live local server", if: live_local do
    let(:live_config) do
      instance_double(Coolhand::Configuration,
        api_key: ENV.fetch("COOLHAND_LIVE_API_KEY"),
        base_url: "#{ENV.fetch('COOLHAND_LIVE_BASE_URL')}/api",
        silent: true, environment: "test", debug_mode: false)
    end
    let(:optimization_id) { ENV.fetch("COOLHAND_LIVE_OPTIMIZATION_ID") }
    let(:feedback_ids) { ENV.fetch("COOLHAND_LIVE_FEEDBACK_IDS").split }

    before do
      WebMock.allow_net_connect!
      allow(Coolhand).to receive(:configuration).and_return(live_config)
    end

    after { WebMock.disable_net_connect! }

    it "links, bulk links, reports unknown ids, and unlinks" do
      bulk = service.bulk_link_feedback(optimization_id, feedback_ids + ["doesnotexist"])
      expect(bulk[:linked] + bulk[:already_linked]).to eq(feedback_ids.size)
      expect(bulk[:not_found]).to eq(["doesnotexist"])

      expect { service.link_feedback(optimization_id, feedback_ids.first) }
        .to raise_error(Coolhand::HttpError) { |e| expect(e.status).to eq(422) }
      expect { service.link_feedback("nope", feedback_ids.first) }
        .to raise_error(Coolhand::HttpError) { |e| expect(e.status).to eq(404) }

      allow(live_config).to receive(:api_key).and_return("ch_pub_invalid")
      expect { service.bulk_link_feedback(optimization_id, feedback_ids) }
        .to raise_error(Coolhand::HttpError) { |e| expect(e.status).to eq(401) }
    end
  end
end
