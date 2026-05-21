# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'ActiveItem Relation#order' do
  let(:fake_dynamo) { @fake_dynamo }

  let(:model_class) do
    Class.new(ActiveItem::Base) do
      self.table_name = 'test-dev-events'
      attr_accessor :customer_id, :event_type

      indexes('CustomerIndex' => { partition_key: 'customerId', sort_key: 'createdAt' })

      def self.name
        'Event'
      end
    end.tap { |klass| klass.dynamodb = fake_dynamo }
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

  it 'passes scan_index_forward false for :desc' do
    model_class.where(customer_id: 'c1').order(:desc).to_a

    query_call = fake_dynamo.calls.find { |c| c.first == :query }
    expect(query_call.last[:scan_index_forward]).to eq(false)
  end

  it 'passes scan_index_forward true for :asc' do
    model_class.where(customer_id: 'c1').order(:asc).to_a

    query_call = fake_dynamo.calls.find { |c| c.first == :query }
    expect(query_call.last[:scan_index_forward]).to eq(true)
  end

  it 'is chainable with other methods' do
    relation = model_class.where(customer_id: 'c1').order(:desc).limit(5)
    expect(relation.order_direction).to eq(:desc)
    expect(relation.limit_value).to eq(5)
  end
end
