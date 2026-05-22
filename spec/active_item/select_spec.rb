# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'ActiveItem Relation#select' do
  let(:dynamo_client) { @dynamo_client }

  let(:model_class) do
    Class.new(ActiveItem::Base) do
      self.table_name = 'test-dev-items'
      attr_accessor :name, :status, :description

      indexes('StatusIndex' => { partition_key: 'status' })

      def self.name
        'Item'
      end
    end.tap { |klass| klass.dynamodb = dynamo_client }
  end

  it 'stores select_attributes on the relation' do
    relation = model_class.all.select(:name, :status)
    expect(relation.select_attributes).to eq(%i[name status])
  end

  it 'includes projection_expression in scan params via explain' do
    result = model_class.where(name: 'test').select(:name, :status).explain
    expect(result[:params][:projection_expression]).not_to be_nil
  end

  it 'includes projection_expression in query params via explain' do
    result = model_class.where(status: 'active').select(:name).explain
    expect(result[:params][:projection_expression]).not_to be_nil
  end

  it 'always includes primary key in projection' do
    result = model_class.where(name: 'test').select(:name).explain
    result[:params][:projection_expression]
    names = result[:params][:expression_attribute_names]

    expect(names.values).to include('id')
  end

  it 'delegates to Enumerable#select when block given' do
    dynamo_client.put_item(table_name: 'test-dev-items', item: { 'id' => 'i1', 'name' => 'Alpha', 'status' => 'active' })
    dynamo_client.put_item(table_name: 'test-dev-items', item: { 'id' => 'i2', 'name' => 'Beta', 'status' => 'inactive' })

    results = model_class.all.select { |r| r.status == 'active' }
    expect(results.length).to eq(1)
    expect(results.first.name).to eq('Alpha')
  end

  it 'is chainable with where' do
    relation = model_class.where(status: 'active').select(:name)
    expect(relation.select_attributes).to eq([:name])
    expect(relation.conditions).to eq({ status: 'active' })
  end
end
