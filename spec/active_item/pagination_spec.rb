# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ActiveItem::Pagination do
  let(:items) do
    5.times.map do |i|
      item = OpenStruct.new(id: "item-#{i}", created_at: "2024-01-0#{5 - i}T00:00:00Z")
      item
    end
  end

  describe '.paginate_array' do
    it 'returns first page of items' do
      result = ActiveItem::Pagination.paginate_array(items, nil, per_page: 3)
      expect(result.items.length).to eq(3)
      expect(result.has_more?).to be true
      expect(result.next_cursor).not_to be_nil
    end

    it 'returns all items when per_page exceeds count' do
      result = ActiveItem::Pagination.paginate_array(items, nil, per_page: 10)
      expect(result.items.length).to eq(5)
      expect(result.has_more?).to be false
      expect(result.next_cursor).to be_nil
    end

    it 'paginates with cursor' do
      first_page = ActiveItem::Pagination.paginate_array(items, nil, per_page: 2)
      second_page = ActiveItem::Pagination.paginate_array(items, first_page.next_cursor, per_page: 2)
      expect(second_page.items.length).to eq(2)
      expect(second_page.items.first.id).not_to eq(first_page.items.first.id)
    end

    it 'clamps per_page to MAX_PER_PAGE' do
      result = ActiveItem::Pagination.paginate_array(items, nil, per_page: 999)
      expect(result.per_page).to eq(100)
    end

    it 'clamps per_page minimum to 1' do
      result = ActiveItem::Pagination.paginate_array(items, nil, per_page: 0)
      expect(result.per_page).to eq(1)
    end
  end

  describe ActiveItem::Pagination::PaginatedResult do
    it 'is enumerable' do
      result = ActiveItem::Pagination::PaginatedResult.new(items: items, next_cursor: nil, per_page: 25)
      expect(result.map(&:id)).to eq(items.map(&:id))
    end

    it 'provides pagination_metadata' do
      result = ActiveItem::Pagination::PaginatedResult.new(items: items, next_cursor: 'abc', per_page: 5)
      meta = result.pagination_metadata
      expect(meta[:next_cursor]).to eq('abc')
      expect(meta[:has_more]).to be true
      expect(meta[:per_page]).to eq(5)
    end
  end
end
