# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'ActiveItem batch_write' do
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

  it 'writes multiple records in one batch' do
    records = 3.times.map { |i| model_class.new(name: "Item #{i}") }
    result = model_class.batch_write(records)

    expect(result.length).to eq(3)
    batch_calls = fake_dynamo.calls.select { |c| c.first == :batch_write_item }
    expect(batch_calls.length).to eq(1)
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

    batch_calls = fake_dynamo.calls.select { |c| c.first == :batch_write_item }
    expect(batch_calls.length).to eq(2)
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
    klass.dynamodb = fake_dynamo
    klass.table_name = 'test-dev-widgets'

    allow_any_instance_of(klass).to receive(:track_callback) { callback_ran = true }

    records = [klass.new(name: 'Test')]
    klass.batch_write(records)

    expect(callback_ran).to be false
  end
end
