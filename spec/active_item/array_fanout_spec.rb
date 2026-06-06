# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Array partition key fan-out' do
  let(:dynamo_client) { @dynamo_client }

  let(:event_class) do
    Class.new(ActiveItem::Base) do
      self.table_name = "#{TABLE_PREFIX}-events"
      attr_accessor :customer_id, :created_at, :event_type

      indexes('CustomerIndex' => { partition_key: 'customerId', sort_key: 'createdAt' })

      def self.name
        'Event'
      end
    end.tap { |klass| klass.dynamodb = dynamo_client }
  end

  before do
    stub_const('Event', event_class)

    # Create events for 3 different customers
    [
      { 'id' => 'e1', 'customerId' => 'c1', 'createdAt' => '2024-01-01T00:00:00Z', 'eventType' => 'pickup' },
      { 'id' => 'e2', 'customerId' => 'c1', 'createdAt' => '2024-01-02T00:00:00Z', 'eventType' => 'return' },
      { 'id' => 'e3', 'customerId' => 'c2', 'createdAt' => '2024-01-03T00:00:00Z', 'eventType' => 'pickup' },
      { 'id' => 'e4', 'customerId' => 'c2', 'createdAt' => '2024-01-04T00:00:00Z', 'eventType' => 'billing' },
      { 'id' => 'e5', 'customerId' => 'c3', 'createdAt' => '2024-01-05T00:00:00Z', 'eventType' => 'pickup' }
    ].each do |item|
      dynamo_client.put_item(table_name: "#{TABLE_PREFIX}-events", item: item)
    end
  end

  describe '.where with array partition key' do
    it 'returns records from all specified partitions' do
      results = event_class.where(customer_id: %w[c1 c2], index: 'CustomerIndex').to_a
      expect(results.map(&:id)).to match_array(%w[e1 e2 e3 e4])
    end

    it 'returns empty array for empty partition array' do
      results = event_class.where(customer_id: [], index: 'CustomerIndex').to_a
      expect(results).to eq([])
    end

    it 'works with order(:desc)' do
      results = event_class.where(customer_id: %w[c1 c2], index: 'CustomerIndex').order(:desc).to_a
      created_ats = results.map(&:created_at)
      expect(created_ats).to eq(created_ats.sort.reverse)
    end

    it 'works with order(:asc)' do
      results = event_class.where(customer_id: %w[c1 c2], index: 'CustomerIndex').order(:asc).to_a
      created_ats = results.map(&:created_at)
      expect(created_ats).to eq(created_ats.sort)
    end

    it 'works with limit' do
      results = event_class.where(customer_id: %w[c1 c2 c3], index: 'CustomerIndex').order(:desc).limit(3).to_a
      expect(results.length).to eq(3)
    end

    it 'works with .not conditions' do
      results = event_class.where(customer_id: %w[c1 c2], index: 'CustomerIndex').not(event_type: 'pickup').to_a
      expect(results.map(&:id)).to match_array(%w[e2 e4])
    end
  end

  describe '.count with array partition key' do
    it 'returns total count across partitions' do
      count = event_class.where(customer_id: %w[c1 c2], index: 'CustomerIndex').count
      expect(count).to eq(4)
    end

    it 'returns 0 for empty array' do
      count = event_class.where(customer_id: [], index: 'CustomerIndex').count
      expect(count).to eq(0)
    end
  end

  describe '.page with array partition key' do
    it 'returns first page of merged results' do
      result = event_class.where(customer_id: %w[c1 c2 c3], index: 'CustomerIndex').order(:desc).page(nil, per_page: 3)
      expect(result.items.length).to eq(3)
      expect(result.has_more?).to be true
      expect(result.next_cursor).not_to be_nil
    end

    it 'returns second page using cursor' do
      first = event_class.where(customer_id: %w[c1 c2 c3], index: 'CustomerIndex').order(:desc).page(nil, per_page: 3)
      second = event_class.where(customer_id: %w[c1 c2 c3], index: 'CustomerIndex').order(:desc).page(first.next_cursor, per_page: 3)
      expect(second.items.length).to eq(2)
      expect(second.has_more?).to be false

      # No overlap between pages
      first_ids = first.items.map(&:id)
      second_ids = second.items.map(&:id)
      expect(first_ids & second_ids).to be_empty
    end

    it 'maintains sort order across pages' do
      first = event_class.where(customer_id: %w[c1 c2 c3], index: 'CustomerIndex').order(:desc).page(nil, per_page: 2)
      second = event_class.where(customer_id: %w[c1 c2 c3], index: 'CustomerIndex').order(:desc).page(first.next_cursor, per_page: 2)

      all_created_ats = (first.items + second.items).map(&:created_at)
      expect(all_created_ats).to eq(all_created_ats.sort.reverse)
    end
  end
end
