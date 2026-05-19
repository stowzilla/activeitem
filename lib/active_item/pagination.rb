# frozen_string_literal: true

module ActiveItem
  module Pagination
    DEFAULT_PER_PAGE = 25
    MAX_PER_PAGE = 100

    def self.paginate_array(items, cursor = nil, per_page: DEFAULT_PER_PAGE)
      per_page = [[per_page.to_i, 1].max, MAX_PER_PAGE].min

      if cursor && !cursor.empty?
        cursor_time, cursor_id = cursor.split('|', 2)
        items = items.drop_while { |i| ([(i.created_at || ''), i.id] <=> [cursor_time, cursor_id]) >= 0 }
      end

      page_items = items.first(per_page)
      has_more = items.length > per_page
      last = page_items.last
      next_cursor = has_more && last ? "#{last.created_at}|#{last.id}" : nil

      PaginatedResult.new(items: page_items, next_cursor: next_cursor, per_page: per_page)
    end

    class PaginatedResult
      include Enumerable

      attr_reader :items, :next_cursor, :per_page

      def initialize(items:, next_cursor:, per_page:)
        @items = items
        @next_cursor = next_cursor
        @per_page = per_page
      end

      def has_more?
        !next_cursor.nil?
      end

      def pagination_metadata
        { next_cursor: next_cursor, has_more: has_more?, per_page: per_page }
      end

      def each(&block) = items.each(&block)
      def length = items.length
      alias_method :size, :length
      alias_method :count, :length
      def empty? = items.empty?
      def to_a = items
    end
  end
end
