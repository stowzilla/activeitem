# frozen_string_literal: true

require 'spec_helper'

# Regressions for Fizzy #2004: writes and lookups that escaped the scope the
# caller asked for.
RSpec.describe 'Scope hardening' do
  let(:dynamo_client) { @dynamo_client }

  let(:parent_class) do
    Class.new(ActiveItem::Base) do
      self.table_name = "#{TABLE_PREFIX}-parents"
      attr_accessor :name

      has_many :children, class_name: 'Child', foreign_key: 'parent_id', index: 'ParentIndex'
      accepts_nested_attributes_for :children, allow_destroy: true

      def self.name
        'Parent'
      end
    end.tap { |klass| klass.dynamodb = dynamo_client }
  end

  let(:child_class) do
    Class.new(ActiveItem::Base) do
      self.table_name = "#{TABLE_PREFIX}-children"
      attr_accessor :parent_id, :label

      indexes('ParentIndex' => { partition_key: 'parentId' })

      def self.name
        'Child'
      end
    end.tap { |klass| klass.dynamodb = dynamo_client }
  end

  let(:widget_class) do
    Class.new(ActiveItem::Base) do
      self.table_name = "#{TABLE_PREFIX}-widgets"
      attr_accessor :owner_id, :name

      def self.name
        'Widget'
      end
    end.tap { |klass| klass.dynamodb = dynamo_client }
  end

  def put(table, item)
    dynamo_client.put_item(table_name: "#{TABLE_PREFIX}-#{table}", item: item)
  end

  def get(table, id)
    dynamo_client.get_item(table_name: "#{TABLE_PREFIX}-#{table}", key: { 'id' => id }).item
  end

  before do
    stub_const('Parent', parent_class)
    stub_const('Child', child_class)

    put('parents', { 'id' => 'p1', 'name' => 'Mine' })
    put('parents', { 'id' => 'p2', 'name' => 'Theirs' })
    put('children', { 'id' => 'c1', 'parentId' => 'p1', 'label' => 'a' })
    put('children', { 'id' => 'c1b', 'parentId' => 'p1', 'label' => 'b' })
    put('children', { 'id' => 'c2', 'parentId' => 'p2', 'label' => 'a' })
  end

  describe 'accepts_nested_attributes_for' do
    let(:mine) { parent_class.find('p1') }

    it "refuses to update another parent's child" do
      mine.children_attributes = [{ id: 'c2', label: 'pwned' }]

      expect { mine.save }.to raise_error(ActiveItem::RecordNotFound)
      expect(get('children', 'c2')['label']).to eq('a')
    end

    it "refuses to destroy another parent's child" do
      mine.children_attributes = [{ id: 'c2', _destroy: true }]

      expect { mine.save }.to raise_error(ActiveItem::RecordNotFound)
      expect(get('children', 'c2')).not_to be_nil
    end

    it 'does not let nested attributes move a child to another parent' do
      mine.children_attributes = [{ id: 'c1', label: 'renamed', parent_id: 'p2' }]
      mine.save

      expect(get('children', 'c1')).to include('parentId' => 'p1', 'label' => 'renamed')
    end

    it 'creates new children under this parent even if the foreign key is supplied' do
      mine.children_attributes = [{ label: 'new', parent_id: 'p2' }]
      mine.save

      created = dynamo_client.scan(table_name: "#{TABLE_PREFIX}-children").items.find { |i| i['label'] == 'new' }
      expect(created['parentId']).to eq('p1')
    end

    it 'still updates and destroys its own children' do
      mine.children_attributes = [{ id: 'c1', label: 'z' }, { id: 'c1b', _destroy: true }]
      mine.save

      expect(get('children', 'c1')['label']).to eq('z')
      expect(get('children', 'c1b')).to be_nil
    end
  end

  describe 'mass-assigned primary key' do
    before do
      put('widgets', { 'id' => 'w1', 'ownerId' => 'me', 'name' => 'mine' })
      put('widgets', { 'id' => 'w2', 'ownerId' => 'them', 'name' => 'theirs' })
    end

    it 'refuses to change the id of a persisted record' do
      widget = widget_class.find('w1')

      expect { widget.update(id: 'w2', name: 'pwned') }.to raise_error(ActiveItem::ReadonlyAttributeError)
      expect(get('widgets', 'w2')['name']).to eq('theirs')
    end

    it 'accepts the same id being assigned back (form round-trip)' do
      widget = widget_class.find('w1')

      expect(widget.update(id: 'w1', name: 'renamed')).to be true
      expect(get('widgets', 'w1')['name']).to eq('renamed')
    end

    it 'refuses a change through a custom primary key writer' do
      custom = Class.new(ActiveItem::Base) do
        self.table_name = "#{TABLE_PREFIX}-widgets-custom-pk"
        self.primary_key = :widget_id
        attr_accessor :name
      end.tap { |klass| klass.dynamodb = dynamo_client }
      dynamo_client.put_item(table_name: "#{TABLE_PREFIX}-widgets-custom-pk", item: { 'widget_id' => 'k1', 'name' => 'x' })

      record = custom.find('k1')
      expect { record.update(widget_id: 'k2') }.to raise_error(ActiveItem::ReadonlyAttributeError)
    end

    it 'still lets new records take an id' do
      widget = widget_class.new(id: 'w3', name: 'new')
      widget.id = 'w4'

      expect(widget.save).to be true
      expect(get('widgets', 'w4')).not_to be_nil
    end
  end

  describe 'Relation#find scope' do
    it 'checks every where condition, not just the first' do
      relation = child_class.where(parent_id: 'p1', label: 'a')

      expect(relation.find('c1').id).to eq('c1')
      expect { relation.find('c1b') }.to raise_error(ActiveItem::RecordNotFound)
    end

    it 'checks not conditions' do
      relation = child_class.where(parent_id: 'p1').not(label: 'b')

      expect { relation.find('c1b') }.to raise_error(ActiveItem::RecordNotFound)
      expect(relation.find('c1').id).to eq('c1')
    end

    it 'falls back to DynamoDB for conditions it cannot evaluate in Ruby' do
      relation = child_class.where(parent_id: 'p1', label: 'a'..'b')

      expect(relation.find('c1b').id).to eq('c1b')
      expect { relation.find('c2') }.to raise_error(ActiveItem::RecordNotFound)
    end

    it 'scopes a preloaded association to its owner' do
      parent = parent_class.includes(:children).where(name: 'Mine').to_a.first
      expect(parent._preloaded_associations).to have_key(:children)

      expect(parent.children.find('c1').id).to eq('c1')
      expect { parent.children.find('c2') }.to raise_error(ActiveItem::RecordNotFound)
      expect(parent.children.where(label: 'a').to_a.map(&:id)).to eq(%w[c1])
    end

    it 'falls back correctly on a custom primary key model' do
      custom = Class.new(ActiveItem::Base) do
        self.table_name = "#{TABLE_PREFIX}-widgets-custom-pk"
        self.primary_key = :widget_id
        attr_accessor :name
      end.tap { |klass| klass.dynamodb = dynamo_client }
      dynamo_client.put_item(table_name: "#{TABLE_PREFIX}-widgets-custom-pk", item: { 'widget_id' => 'k1', 'name' => 'b' })
      dynamo_client.put_item(table_name: "#{TABLE_PREFIX}-widgets-custom-pk", item: { 'widget_id' => 'k2', 'name' => 'z' })

      expect(custom.where(name: 'a'..'c').find('k1').id).to eq('k1')
      expect { custom.where(name: 'a'..'c').find('k2') }.to raise_error(ActiveItem::RecordNotFound)
    end

    it 'scopes a batch-loaded relation to the requested ids' do
      expect { child_class.where(id: %w[c1]).find('c2') }.to raise_error(ActiveItem::RecordNotFound)
    end

    it 'finds nothing on an empty relation' do
      expect { child_class.none.find('c1') }.to raise_error(ActiveItem::RecordNotFound)
    end
  end

  describe 'ilike' do
    before do
      put('widgets', { 'id' => 'w1', 'ownerId' => 'me', 'name' => 'Hello World' })
      put('widgets', { 'id' => 'w2', 'ownerId' => 'me-not', 'name' => 'hello there' })
    end

    it 'does not loosen conditions from other where calls' do
      ids = widget_class.where(owner_id: 'me').where(name: 'hello', ilike: true).map(&:id)

      expect(ids).to eq(%w[w1])
    end

    it 'applies only to the named attribute' do
      ids = widget_class.where(owner_id: 'me', name: 'HELLO', ilike: :name).map(&:id)

      expect(ids).to eq(%w[w1])
    end

    it 'refuses an ambiguous ilike: true' do
      expect { widget_class.where(owner_id: 'me', name: 'hello', ilike: true) }.to raise_error(ArgumentError, /ambiguous/)
    end

    it 'still works with a single string condition' do
      expect(widget_class.where(name: 'HELLO', ilike: true).map(&:id)).to contain_exactly('w1', 'w2')
    end
  end

  describe 'create inside a transaction' do
    before { put('widgets', { 'id' => 'w1', 'ownerId' => 'them', 'name' => 'original' }) }

    it 'does not overwrite an existing row' do
      expect do
        widget_class.transaction { widget_class.new(id: 'w1', name: 'replaced').save }
      end.to raise_error(ActiveItem::TransactionError)

      expect(get('widgets', 'w1')['name']).to eq('original')
    end
  end

  describe 'filtered scans' do
    before do
      30.times { |i| put('widgets', { 'id' => format('w%02d', i), 'ownerId' => 'nobody' }) }
      put('widgets', { 'id' => 'zz', 'ownerId' => 'needle' })
      allow(dynamo_client).to receive(:scan).and_call_original
    end

    it 'does not spend one Scan per item on find_by' do
      expect(widget_class.find_by(owner_id: 'needle').id).to eq('zz')
      expect(dynamo_client).to have_received(:scan).at_most(2).times
    end

    it 'does not spend one Scan per item on exists?' do
      expect(widget_class.where(owner_id: 'needle').exists?).to be true
      expect(dynamo_client).to have_received(:scan).at_most(2).times
    end

    it 'pages a filtered scan without dropping or repeating matches' do
      12.times { |i| put('widgets', { 'id' => format('m%02d', i), 'ownerId' => 'match' }) }

      expect(collect_pages(widget_class.where(owner_id: 'match'))).to match_array(Array.new(12) { |i| format('m%02d', i) })
    end

    it 'pages a filtered GSI query without dropping or repeating matches' do
      items = Class.new(ActiveItem::Base) do
        self.table_name = "#{TABLE_PREFIX}-items"
        attr_accessor :status, :color

        indexes('StatusIndex' => { partition_key: 'status', sort_key: 'createdAt' })
      end.tap { |klass| klass.dynamodb = dynamo_client }
      20.times do |i|
        dynamo_client.put_item(table_name: "#{TABLE_PREFIX}-items",
                               item: { 'id' => format('i%02d', i), 'status' => 'active', 'createdAt' => format('2026-01-%02d', i + 1),
                                       'color' => i.even? ? 'red' : 'blue' })
      end

      expected = Array.new(10) { |i| format('i%02d', i * 2) }
      expect(collect_pages(items.where(status: 'active', color: 'red'))).to match_array(expected)
    end

    def collect_pages(relation)
      ids = []
      cursor = nil
      loop do
        page = relation.page(cursor, per_page: 3)
        ids.concat(page.items.map(&:id))
        cursor = page.next_cursor
        break unless page.has_more?
      end
      expect(ids.uniq.length).to eq(ids.length)
      ids
    end

    it 'still honors the limit' do
      expect(widget_class.where(owner_id: 'nobody').limit(3).to_a.length).to eq(3)
    end
  end
end
