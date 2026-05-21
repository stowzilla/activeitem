# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'ActiveItem batch_find' do
  let(:fake_dynamo) { @fake_dynamo }

  let(:model_class) do
    Class.new(ActiveItem::Base) do
      self.table_name = 'test-dev-widgets'
      attr_accessor :name

      def self.name
        'Widget'
      end
    end.tap { |klass| klass.dynamodb = fake_dynamo }
  end

  it 'returns multiple records by ID' do
    fake_dynamo.seed('test-dev-widgets', 'w1', { 'id' => 'w1', 'name' => 'Alpha' })
    fake_dynamo.seed('test-dev-widgets', 'w2', { 'id' => 'w2', 'name' => 'Beta' })

    results = model_class.batch_find(['w1', 'w2'])
    expect(results.length).to eq(2)
    expect(results.map(&:name)).to contain_exactly('Alpha', 'Beta')
  end

  it 'returns empty array for empty input' do
    expect(model_class.batch_find([])).to eq([])
  end

  it 'silently skips IDs not found' do
    fake_dynamo.seed('test-dev-widgets', 'w1', { 'id' => 'w1', 'name' => 'Alpha' })

    results = model_class.batch_find(['w1', 'missing'])
    expect(results.length).to eq(1)
    expect(results.first.name).to eq('Alpha')
  end

  it 'marks returned records as persisted' do
    fake_dynamo.seed('test-dev-widgets', 'w1', { 'id' => 'w1', 'name' => 'Alpha' })

    results = model_class.batch_find(['w1'])
    expect(results.first.persisted?).to be true
  end

  it 'batches requests in chunks of 100' do
    # Seed 101 items
    101.times { |i| fake_dynamo.seed('test-dev-widgets', "w#{i}", { 'id' => "w#{i}", 'name' => "Item #{i}" }) }

    ids = 101.times.map { |i| "w#{i}" }
    results = model_class.batch_find(ids)
    expect(results.length).to eq(101)

    # Should have made at least 2 batch_get_item calls
    batch_calls = fake_dynamo.calls.select { |c| c.first == :batch_get_item }
    expect(batch_calls.length).to eq(2)
  end
end
