# frozen_string_literal: true

# Opt-in live suite: real HTTP against a real Coolhand server, no stubbing anywhere.
#
# Deliberately named `_live.rb` rather than `_spec.rb` so RSpec's default pattern never picks it
# up. `bundle exec rspec` — which is what CI runs, with neither a server nor a private key — skips
# it by not matching it, rather than by any example being marked pending or skipped. Run it with
# `bundle exec rake spec:live`.
#
# Every request it makes is a read. Nothing here inserts or mutates a record.

require "spec_helper"

BASE_URL = ENV.fetch("COOLHAND_LIVE_BASE_URL") do
  raise "COOLHAND_LIVE_BASE_URL is required, e.g. http://127.0.0.1:3000/api"
end

# Read at the moment of use and never written down anywhere: not into a fixture, a log line, a
# commit or a PR body.
API_KEY = ENV.fetch("COOLHAND_LIVE_API_KEY") do
  raise "COOLHAND_LIVE_API_KEY is required (the client's private API key)"
end

# The two buckets every Coolhand client is created with.
SYSTEM_TEMPLATE_NAMES = ["Unmatched", "Ignored API Calls"].freeze

# Exactly the fields the API definition declares on a list row - asserted as a set, so a field
# quietly disappearing from the response fails here rather than turning into a nil downstream.
LIST_FIELDS = %i[
  id name status version group workload_id workload_name
  system_template deprecated_at log_count created_at updated_at
].freeze

DETAIL_ONLY_FIELDS = %i[user_prompt_pattern system_prompt_pattern].freeze

RSpec.describe Coolhand::TemplateService, :live do
  let(:service) { described_class.new }

  before do
    # Set the configuration directly rather than through Coolhand.configure, which would also
    # patch Net::HTTP for interception - irrelevant here, and a global side effect.
    Coolhand.configuration.base_url = BASE_URL
    Coolhand.configuration.api_key = API_KEY
    Coolhand.configuration.silent = true
  end

  describe "#search_templates" do
    it "returns an empty page by default, because this client's only templates are system ones" do
      result = service.search_templates

      expect(result.templates).to eq([])
    end

    it "hides system templates unless they are asked for" do
      names = service.search_templates.templates.map { |template| template[:name] }

      expect(names).not_to include(*SYSTEM_TEMPLATE_NAMES)
    end

    it "reports the server's own zero-result pagination rather than inventing one" do
      pagination = service.search_templates.pagination

      expect(pagination).to have_attributes(
        current_page: 1,
        total_count: 0,
        # The server sends X-Total-Pages: 1 next to X-Total-Count: 0. Read, not second-guessed.
        total_pages: 1,
        has_next_page: false,
        has_prev_page: false
      )
    end

    it "returns both system buckets when include_system is passed" do
      templates = service.search_templates(include_system: true).templates

      expect(templates.map { |template| template[:name] }).to match_array(SYSTEM_TEMPLATE_NAMES)
      expect(templates).to all(include(system_template: true))
    end

    it "counts the system buckets in the pagination totals" do
      pagination = service.search_templates(include_system: true).pagination

      expect(pagination.total_count).to eq(2)
    end

    it "renders exactly the fields the API definition declares, and no prompt patterns" do
      template = service.search_templates(include_system: true).templates.first

      expect(template.keys).to match_array(LIST_FIELDS)
    end

    it "types every declared field the way the definition does" do
      template = service.search_templates(include_system: true).templates.first

      expect(template[:id]).to be_a(String)
      expect(template[:name]).to be_a(String)
      expect(template[:workload_id]).to be_a(String)
      expect(template[:workload_name]).to be_a(String)
      expect(template[:log_count]).to be_a(Integer)
      expect(template[:created_at]).to be_a(String)
      expect(template[:system_template]).to be(true)
    end

    it "paginates from the headers across a real multi-page result" do
      first = service.search_templates(include_system: true, per: 1, page: 1)
      second = service.search_templates(include_system: true, per: 1, page: 2)

      expect(first.templates.size).to eq(1)
      expect(first.pagination).to have_attributes(
        current_page: 1, per_page: 1, total_count: 2, total_pages: 2,
        has_next_page: true, has_prev_page: false
      )
      expect(second.pagination).to have_attributes(
        current_page: 2, has_next_page: false, has_prev_page: true
      )
      expect(second.templates.first[:id]).not_to eq(first.templates.first[:id])
    end

    it "narrows to a real name with the search parameter" do
      templates = service.search_templates(include_system: true, search: "unmatch").templates

      expect(templates.map { |template| template[:name] }).to eq(["Unmatched"])
    end

    it "raises a 422 for a status the endpoint does not recognise" do
      expect { service.search_templates(status: "bogus") }
        .to raise_error(Coolhand::HttpError) { |error| expect(error.status).to eq(422) }
    end

    it "raises a 401 for a key the server rejects" do
      Coolhand.configuration.api_key = "definitely-not-a-valid-key"

      expect { service.search_templates }
        .to raise_error(Coolhand::HttpError) { |error| expect(error.status).to eq(401) }
    end
  end

  describe "#get_template" do
    let(:system_template) { service.search_templates(include_system: true).templates.first }

    it "reaches a system template by id with no opt-in flag" do
      fetched = service.get_template(system_template[:id])

      expect(fetched[:id]).to eq(system_template[:id])
      expect(fetched[:system_template]).to be(true)
    end

    it "adds the prompt patterns the list omits, and nothing else" do
      fetched = service.get_template(system_template[:id])

      expect(fetched.keys).to match_array(LIST_FIELDS + DETAIL_ONLY_FIELDS)
    end

    it "agrees with the list row on every field they share" do
      fetched = service.get_template(system_template[:id])

      expect(fetched.slice(*LIST_FIELDS)).to eq(system_template)
    end

    it "raises a 404 for an id this client cannot see, without disclosing whether it exists" do
      expect { service.get_template("definitelynotarealhashid") }
        .to raise_error(Coolhand::HttpError) { |error| expect(error.status).to eq(404) }
    end
  end
end
