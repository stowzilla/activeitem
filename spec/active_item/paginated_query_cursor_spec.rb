# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'paginated query synthetic cursor' do
  let(:dynamo_client) { @dynamo_client }

  let(:model_class) do
    Class.new(ActiveItem::Base) do
      self.table_name = "#{TABLE_PREFIX}-items"
      attr_accessor :customer_id, :status, :name

      indexes('CustomerIndex' => { partition_key: 'customerId' },
              'StatusIndex' => { partition_key: 'status', sort_key: 'createdAt' })

      def self.name
        'Item'
      end
    end.tap { |klass| klass.dynamodb = dynamo_client }
  end

  context 'when items fit within the overfetch limit but exceed per_page' do
    it 'returns has_more and a valid cursor for GSI without sort key' do
      30.times do |i|
        dynamo_client.put_item(table_name: "#{TABLE_PREFIX}-items",
                               item: { 'id' => "synth-#{i.to_s.rjust(3, '0')}", 'customerId' => 'cust-synth',
                                       'status' => 'active', 'name' => "Item #{i}", 'createdAt' => "2024-01-01T00:#{i.to_s.rjust(2, '0')}:00Z" })
      end

      result = model_class.where(customer_id: 'cust-synth').page(nil, per_page: 25)

      expect(result.items.length).to eq(25)
      expect(result.has_more?).to be true
      expect(result.next_cursor).not_to be_nil

      second_page = model_class.where(customer_id: 'cust-synth').page(result.next_cursor, per_page: 25)

      expect(second_page.items.length).to eq(5)
      expect(second_page.has_more?).to be false

      all_ids = (result.items + second_page.items).map(&:id).uniq
      expect(all_ids.length).to eq(30)
    end

    it 'returns has_more and a valid cursor for GSI with sort key' do
      30.times do |i|
        dynamo_client.put_item(table_name: "#{TABLE_PREFIX}-items",
                               item: { 'id' => "synth-sk-#{i.to_s.rjust(3, '0')}", 'customerId' => 'cust-sk2',
                                       'status' => 'synth-active', 'name' => "Item #{i}", 'createdAt' => "2024-01-01T00:#{i.to_s.rjust(2, '0')}:00Z" })
      end

      result = model_class.where(status: 'synth-active').page(nil, per_page: 25)

      expect(result.items.length).to eq(25)
      expect(result.has_more?).to be true
      expect(result.next_cursor).not_to be_nil

      second_page = model_class.where(status: 'synth-active').page(result.next_cursor, per_page: 25)

      expect(second_page.items.length).to eq(5)
      expect(second_page.has_more?).to be false

      all_ids = (result.items + second_page.items).map(&:id).uniq
      expect(all_ids.length).to eq(30)
    end
  end
end
