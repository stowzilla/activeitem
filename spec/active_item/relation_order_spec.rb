# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'ActiveItem Relation#order' do
  let(:dynamo_client) { @dynamo_client }

  let(:model_class) do
    Class.new(ActiveItem::Base) do
      self.table_name = 'test-dev-events'
      attr_accessor :customer_id, :event_type

      indexes('CustomerIndex' => { partition_key: 'customerId', sort_key: 'createdAt' })

      def self.name
        'Event'
      end
    end.tap { |klass| klass.dynamodb = dynamo_client }
  end

  it 'sets order_direction to :desc' do
    relation = model_class.where(customer_id: 'c1').order(:desc)
    expect(relation.order_direction).to eq(:desc)
  end

  it 'sets order_direction to :asc' do
    relation = model_class.where(customer_id: 'c1').order(:asc)
    expect(relation.order_direction).to eq(:asc)
  end

  it 'raises on invalid direction' do
    expect { model_class.where(customer_id: 'c1').order(:sideways) }.to raise_error(ArgumentError)
  end

  it 'returns results in descending order' do
    dynamo_client.put_item(table_name: 'test-dev-events', item: { 'id' => 'e1', 'customerId' => 'c1', 'createdAt' => '2024-01-01T00:00:00Z', 'eventType' => 'first' })
    dynamo_client.put_item(table_name: 'test-dev-events', item: { 'id' => 'e2', 'customerId' => 'c1', 'createdAt' => '2024-01-02T00:00:00Z', 'eventType' => 'second' })

    results = model_class.where(customer_id: 'c1').order(:desc).to_a
    expect(results.first.created_at).to be > results.last.created_at
  end

  it 'returns results in ascending order' do
    dynamo_client.put_item(table_name: 'test-dev-events', item: { 'id' => 'e1', 'customerId' => 'c1', 'createdAt' => '2024-01-01T00:00:00Z', 'eventType' => 'first' })
    dynamo_client.put_item(table_name: 'test-dev-events', item: { 'id' => 'e2', 'customerId' => 'c1', 'createdAt' => '2024-01-02T00:00:00Z', 'eventType' => 'second' })

    results = model_class.where(customer_id: 'c1').order(:asc).to_a
    expect(results.first.created_at).to be < results.last.created_at
  end

  it 'is chainable with other methods' do
    relation = model_class.where(customer_id: 'c1').order(:desc).limit(5)
    expect(relation.order_direction).to eq(:desc)
    expect(relation.limit_value).to eq(5)
  end
end
