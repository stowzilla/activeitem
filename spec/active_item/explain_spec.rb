# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'ActiveItem Relation#explain' do
  let(:dynamo_client) { @dynamo_client }

  let(:model_class) do
    Class.new(ActiveItem::Base) do
      self.table_name = "#{TABLE_PREFIX}-items"
      attr_accessor :name, :status, :customer_id

      indexes(
        'StatusIndex' => { partition_key: 'status', sort_key: 'createdAt' },
        'CustomerIndex' => { partition_key: 'customerId' }
      )

      def self.name
        'Item'
      end
    end.tap { |klass| klass.dynamodb = dynamo_client }
  end

  it 'returns scan for .all' do
    result = model_class.all.explain
    expect(result[:operation]).to eq(:scan)
    expect(result[:table]).to eq("#{TABLE_PREFIX}-items")
  end

  it 'returns query with index for indexed condition' do
    result = model_class.where(status: 'active').explain
    expect(result[:operation]).to eq(:query)
    expect(result[:index]).to eq('StatusIndex')
    expect(result[:params][:key_condition_expression]).to include('#pk = :pk_val')
  end

  it 'returns scan for non-indexed condition' do
    result = model_class.where(name: 'test').explain
    expect(result[:operation]).to eq(:scan)
  end

  it 'includes limit in params' do
    result = model_class.all.limit(10).explain
    expect(result[:params][:limit]).to eq(10)
  end

  it 'returns none for empty relation' do
    result = model_class.none.explain
    expect(result[:operation]).to eq(:none)
  end

  it 'includes not_conditions in filter' do
    result = model_class.where(status: 'active').not(name: 'deleted').explain
    expect(result[:params][:filter_expression]).to include('<>')
  end
end
