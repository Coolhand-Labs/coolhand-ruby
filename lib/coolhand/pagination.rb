# frozen_string_literal: true

module Coolhand
  # Paging state for a v2 list endpoint. These send a bare JSON array and carry paging in the
  # `X-Page`, `X-Per-Page`, `X-Total-Count` and `X-Total-Pages` headers, never in the body.
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
    # Mirrors of the v2 controllers' values, used only to fill a header the server did not send.
    DEFAULT_PER_PAGE = 25
    MAX_PER_PAGE = 100

    class << self
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
        ).freeze
      end

      private

      # Falling back to the computed totals here would report "no next page" for a full page, and
      # silently truncate a caller's loop.
      def next_page?(reported_total_pages, current_page, per_page, items)
        return current_page < reported_total_pages if reported_total_pages
        return false unless per_page.positive?

        items.size >= per_page
      end

      # A lower bound, not a count: every earlier page assumed full, plus this page.
      def fallback_total_count(current_page, per_page, items)
        return items.size unless per_page.positive?

        [((current_page - 1) * per_page) + items.size, items.size].max
      end

      def fallback_total_pages(total_count, per_page)
        return total_count.positive? ? 1 : 0 unless per_page.positive?

        (total_count.to_f / per_page).ceil
      end

      # Neither `Integer()` nor `to_i` is safe alone: the first raises on `""`, the second turns
      # `"3.5"` into `3` and `"nonsense"` into `0` — a fabricated, legitimate-looking count.
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
