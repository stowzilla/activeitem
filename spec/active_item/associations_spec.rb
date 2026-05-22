# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ActiveItem::Associations do
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

      belongs_to :author, class_name: 'Author', optional: true

      def self.name
        'Book'
      end
    end.tap { |klass| klass.dynamodb = dynamo_client }
  end

  describe 'belongs_to' do
    it 'defines foreign key accessor' do
      book = book_class.new(title: 'Test', author_id: 'auth-1')
      expect(book.author_id).to eq('auth-1')
    end

    it 'loads associated record' do
      stub_const('Author', author_class)
      dynamo_client.put_item(table_name: 'test-dev-authors', item: { 'id' => 'auth-1', 'name' => 'Hemingway' })

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
      end.tap { |klass| klass.dynamodb = dynamo_client }
    end

    it 'returns a Relation' do
      stub_const('Child', Class.new(ActiveItem::Base) {
        self.table_name = 'test-dev-children'
        def self.name; 'Child'; end
      }.tap { |k| k.dynamodb = dynamo_client })

      parent = parent_class.new(name: 'Test')
      parent.save

      result = parent.children
      expect(result).to be_a(ActiveItem::Relation)
    end
  end
end
