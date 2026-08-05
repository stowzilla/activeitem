# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Embedded Associations' do
  let(:dynamo_client) { @dynamo_client }

  let(:gadget_class) do
    Class.new(ActiveItem::Base) do
      self.embedded = true

      attr_accessor :name, :weight, :color

      validates :name, presence: true

      before_save :normalize_name

      def self.name
        'Gadget'
      end

      private

      def normalize_name
        self.name = name.strip.downcase if name
      end
    end
  end

  let(:container_class) do
    klass = Class.new(ActiveItem::Base) do
      self.table_name = "#{TABLE_PREFIX}-things"

      attr_accessor :label

      def self.name
        'Container'
      end
    end
    klass.dynamodb = dynamo_client
    stub_const('Gadget', gadget_class)
    klass.has_many :gadgets, embedded: true, class_name: 'Gadget'
    klass
  end

  describe 'model configuration' do
    it 'marks the child class as embedded' do
      expect(gadget_class).to be_embedded
    end

    it 'does not mark the parent class as embedded' do
      expect(container_class).not_to be_embedded
    end

    it 'registers the embedded association on the parent' do
      expect(container_class._embedded_associations).to have_key(:gadgets)
      expect(container_class._embedded_associations[:gadgets][:class_name]).to eq('Gadget')
    end
  end

  describe 'EmbeddedCollection' do
    let(:container) { container_class.new(label: 'Tool Box') }

    describe '#build' do
      it 'adds a new record to the collection' do
        gadget = container.gadgets.build(name: 'wrench', weight: 2)

        expect(container.gadgets.count).to eq(1)
        expect(gadget.name).to eq('wrench')
        expect(gadget.weight).to eq(2)
      end

      it 'auto-assigns a UUID id' do
        gadget = container.gadgets.build(name: 'bolt')

        expect(gadget.id).not_to be_nil
        expect(gadget.id).to match(/\A[0-9a-f-]{36}\z/)
      end

      it 'sets the embedded parent reference' do
        gadget = container.gadgets.build(name: 'nut')

        parent = gadget.instance_variable_get(:@_embedded_parent)
        expect(parent).to eq(container)
      end

      it 'marks the parent as dirty' do
        container.save
        container.send(:clear_changes_information)
        container.instance_variable_set(:@_embedded_gadgets_snapshot, container.send(:serialize_embedded_snapshot, container.gadgets))

        container.gadgets.build(name: 'screw')

        expect(container.has_changes_to_save?).to be true
      end
    end

    describe '#create!' do
      it 'builds and validates the record' do
        gadget = container.gadgets.create!(name: 'hammer')

        expect(gadget.name).to eq('hammer')
        expect(container.gadgets.count).to eq(1)
      end

      it 'raises RecordInvalid when validation fails' do
        expect {
          container.gadgets.create!(name: nil)
        }.to raise_error(ActiveItem::RecordInvalid)
      end
    end

    describe '#find' do
      it 'finds a record by id' do
        gadget = container.gadgets.build(name: 'pliers')
        found = container.gadgets.find(gadget.id)

        expect(found).to eq(gadget)
      end

      it 'raises RecordNotFound for unknown id' do
        expect {
          container.gadgets.find('nonexistent')
        }.to raise_error(ActiveItem::RecordNotFound)
      end
    end

    describe '#where' do
      before do
        container.gadgets.build(name: 'red bolt', color: 'red')
        container.gadgets.build(name: 'blue bolt', color: 'blue')
        container.gadgets.build(name: 'red nut', color: 'red')
      end

      it 'filters records by attribute' do
        results = container.gadgets.where(color: 'red')

        expect(results.count).to eq(2)
        expect(results.map(&:name)).to contain_exactly('red bolt', 'red nut')
      end

      it 'filters by multiple attributes' do
        container.gadgets.build(name: 'heavy red bolt', color: 'red', weight: 5)

        results = container.gadgets.where(color: 'red', weight: 5)
        expect(results.count).to eq(1)
        expect(results.first.name).to eq('heavy red bolt')
      end

      it 'returns an EmbeddedCollection' do
        results = container.gadgets.where(color: 'blue')
        expect(results).to be_a(ActiveItem::EmbeddedCollection)
      end

      it 'returns empty collection when no matches' do
        results = container.gadgets.where(color: 'green')
        expect(results.count).to eq(0)
        expect(results).to be_empty
      end
    end

    describe '#delete' do
      it 'removes a record from the collection by reference' do
        gadget = container.gadgets.build(name: 'doomed')
        container.gadgets.build(name: 'survivor')

        container.gadgets.delete(gadget)

        expect(container.gadgets.count).to eq(1)
        expect(container.gadgets.first.name).to eq('survivor')
      end

      it 'removes a record from the collection by id' do
        gadget = container.gadgets.build(name: 'target')
        container.gadgets.build(name: 'bystander')

        container.gadgets.delete(gadget.id)

        expect(container.gadgets.count).to eq(1)
        expect(container.gadgets.first.name).to eq('bystander')
      end
    end

    describe '#<<' do
      it 'appends a record to the collection' do
        gadget = gadget_class.new(name: 'appended')
        gadget.instance_variable_set(:@id, SecureRandom.uuid)

        container.gadgets << gadget

        expect(container.gadgets.count).to eq(1)
        expect(container.gadgets.first.name).to eq('appended')
      end

      it 'sets the parent reference on the appended record' do
        gadget = gadget_class.new(name: 'appended')
        gadget.instance_variable_set(:@id, SecureRandom.uuid)

        container.gadgets << gadget

        expect(gadget.instance_variable_get(:@_embedded_parent)).to eq(container)
      end
    end

    describe 'Enumerable' do
      before do
        container.gadgets.build(name: 'a')
        container.gadgets.build(name: 'b')
        container.gadgets.build(name: 'c')
      end

      it 'supports #first' do
        expect(container.gadgets.first.name).to eq('a')
      end

      it 'supports #last' do
        expect(container.gadgets.last.name).to eq('c')
      end

      it 'supports #each' do
        names = []
        container.gadgets.each { |g| names << g.name }
        expect(names).to eq(%w[a b c])
      end

      it 'supports #map' do
        names = container.gadgets.map(&:name)
        expect(names).to eq(%w[a b c])
      end

      it 'supports #select' do
        results = container.gadgets.select { |g| g.name == 'b' }
        expect(results.length).to eq(1)
      end

      it 'supports #any?' do
        expect(container.gadgets.any?).to be true
        expect(container.gadgets.any? { |g| g.name == 'z' }).to be false
      end

      it 'supports #empty?' do
        expect(container.gadgets.empty?).to be false
        expect(container_class.new.gadgets.empty?).to be true
      end

      it 'supports #to_a' do
        arr = container.gadgets.to_a
        expect(arr).to be_a(Array)
        expect(arr.length).to eq(3)
      end
    end

    describe '#replace' do
      it 'replaces the entire collection' do
        container.gadgets.build(name: 'old')

        new_gadgets = [gadget_class.new(name: 'new1'), gadget_class.new(name: 'new2')]
        new_gadgets.each { |g| g.instance_variable_set(:@id, SecureRandom.uuid) }

        container.gadgets.replace(new_gadgets)

        expect(container.gadgets.count).to eq(2)
        expect(container.gadgets.map(&:name)).to eq(%w[new1 new2])
      end
    end
  end

  describe 'persistence' do
    let(:container) { container_class.new(label: 'Storage Box') }

    it 'saves embedded records as an array in DynamoDB' do
      container.gadgets.build(name: 'wrench', weight: 2, color: 'silver')
      container.gadgets.build(name: 'bolt', weight: 1, color: 'grey')
      container.save

      resp = dynamo_client.get_item(
        table_name: "#{TABLE_PREFIX}-things",
        key: { 'id' => container.id }
      )
      item = resp.item

      expect(item['gadgets']).to be_a(Array)
      expect(item['gadgets'].length).to eq(2)
      expect(item['gadgets'][0]['name']).to eq('wrench')
      expect(item['gadgets'][0]['weight']).to eq(2)
      expect(item['gadgets'][1]['name']).to eq('bolt')
    end

    it 'hydrates embedded records when loading from DynamoDB' do
      container.gadgets.build(name: 'pliers', color: 'red')
      container.save

      loaded = container_class.find(container.id)

      expect(loaded.gadgets.count).to eq(1)
      expect(loaded.gadgets.first).to be_a(gadget_class)
      expect(loaded.gadgets.first.name).to eq('pliers')
      expect(loaded.gadgets.first.color).to eq('red')
    end

    it 'preserves embedded record IDs across save/load' do
      gadget = container.gadgets.build(name: 'hammer')
      container.save

      loaded = container_class.find(container.id)
      expect(loaded.gadgets.first.id).to eq(gadget.id)
    end

    it 'marks loaded embedded records as persisted (not new_record)' do
      container.gadgets.build(name: 'saw')
      container.save

      loaded = container_class.find(container.id)
      expect(loaded.gadgets.first.new_record?).to be false
    end

    it 'saves an empty embedded collection (no gadgets key in DynamoDB)' do
      container.save

      resp = dynamo_client.get_item(
        table_name: "#{TABLE_PREFIX}-things",
        key: { 'id' => container.id }
      )
      item = resp.item

      expect(item).not_to have_key('gadgets')
    end

    it 'persists updates to existing embedded records' do
      container.gadgets.build(name: 'widget', color: 'blue')
      container.save

      loaded = container_class.find(container.id)
      loaded.gadgets.first.color = 'green'
      loaded.save

      reloaded = container_class.find(container.id)
      expect(reloaded.gadgets.first.color).to eq('green')
    end

    it 'persists addition of new embedded records to existing parent' do
      container.gadgets.build(name: 'first')
      container.save

      loaded = container_class.find(container.id)
      loaded.gadgets.build(name: 'second')
      loaded.save

      reloaded = container_class.find(container.id)
      expect(reloaded.gadgets.count).to eq(2)
      expect(reloaded.gadgets.map(&:name)).to contain_exactly('first', 'second')
    end

    it 'persists removal of embedded records' do
      container.gadgets.build(name: 'keep')
      doomed = container.gadgets.build(name: 'remove')
      container.save

      loaded = container_class.find(container.id)
      loaded.gadgets.delete(doomed.id)
      loaded.save

      reloaded = container_class.find(container.id)
      expect(reloaded.gadgets.count).to eq(1)
      expect(reloaded.gadgets.first.name).to eq('keep')
    end
  end

  describe 'delegated save/update/destroy' do
    let(:container) { container_class.new(label: 'Delegation Box') }

    before do
      container.gadgets.build(name: 'target', color: 'red')
      container.gadgets.build(name: 'bystander', color: 'blue')
      container.save
    end

    it 'allows embedded record to save via parent' do
      loaded = container_class.find(container.id)
      gadget = loaded.gadgets.first
      gadget.color = 'purple'
      gadget.save

      reloaded = container_class.find(container.id)
      expect(reloaded.gadgets.find(gadget.id).color).to eq('purple')
    end

    it 'allows embedded record to update attributes via parent' do
      loaded = container_class.find(container.id)
      gadget = loaded.gadgets.first
      gadget.update(color: 'orange')

      reloaded = container_class.find(container.id)
      expect(reloaded.gadgets.find(gadget.id).color).to eq('orange')
    end

    it 'allows embedded record to destroy via parent' do
      loaded = container_class.find(container.id)
      gadget = loaded.gadgets.first
      gadget_id = gadget.id
      gadget.destroy

      reloaded = container_class.find(container.id)
      expect(reloaded.gadgets.count).to eq(1)
      expect { reloaded.gadgets.find(gadget_id) }.to raise_error(ActiveItem::RecordNotFound)
    end

    it 'raises EmbeddedModelError when saving orphaned embedded record' do
      orphan = gadget_class.new(name: 'orphan')

      expect { orphan.save }.to raise_error(ActiveItem::EmbeddedModelError, /no parent record/)
    end

    it 'raises EmbeddedModelError when destroying orphaned embedded record' do
      orphan = gadget_class.new(name: 'orphan')

      expect { orphan.destroy }.to raise_error(ActiveItem::EmbeddedModelError, /no parent record/)
    end
  end

  describe 'embedded model guards' do
    it 'raises EmbeddedModelError on .find' do
      expect { gadget_class.find('x') }.to raise_error(ActiveItem::EmbeddedModelError)
    end

    it 'raises EmbeddedModelError on .where' do
      expect { gadget_class.where(name: 'x') }.to raise_error(ActiveItem::EmbeddedModelError)
    end

    it 'raises EmbeddedModelError on .all' do
      expect { gadget_class.all }.to raise_error(ActiveItem::EmbeddedModelError)
    end

    it 'raises EmbeddedModelError on .count' do
      expect { gadget_class.count }.to raise_error(ActiveItem::EmbeddedModelError)
    end

    it 'raises EmbeddedModelError on .exists?' do
      expect { gadget_class.exists?('x') }.to raise_error(ActiveItem::EmbeddedModelError)
    end

    it 'raises EmbeddedModelError on .create' do
      expect { gadget_class.create(name: 'x') }.to raise_error(ActiveItem::EmbeddedModelError)
    end

    it 'raises EmbeddedModelError on .create!' do
      expect { gadget_class.create!(name: 'x') }.to raise_error(ActiveItem::EmbeddedModelError)
    end
  end

  describe 'validation cascading' do
    let(:container) { container_class.new(label: 'Validation Box') }

    it 'parent is invalid when embedded record is invalid' do
      container.gadgets.build(name: nil) # name is required

      expect(container.save).to be false
    end

    it 'adds namespaced errors for invalid embedded records' do
      container.gadgets.build(name: nil)
      container.save

      expect(container.errors.messages.keys.any? { |k| k.to_s.start_with?('gadgets[') }).to be true
    end

    it 'parent is valid when all embedded records are valid' do
      container.gadgets.build(name: 'valid gadget')

      expect(container.save).to be true
    end

    it 'validates embedded records on delegated save' do
      container.gadgets.build(name: 'initial')
      container.save

      loaded = container_class.find(container.id)
      gadget = loaded.gadgets.first
      gadget.name = nil

      expect(gadget.save).to be false
    end
  end

  describe 'callbacks' do
    let(:container) { container_class.new(label: 'Callback Box') }

    it 'runs before_save on embedded records during parent create' do
      container.gadgets.build(name: '  WRENCH  ')
      container.save

      loaded = container_class.find(container.id)
      expect(loaded.gadgets.first.name).to eq('wrench')
    end

    it 'runs before_save on embedded records during parent update' do
      container.gadgets.build(name: 'bolt')
      container.save

      loaded = container_class.find(container.id)
      loaded.gadgets.build(name: '  NUT  ')
      loaded.save

      reloaded = container_class.find(container.id)
      names = reloaded.gadgets.map(&:name)
      expect(names).to include('nut')
    end
  end

  describe 'dirty tracking' do
    let(:container) { container_class.new(label: 'Dirty Box') }

    before do
      container.gadgets.build(name: 'original')
      container.save
    end

    it 'detects changes to embedded record attributes' do
      loaded = container_class.find(container.id)
      expect(loaded.has_changes_to_save?).to be false

      loaded.gadgets.first.name = 'modified'
      expect(loaded.has_changes_to_save?).to be true
    end

    it 'detects addition of embedded records' do
      loaded = container_class.find(container.id)
      loaded.gadgets.build(name: 'added')

      expect(loaded.has_changes_to_save?).to be true
    end

    it 'detects removal of embedded records' do
      loaded = container_class.find(container.id)
      loaded.gadgets.delete(loaded.gadgets.first)

      expect(loaded.has_changes_to_save?).to be true
    end

    it 'is clean after save' do
      loaded = container_class.find(container.id)
      loaded.gadgets.first.name = 'changed'
      loaded.save

      reloaded = container_class.find(container.id)
      expect(reloaded.has_changes_to_save?).to be false
    end
  end

  describe 'ItemTooLargeError' do
    let(:container) { container_class.new(label: 'Overflow Box') }

    it 'raises ItemTooLargeError with helpful message when item exceeds 400KB' do
      # Stub DynamoDB to raise the size limit error
      allow(dynamo_client).to receive(:put_item).and_raise(
        Aws::DynamoDB::Errors::ValidationException.new(
          nil, 'Item size has exceeded the maximum allowed size of 400KB'
        )
      )

      container.gadgets.build(name: 'too-much-data')

      expect { container.save! }.to raise_error(ActiveItem::ItemTooLargeError) do |error|
        expect(error.message).to include('400KB')
        expect(error.message).to include('embedded')
        expect(error.model_name).to eq('Container')
      end
    end
  end

  describe 'serialization format' do
    let(:container) { container_class.new(label: 'Format Box') }

    it 'serializes attribute names to camelCase in DynamoDB' do
      # Gadget has attrs: name, weight, color — should appear as-is (single-word)
      # but multi-word attrs would be camelCased
      container.gadgets.build(name: 'test', weight: 5, color: 'red')
      container.save

      resp = dynamo_client.get_item(
        table_name: "#{TABLE_PREFIX}-things",
        key: { 'id' => container.id }
      )
      gadget_hash = resp.item['gadgets'][0]

      expect(gadget_hash).to have_key('id')
      expect(gadget_hash).to have_key('name')
      expect(gadget_hash).to have_key('weight')
      expect(gadget_hash).to have_key('color')
    end

    it 'does not serialize nil attributes' do
      container.gadgets.build(name: 'sparse', weight: nil, color: nil)
      container.save

      resp = dynamo_client.get_item(
        table_name: "#{TABLE_PREFIX}-things",
        key: { 'id' => container.id }
      )
      gadget_hash = resp.item['gadgets'][0]

      expect(gadget_hash).to have_key('name')
      expect(gadget_hash).not_to have_key('weight')
      expect(gadget_hash).not_to have_key('color')
    end

    it 'includes id in each serialized embedded record' do
      container.gadgets.build(name: 'identified')
      container.save

      resp = dynamo_client.get_item(
        table_name: "#{TABLE_PREFIX}-things",
        key: { 'id' => container.id }
      )
      gadget_hash = resp.item['gadgets'][0]

      expect(gadget_hash['id']).to match(/\A[0-9a-f-]{36}\z/)
    end
  end

  describe 'multiple embedded associations' do
    let(:tag_class) do
      Class.new(ActiveItem::Base) do
        self.embedded = true
        attr_accessor :label, :priority

        def self.name
          'Tag'
        end
      end
    end

    let(:multi_container_class) do
      klass = Class.new(ActiveItem::Base) do
        self.table_name = "#{TABLE_PREFIX}-things"
        attr_accessor :title

        def self.name
          'MultiContainer'
        end
      end
      klass.dynamodb = dynamo_client
      stub_const('Gadget', gadget_class)
      stub_const('Tag', tag_class)
      klass.has_many :gadgets, embedded: true, class_name: 'Gadget'
      klass.has_many :tags, embedded: true, class_name: 'Tag'
      klass
    end

    it 'supports multiple embedded collections on one parent' do
      record = multi_container_class.new(title: 'Multi')
      record.gadgets.build(name: 'gadget1')
      record.tags.build(label: 'urgent', priority: 1)
      record.save

      loaded = multi_container_class.find(record.id)
      expect(loaded.gadgets.count).to eq(1)
      expect(loaded.tags.count).to eq(1)
      expect(loaded.gadgets.first.name).to eq('gadget1')
      expect(loaded.tags.first.label).to eq('urgent')
    end
  end

  describe 'edge cases' do
    let(:container) { container_class.new(label: 'Edge Case Box') }

    it 'handles saving parent with no embedded records' do
      container.save
      loaded = container_class.find(container.id)

      expect(loaded.gadgets.count).to eq(0)
      expect(loaded.gadgets).to be_empty
    end

    it 'handles loading a record that was saved without embedded data' do
      dynamo_client.put_item(
        table_name: "#{TABLE_PREFIX}-things",
        item: { 'id' => 'raw-1', 'label' => 'Raw' }
      )

      loaded = container_class.find('raw-1')
      expect(loaded.gadgets.count).to eq(0)
    end

    it 'handles building into an empty collection after load' do
      container.save
      loaded = container_class.find(container.id)

      loaded.gadgets.build(name: 'late addition')
      loaded.save

      reloaded = container_class.find(container.id)
      expect(reloaded.gadgets.count).to eq(1)
      expect(reloaded.gadgets.first.name).to eq('late addition')
    end

    it 'does not persist unchanged embedded collections on update' do
      container.gadgets.build(name: 'stable')
      container.save

      loaded = container_class.find(container.id)
      loaded.label = 'Updated Label'

      # The embedded collection hasn't changed, but the parent attribute has
      expect(loaded.gadgets.first.name).to eq('stable')
      loaded.save

      reloaded = container_class.find(container.id)
      expect(reloaded.label).to eq('Updated Label')
      expect(reloaded.gadgets.first.name).to eq('stable')
    end

    it 'count method returns correct value' do
      container.gadgets.build(name: 'one')
      container.gadgets.build(name: 'two')
      container.gadgets.build(name: 'three')

      expect(container.gadgets_count).to eq(3)
    end
  end
end
