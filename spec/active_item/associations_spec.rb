# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ActiveItem::Associations do
  let(:dynamo_client) { @dynamo_client }

  let(:author_class) do
    Class.new(ActiveItem::Base) do
      self.table_name = "#{TABLE_PREFIX}-authors"
      attr_accessor :name

      def self.name
        'Author'
      end
    end.tap { |klass| klass.dynamodb = dynamo_client }
  end

  let(:book_class) do
    Class.new(ActiveItem::Base) do
      self.table_name = "#{TABLE_PREFIX}-books"
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
      dynamo_client.put_item(table_name: "#{TABLE_PREFIX}-authors", item: { 'id' => 'auth-1', 'name' => 'Hemingway' })

      book = book_class.new(title: 'Test', author_id: 'auth-1')
      author = book.author
      expect(author).not_to be_nil
      expect(author.name).to eq('Hemingway')
    end

    it 'returns nil when foreign key is nil' do
      book = book_class.new(title: 'Test')
      expect(book.author).to be_nil
    end

    describe 'auto-index registration' do
      it 'registers a conventional index from belongs_to' do
        klass = Class.new(ActiveItem::Base) do
          self.table_name = "#{TABLE_PREFIX}-comments"
          belongs_to :post

          def self.name
            'Comment'
          end
        end
        klass.dynamodb = dynamo_client

        expect(klass.indexes).to include('PostIndex' => { partition_key: 'post_id' })
      end

      it 'registers indexes for multiple belongs_to associations' do
        klass = Class.new(ActiveItem::Base) do
          self.table_name = "#{TABLE_PREFIX}-authorings"
          belongs_to :book
          belongs_to :author

          def self.name
            'Authoring'
          end
        end
        klass.dynamodb = dynamo_client

        expect(klass.indexes).to include(
          'BookIndex' => { partition_key: 'book_id' },
          'AuthorIndex' => { partition_key: 'author_id' }
        )
      end

      it 'suppresses index with index: false' do
        klass = Class.new(ActiveItem::Base) do
          self.table_name = "#{TABLE_PREFIX}-logs"
          belongs_to :user, index: false

          def self.name
            'Log'
          end
        end
        klass.dynamodb = dynamo_client

        expect(klass.indexes.keys).not_to include('UserIndex')
      end

      it 'uses custom index name with index: "CustomName"' do
        klass = Class.new(ActiveItem::Base) do
          self.table_name = "#{TABLE_PREFIX}-items"
          belongs_to :owner, class_name: 'User', index: 'OwnerLookup'

          def self.name
            'Item'
          end
        end
        klass.dynamodb = dynamo_client

        expect(klass.indexes).to include('OwnerLookup' => { partition_key: 'owner_id' })
        expect(klass.indexes.keys).not_to include('OwnerIndex')
      end

      it 'explicit indexes() takes priority over auto-registered' do
        klass = Class.new(ActiveItem::Base) do
          self.table_name = "#{TABLE_PREFIX}-tasks"
          belongs_to :project

          indexes(
            'ProjectIndex' => { partition_key: 'project_id', sort_key: 'created_at' }
          )

          def self.name
            'Task'
          end
        end
        klass.dynamodb = dynamo_client

        expect(klass.indexes['ProjectIndex']).to eq(partition_key: 'project_id', sort_key: 'created_at')
      end

      it 'works with has_many index auto-detection on the parent' do
        child_class = Class.new(ActiveItem::Base) do
          self.table_name = "#{TABLE_PREFIX}-children"
          belongs_to :parent

          def self.name
            'Child'
          end
        end
        child_class.dynamodb = dynamo_client
        stub_const('Child', child_class)

        parent_klass = Class.new(ActiveItem::Base) do
          def self.name
            'Parent'
          end

          self.table_name = "#{TABLE_PREFIX}-parents"
          has_many :children
        end
        parent_klass.dynamodb = dynamo_client

        # Child should have ParentIndex auto-registered
        expect(child_class.indexes).to include('ParentIndex' => { partition_key: 'parent_id' })

        # Parent.has_many should be able to resolve the index via detect_index_for_conditions
        parent = parent_klass.new
        parent.save
        relation = parent.children
        expect(relation).to be_a(ActiveItem::Relation)
      end
    end
  end

  describe 'has_many' do
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
        attr_accessor :parent_id, :label

        belongs_to :parent, class_name: 'Parent', optional: true

        def self.name
          'Child'
        end
      end.tap { |klass| klass.dynamodb = dynamo_client }
    end

    before do
      stub_const('Child', child_class)
      stub_const('Parent', parent_class)
    end

    it 'returns a Relation' do
      parent = parent_class.new(name: 'Test')
      parent.save

      result = parent.children
      expect(result).to be_a(ActiveItem::Relation)
    end

    describe '#build' do
      it 'returns an unsaved record with the foreign key set' do
        parent = parent_class.new(name: 'Test')
        parent.save

        child = parent.children.build(label: 'built-child')
        expect(child).to be_a(child_class)
        expect(child.parent_id).to eq(parent.id)
        expect(child.label).to eq('built-child')
        expect(child.id).to be_nil
      end
    end

    describe '#create' do
      it 'saves the record and returns it' do
        parent = parent_class.new(name: 'Test')
        parent.save

        child = parent.children.create(label: 'created-child')
        expect(child.id).not_to be_nil
        expect(child.parent_id).to eq(parent.id)
        expect(child.label).to eq('created-child')
      end
    end

    describe '#create!' do
      it 'saves the record and returns it' do
        parent = parent_class.new(name: 'Test')
        parent.save

        child = parent.children.create!(label: 'created-bang-child')
        expect(child.id).not_to be_nil
        expect(child.parent_id).to eq(parent.id)
        expect(child.label).to eq('created-bang-child')
      end
    end
  end
end
