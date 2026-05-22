# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'ActiveItem batch_find unprocessed keys' do
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

  it 'retries unprocessed keys with exponential backoff' do
    dynamo_client.put_item(table_name: "#{TABLE_PREFIX}-widgets", item: { 'id' => 'w1', 'name' => 'Alpha' })
    dynamo_client.put_item(table_name: "#{TABLE_PREFIX}-widgets", item: { 'id' => 'w2', 'name' => 'Beta' })

    call_count = 0
    allow(dynamo_client).to receive(:batch_get_item).and_wrap_original do |method, params|
      call_count += 1
      if call_count == 1
        # Simulate throttling: return w1 but mark w2 as unprocessed
        Aws::DynamoDB::Types::BatchGetItemOutput.new(
          responses: { "#{TABLE_PREFIX}-widgets" => [{ 'id' => 'w1', 'name' => 'Alpha' }] },
          unprocessed_keys: { "#{TABLE_PREFIX}-widgets" => { keys: [{ 'id' => 'w2' }] } }
        )
      else
        method.call(params)
      end
    end

    allow_any_instance_of(Object).to receive(:sleep)

    results = model_class.batch_find(%w[w1 w2])
    expect(results.length).to eq(2)
    expect(call_count).to eq(2)
  end

  it 'gives up after max retries' do
    allow(dynamo_client).to receive(:batch_get_item).and_return(
      Aws::DynamoDB::Types::BatchGetItemOutput.new(
        responses: { "#{TABLE_PREFIX}-widgets" => [] },
        unprocessed_keys: { "#{TABLE_PREFIX}-widgets" => { keys: [{ 'id' => 'w1' }] } }
      )
    )
    allow_any_instance_of(Object).to receive(:sleep)

    results = model_class.batch_find(['w1'])
    expect(results).to eq([])
  end
end
