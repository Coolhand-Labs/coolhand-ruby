# frozen_string_literal: true

require "spec_helper"
require "webmock/rspec"

# Read-only calls against a running Coolhand server. Not part of the default run: set
#   COOLHAND_SPEC_LIVE_BASE_URL=http://127.0.0.1:3000/api  COOLHAND_SPEC_LIVE_API_KEY=<private key>
# to exercise it. Set COOLHAND_SPEC_LIVE_LOG_ID to a captured agent session's log hashid to also cover
# turn_metrics. Creates and mutates nothing.
STEP_TEMPLATES_LIVE = %w[COOLHAND_SPEC_LIVE_BASE_URL COOLHAND_SPEC_LIVE_API_KEY].all? do |name|
  !ENV.fetch(name, "").strip.empty?
end

RSpec.describe Coolhand, if: STEP_TEMPLATES_LIVE do
  let(:service) { Coolhand.step_template_service }

  before do
    WebMock.allow_net_connect!
    Coolhand.configure do |config|
      config.api_key = ENV.fetch("COOLHAND_SPEC_LIVE_API_KEY")
      config.base_url = ENV.fetch("COOLHAND_SPEC_LIVE_BASE_URL")
      config.silent = true
      config.enabled = false
    end
  end

  after { WebMock.disable_net_connect! }

  def status_of
    yield
    nil
  rescue Coolhand::HttpError => e
    e.status
  end

  it "lists step templates without metrics by default" do
    result = service.list_step_templates

    expect(result.step_templates).not_to be_empty
    expect(result.step_templates.first).to include(:id, :name, :step_type, :sessions_count, :last_seen_at)
    expect(result.step_templates.first[:id]).to be_a(Integer)
    expect(result.step_templates).to all(satisfy { |row| !row.key?(:metrics) })
    expect(result.pagination.total_count).to be >= result.step_templates.size
  end

  it "adds metrics per row and caps per at 25 when include_metrics is set" do
    result = service.list_step_templates(include_metrics: true, per: 100)

    expect(result.pagination.per_page).to eq(25)
    expect(result.step_templates).to all(include(:metrics))
    expect(result.step_templates.first[:metrics]).to include(:total_runs, :tool_stats, :turn_stats, :efficiency, :notes)
  end

  it "filters by search and step_type" do
    all_rows = service.list_step_templates.step_templates
    type = all_rows.first[:step_type]

    by_type = service.list_step_templates(step_type: type).step_templates
    by_name = service.list_step_templates(search: all_rows.first[:name].upcase).step_templates

    expect(by_type.map { |row| row[:step_type] }.uniq).to eq([type])
    expect(by_name.map { |row| row[:id] }).to include(all_rows.first[:id])
  end

  it "shows one step template with metrics by default and without them on request" do
    id = service.list_step_templates.step_templates.first[:id]

    with_metrics = service.get_step_template(id)
    lean = service.get_step_template(id, include_metrics: false)

    expect(with_metrics).to include(id: id, metrics: a_hash_including(:total_runs, :notes))
    expect(lean).to include(id: id)
    expect(lean).not_to have_key(:metrics)
  end

  it "answers 404 for an unknown id and 422 for a bad step_type" do
    expect(status_of { service.get_step_template(2_000_000_000) }).to eq(404)
    expect(status_of { service.list_step_templates(step_type: "bogus") }).to eq(422)
  end

  it "answers 401 for an invalid key" do
    Coolhand.configuration.api_key = "not-a-real-key"

    expect(status_of { service.list_step_templates }).to eq(401)
  end

  describe "turn_metrics on a log", if: !ENV.fetch("COOLHAND_SPEC_LIVE_LOG_ID", "").strip.empty? do
    let(:logs) { Coolhand.log_service }
    let(:log_id) { ENV.fetch("COOLHAND_SPEC_LIVE_LOG_ID") }

    it "is absent unless requested and present when it is" do
      expect(logs.get_log(log_id)).not_to have_key(:turn_metrics)

      turns = logs.get_log(log_id, include_turn_metrics: true)[:turn_metrics]

      expect(turns).to be_an(Array).and(all(include(:index, :human, :assistant_requests, :tool_calls, :input_tokens)))
    end
  end
end
