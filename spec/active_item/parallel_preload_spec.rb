# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'ActiveItem parallel preload' do
  let(:fake_dynamo) { @fake_dynamo }

  let(:parent_class) do
    Class.new(ActiveItem::Base) do
      self.table_name = 'test-dev-parents'
      attr_accessor :name

      has_many :children, class_name: 'Child', foreign_key: 'parent_id', index: 'ParentIndex'

      def self.name
        'Parent'
      end
    end.tap { |klass| klass.dynamodb = fake_dynamo }
  end

  let(:child_class) do
    Class.new(ActiveItem::Base) do
      self.table_name = 'test-dev-children'
      attr_accessor :parent_id

      indexes('ParentIndex' => { partition_key: 'parentId' })

      def self.name
        'Child'
      end
    end.tap { |klass| klass.dynamodb = fake_dynamo }
  end

  before do
    stub_const('Parent', parent_class)
    stub_const('Child', child_class)
  end

  it 'uses parallel queries for count preloading with multiple parents' do
    5.times { |i| fake_dynamo.seed('test-dev-parents', "p#{i}", { 'id' => "p#{i}", 'name' => "Parent #{i}" }) }

    parents = parent_class.includes(children: :count).all.to_a

    # Each parent should have a preloaded count
    parents.each do |parent|
      expect(parent._preloaded_counts).to have_key(:children)
    end
  end

  it 'handles empty parent set gracefully' do
    parents = parent_class.includes(children: :count).all.to_a
    expect(parents).to eq([])
  end

  it 'preloads counts correctly when children exist' do
    fake_dynamo.seed('test-dev-parents', 'p1', { 'id' => 'p1', 'name' => 'Parent 1' })

    # Stub query to return a count
    allow(fake_dynamo).to receive(:query).and_return(
      OpenStruct.new(count: 3, items: [], last_evaluated_key: nil)
    )

    parents = parent_class.includes(children: :count).all.to_a
    expect(parents.first._preloaded_counts[:children]).to eq(3)
  end
end
