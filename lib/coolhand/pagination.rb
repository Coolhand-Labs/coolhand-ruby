# frozen_string_literal: true

module Coolhand
  # Paging state for a v2 list endpoint.
  #
  # These endpoints render a bare JSON array on the wire and carry their paging state in the
  # `X-Page`, `X-Per-Page`, `X-Total-Count` and `X-Total-Pages` response headers, so this is built
  # from the response rather than from the body — and never from the size of the array, which only
  # ever describes the page in hand.
  Pagination = Struct.new(
    :current_page,
    :per_page,
    :total_count,
    :total_pages,
    :has_next_page,
    :has_prev_page,
    keyword_init: true
  )

  class Pagination
    # DEFAULT_PER_PAGE / MAX_PER_PAGE as the v2 list controllers apply them. Mirrored here only to
    # fill in a header the server did not send; whenever the server states a value, it wins.
    DEFAULT_PER_PAGE = 25
    MAX_PER_PAGE = 100

    class << self
      # @param response [Net::HTTPResponse] the list response, read for its pagination headers.
      # @param items [Array] the page actually returned, used only as evidence for the fallbacks.
      # @param page [Integer, nil] the caller's requested page, used only as a fallback value.
      # @param per [Integer, nil] the caller's requested page size, used only as a fallback value.
      def from_headers(response, items:, page: nil, per: nil)
        requested_page = positive_int(page) || 1
        requested_per = [positive_int(per) || DEFAULT_PER_PAGE, MAX_PER_PAGE].min

        current_page = header_int(response, "X-Page") || requested_page
        per_page = header_int(response, "X-Per-Page") || requested_per
        reported_total_pages = header_int(response, "X-Total-Pages")
        total_count = header_int(response, "X-Total-Count") || fallback_total_count(current_page, per_page, items)
        total_pages = reported_total_pages || fallback_total_pages(total_count, per_page)

        new(
          current_page: current_page,
          per_page: per_page,
          total_count: total_count,
          total_pages: total_pages,
          has_next_page: next_page?(reported_total_pages, current_page, per_page, items),
          has_prev_page: current_page > 1
        )
      end

      private

      # The server's page count is authoritative whenever it sends one, so it is read rather than
      # recomputed. Without it the totals above are only a lower bound, and comparing against them
      # reports "no next page" for a page that is plainly full - a caller looping on has_next_page
      # would stop early and silently drop the rest. A full page is the honest signal there.
      def next_page?(reported_total_pages, current_page, per_page, items)
        return current_page < reported_total_pages if reported_total_pages
        return false unless per_page.positive?

        items.size >= per_page
      end

      # Only reached when a total header is missing or unparseable, which
      # `GET /api/v2/llm_request_templates` never does — it has no `include_total` opt-out. It
      # reports a lower bound (every earlier page assumed full, plus this page) rather than letting
      # a bad header claim zero results next to a page that plainly has some. Offset paging can
      # only return rows at all if that many rows precede them, so the bound holds.
      def fallback_total_count(current_page, per_page, items)
        return items.size unless per_page.positive?

        ((current_page - 1) * per_page) + items.size
      end

      def fallback_total_pages(total_count, per_page)
        return total_count.positive? ? 1 : 0 unless per_page.positive?

        (total_count.to_f / per_page).ceil
      end

      # Treats an absent, empty, negative, fractional or garbage header as absent. Neither
      # `Integer()` nor `String#to_i` is safe here on its own: the first raises on `""`, and the
      # second turns `"3.5"` into `3` and `"nonsense"` into `0` — a fabricated legitimate-looking
      # count.
      def header_int(response, name)
        raw = response[name]
        return nil if raw.nil?

        value = raw.strip
        value.match?(/\A\d+\z/) ? value.to_i : nil
      end

      def positive_int(value)
        integer = Integer(value, exception: false)
        integer&.positive? ? integer : nil
      end
    end
  end
end
