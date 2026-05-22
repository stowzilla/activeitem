# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'ActiveItem Relation#load' do
  let(:dynamo_client) { @dynamo_client }

  let(:model_class) do
    Class.new(ActiveItem::Base) do
      self.table_name = 'test-dev-items'
      attr_accessor :name, :status

      indexes('StatusIndex' => { partition_key: 'status' })

      def self.name
        'Item'
      end
    end.tap { |klass| klass.dynamodb = dynamo_client }
  end

  it 'returns an array of records' do
    dynamo_client.put_item(table_name: 'test-dev-items', item: { 'id' => 'i1', 'name' => 'Alpha', 'status' => 'active' })
    dynamo_client.put_item(table_name: 'test-dev-items', item: { 'id' => 'i2', 'name' => 'Beta', 'status' => 'active' })

    results = model_class.all.load
    expect(results).to be_an(Array)
    expect(results.length).to eq(2)
  end

  it 'returns empty array when no records' do
    results = model_class.all.load
    expect(results).to eq([])
  end

  it 'returns fully hydrated records' do
    dynamo_client.put_item(table_name: 'test-dev-items', item: { 'id' => 'i1', 'name' => 'Alpha', 'status' => 'active' })

    results = model_class.all.load
    expect(results.first.name).to eq('Alpha')
    expect(results.first.status).to eq('active')
  end
end
