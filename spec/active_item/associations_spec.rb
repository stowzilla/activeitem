# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ActiveItem::Associations do
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
    author_klass = author_class
    Class.new(ActiveItem::Base) do
      self.table_name = 'test-dev-books'
      attr_accessor :title, :author_id

      belongs_to :author, class_name: 'Author', optional: true

      def self.name
        'Book'
      end
    end.tap { |klass| klass.dynamodb = fake_dynamo }
  end

  describe 'belongs_to' do
    it 'defines foreign key accessor' do
      book = book_class.new(title: 'Test', author_id: 'auth-1')
      expect(book.author_id).to eq('auth-1')
    end

    it 'loads associated record' do
      # Stub Author constant for model loader
      stub_const('Author', author_class)
      fake_dynamo.seed('test-dev-authors', 'auth-1', { 'id' => 'auth-1', 'name' => 'Hemingway' })

      book = book_class.new(title: 'Test', author_id: 'auth-1')
      author = book.author
      expect(author).not_to be_nil
      expect(author.name).to eq('Hemingway')
    end

    it 'returns nil when foreign key is nil' do
      book = book_class.new(title: 'Test')
      expect(book.author).to be_nil
    end
  end

  describe 'has_many' do
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

    it 'returns a Relation' do
      stub_const('Child', Class.new(ActiveItem::Base) { self.table_name = 'test-dev-children' })
      parent = parent_class.allocate
      parent.instance_variable_set(:@id, 'p-1')
      parent.instance_variable_set(:@new_record, false)
      parent.instance_variable_set(:@pending_changes, {})
      parent.instance_variable_set(:@previously_changed, {})
      parent.instance_variable_set(:@_preloaded_counts, {})
      parent.instance_variable_set(:@_preloaded_associations, {})

      result = parent.children
      expect(result).to be_a(ActiveItem::Relation)
    end
  end
end
