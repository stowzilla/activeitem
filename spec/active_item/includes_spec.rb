# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'ActiveItem includes (preloading)' do
  let(:dynamo_client) { @dynamo_client }

  let(:author_class) do
    Class.new(ActiveItem::Base) do
      self.table_name = 'test-dev-authors'
      attr_accessor :name

      def self.name
        'Author'
      end
    end.tap { |klass| klass.dynamodb = dynamo_client }
  end

  let(:book_class) do
    Class.new(ActiveItem::Base) do
      self.table_name = 'test-dev-books'
      attr_accessor :title, :author_id

      belongs_to :author, class_name: 'Author'

      def self.name
        'Book'
      end
    end.tap { |klass| klass.dynamodb = dynamo_client }
  end

  before do
    stub_const('Author', author_class)
    stub_const('Book', book_class)
  end

  describe '.includes with belongs_to' do
    it 'preloads associated records' do
      dynamo_client.put_item(table_name: 'test-dev-authors', item: { 'id' => 'a1', 'name' => 'Hemingway' })
      dynamo_client.put_item(table_name: 'test-dev-authors', item: { 'id' => 'a2', 'name' => 'Fitzgerald' })
      dynamo_client.put_item(table_name: 'test-dev-books', item: { 'id' => 'b1', 'title' => 'Sun Also Rises', 'authorId' => 'a1' })
      dynamo_client.put_item(table_name: 'test-dev-books', item: { 'id' => 'b2', 'title' => 'Gatsby', 'authorId' => 'a2' })

      books = book_class.includes(:author).all.to_a

      books.each do |book|
        cached = book.instance_variable_get(:@_association_cache_author)
        expect(cached).not_to be_nil
      end
    end
  end

  describe '.includes returns a Relation' do
    it 'is chainable' do
      relation = book_class.includes(:author)
      expect(relation).to be_a(ActiveItem::Relation)
    end

    it 'can be combined with where' do
      relation = book_class.includes(:author).where(title: 'Gatsby')
      expect(relation).to be_a(ActiveItem::Relation)
    end
  end

  describe '.includes with has_many :count' do
    let(:parent_class) do
      Class.new(ActiveItem::Base) do
        self.table_name = 'test-dev-parents'
        attr_accessor :name

        has_many :children, class_name: 'Child', foreign_key: 'parent_id', index: 'ParentIndex'

        def self.name
          'Parent'
        end
      end.tap { |klass| klass.dynamodb = dynamo_client }
    end

    let(:child_class) do
      Class.new(ActiveItem::Base) do
        self.table_name = 'test-dev-children'
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

    it 'preloads counts for has_many associations' do
      dynamo_client.put_item(table_name: 'test-dev-parents', item: { 'id' => 'p1', 'name' => 'Parent 1' })
      dynamo_client.put_item(table_name: 'test-dev-children', item: { 'id' => 'c1', 'parentId' => 'p1' })
      dynamo_client.put_item(table_name: 'test-dev-children', item: { 'id' => 'c2', 'parentId' => 'p1' })

      parents = parent_class.includes(children: :count).all.to_a
      expect(parents.first._preloaded_counts[:children]).to eq(2)
    end
  end
end
