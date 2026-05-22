# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'ActiveItem parallel preload' do
  let(:dynamo_client) { @dynamo_client }

  let(:parent_class) do
    Class.new(ActiveItem::Base) do
      self.table_name = "#{TABLE_PREFIX}-parents"
      attr_accessor :name

      has_many :children, class_name: 'Child', foreign_key: 'parent_id', index: 'ParentIndex'

      def self.name
        'Parent'
      end
    end.tap { |klass| klass.dynamodb = dynamo_client }
  end

  let(:child_class) do
    Class.new(ActiveItem::Base) do
      self.table_name = "#{TABLE_PREFIX}-children"
      attr_accessor :parent_id

      indexes('ParentIndex' => { partition_key: 'parentId' })

      def self.name
        'Child'
      end
    end.tap { |klass| klass.dynamodb = dynamo_client }
  end

  before do
    stub_const('Parent', parent_class)
    stub_const('Child', child_class)
  end

  it 'preloads counts for multiple parents' do
    3.times do |i|
      dynamo_client.put_item(table_name: "#{TABLE_PREFIX}-parents", item: { 'id' => "p#{i}", 'name' => "Parent #{i}" })
      2.times do |j|
        dynamo_client.put_item(table_name: "#{TABLE_PREFIX}-children", item: { 'id' => "c#{i}-#{j}", 'parentId' => "p#{i}" })
      end
    end

    parents = parent_class.includes(children: :count).all.to_a

    parents.each do |parent|
      expect(parent._preloaded_counts).to have_key(:children)
      expect(parent._preloaded_counts[:children]).to eq(2)
    end
  end

  it 'handles empty parent set gracefully' do
    parents = parent_class.includes(children: :count).all.to_a
    expect(parents).to eq([])
  end
end
