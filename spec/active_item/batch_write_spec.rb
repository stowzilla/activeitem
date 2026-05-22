# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'ActiveItem batch_write' do
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

  it 'writes multiple records to DynamoDB' do
    records = 3.times.map { |i| model_class.new(name: "Item #{i}") }
    model_class.batch_write(records)

    records.each do |r|
      resp = dynamo_client.get_item(table_name: "#{TABLE_PREFIX}-widgets", key: { 'id' => r.id })
      expect(resp.item).not_to be_nil
    end
  end

  it 'assigns IDs and timestamps' do
    records = [model_class.new(name: 'Test')]
    model_class.batch_write(records)

    expect(records.first.id).to match(/\A[0-9a-f-]{36}\z/)
    expect(records.first.created_at).not_to be_nil
    expect(records.first.updated_at).not_to be_nil
  end

  it 'marks records as persisted' do
    records = [model_class.new(name: 'Test')]
    model_class.batch_write(records)

    expect(records.first.persisted?).to be true
    expect(records.first.new_record?).to be false
  end

  it 'returns empty array for empty input' do
    expect(model_class.batch_write([])).to eq([])
  end

  it 'batches in chunks of 25' do
    records = 30.times.map { |i| model_class.new(name: "Item #{i}") }
    model_class.batch_write(records)

    # Verify all 30 were written
    scan = dynamo_client.scan(table_name: "#{TABLE_PREFIX}-widgets")
    expect(scan.items.length).to eq(30)
  end

  it 'does not run callbacks or validations' do
    callback_ran = false
    klass = Class.new(model_class) do
      before_create :track_callback

      private

      def track_callback
        # This should NOT run during batch_write
      end
    end
    klass.dynamodb = dynamo_client
    klass.table_name = "#{TABLE_PREFIX}-widgets"

    allow_any_instance_of(klass).to receive(:track_callback) { callback_ran = true }

    records = [klass.new(name: 'Test')]
    klass.batch_write(records)

    expect(callback_ran).to be false
  end
end
