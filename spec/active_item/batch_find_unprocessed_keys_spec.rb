# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'ActiveItem batch_find unprocessed keys' do
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

  it 'retries unprocessed keys with exponential backoff' do
    fake_dynamo.seed('test-dev-widgets', 'w1', { 'id' => 'w1', 'name' => 'Alpha' })
    fake_dynamo.seed('test-dev-widgets', 'w2', { 'id' => 'w2', 'name' => 'Beta' })

    call_count = 0
    allow(fake_dynamo).to receive(:batch_get_item).and_wrap_original do |method, params|
      call_count += 1
      if call_count == 1
        # First call: return w1 but mark w2 as unprocessed
        OpenStruct.new(
          responses: { 'test-dev-widgets' => [{ 'id' => 'w1', 'name' => 'Alpha' }] },
          unprocessed_keys: { 'test-dev-widgets' => { keys: [{ 'id' => 'w2' }] } }
        )
      else
        # Retry: return w2
        OpenStruct.new(
          responses: { 'test-dev-widgets' => [{ 'id' => 'w2', 'name' => 'Beta' }] },
          unprocessed_keys: {}
        )
      end
    end

    # Stub sleep to avoid actual delays in tests
    allow_any_instance_of(Object).to receive(:sleep)

    results = model_class.batch_find(['w1', 'w2'])
    expect(results.length).to eq(2)
    expect(call_count).to eq(2)
  end

  it 'gives up after max retries' do
    allow(fake_dynamo).to receive(:batch_get_item).and_return(
      OpenStruct.new(
        responses: { 'test-dev-widgets' => [] },
        unprocessed_keys: { 'test-dev-widgets' => { keys: [{ 'id' => 'w1' }] } }
      )
    )
    allow_any_instance_of(Object).to receive(:sleep)

    results = model_class.batch_find(['w1'])
    # After max retries it stops — returns whatever it collected
    expect(results).to eq([])
  end
end
