# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'ActiveItem includes (preloading)' do
  let(:fake_dynamo) { @fake_dynamo }

  let(:author_class) do
    Class.new(ActiveItem::Base) do
      self.table_name = 'test-dev-authors'
      attr_accessor :name

      def self.name
        'Author'
      end
    end.tap { |klass| klass.dynamodb = fake_dynamo }
  end

  let(:book_class) do
    Class.new(ActiveItem::Base) do
      self.table_name = 'test-dev-books'
      attr_accessor :title, :author_id

      belongs_to :author, class_name: 'Author'

      def self.name
        'Book'
      end
    end.tap { |klass| klass.dynamodb = fake_dynamo }
  end

  before do
    stub_const('Author', author_class)
    stub_const('Book', book_class)
  end

  describe '.includes with belongs_to' do
    it 'preloads associated records via batch_find' do
      fake_dynamo.seed('test-dev-authors', 'a1', { 'id' => 'a1', 'name' => 'Hemingway' })
      fake_dynamo.seed('test-dev-authors', 'a2', { 'id' => 'a2', 'name' => 'Fitzgerald' })
      fake_dynamo.seed('test-dev-books', 'b1', { 'id' => 'b1', 'title' => 'Sun Also Rises', 'authorId' => 'a1' })
      fake_dynamo.seed('test-dev-books', 'b2', { 'id' => 'b2', 'title' => 'Gatsby', 'authorId' => 'a2' })

      books = book_class.includes(:author).all.to_a

      # Should have used batch_get_item for authors (not individual get_item calls)
      batch_calls = fake_dynamo.calls.select { |c| c.first == :batch_get_item }
      expect(batch_calls.length).to be >= 1

      # Authors should be cached on the records
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

    it 'preloads counts for has_many associations' do
      fake_dynamo.seed('test-dev-parents', 'p1', { 'id' => 'p1', 'name' => 'Parent 1' })

      parents = parent_class.includes(children: :count).all.to_a
      expect(parents.first._preloaded_counts[:children]).to be_a(Integer)
    end
  end
end
