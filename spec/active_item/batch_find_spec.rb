# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'ActiveItem batch_find' do
  let(:dynamo_client) { @dynamo_client }

  let(:model_class) do
    Class.new(ActiveItem::Base) do
      self.table_name = "#{TABLE_PREFIX}-widgets"
      attr_accessor :name

      def self.name
        'Widget'
      end
    end.tap { |klass| klass.dynamodb = dynamo_client }
  end

  it 'returns multiple records by ID' do
    dynamo_client.put_item(table_name: "#{TABLE_PREFIX}-widgets", item: { 'id' => 'w1', 'name' => 'Alpha' })
    dynamo_client.put_item(table_name: "#{TABLE_PREFIX}-widgets", item: { 'id' => 'w2', 'name' => 'Beta' })

    results = model_class.batch_find(['w1', 'w2'])
    expect(results.length).to eq(2)
    expect(results.map(&:name)).to contain_exactly('Alpha', 'Beta')
  end

  it 'returns empty array for empty input' do
    expect(model_class.batch_find([])).to eq([])
  end

  it 'silently skips IDs not found' do
    dynamo_client.put_item(table_name: "#{TABLE_PREFIX}-widgets", item: { 'id' => 'w1', 'name' => 'Alpha' })

    results = model_class.batch_find(['w1', 'missing'])
    expect(results.length).to eq(1)
    expect(results.first.name).to eq('Alpha')
  end

  it 'marks returned records as persisted' do
    dynamo_client.put_item(table_name: "#{TABLE_PREFIX}-widgets", item: { 'id' => 'w1', 'name' => 'Alpha' })

    results = model_class.batch_find(['w1'])
    expect(results.first.persisted?).to be true
  end

  it 'batches requests in chunks of 100' do
    101.times { |i| dynamo_client.put_item(table_name: "#{TABLE_PREFIX}-widgets", item: { 'id' => "w#{i}", 'name' => "Item #{i}" }) }

    ids = 101.times.map { |i| "w#{i}" }
    results = model_class.batch_find(ids)
    expect(results.length).to eq(101)
  end
end
