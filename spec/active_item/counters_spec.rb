# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ActiveItem::Counters do
  let(:dynamo_client) { @dynamo_client }

  let(:link_class) do
    Class.new(ActiveItem::Base) do
      self.table_name = "#{TABLE_PREFIX}-widgets"
      attr_accessor :name, :opens, :visitors, :first_opened_at, :last_opened_at

      def self.name
        'ShareLink'
      end
    end.tap { |klass| klass.dynamodb = dynamo_client }
  end

  let(:custom_pk_class) do
    Class.new(ActiveItem::Base) do
      self.table_name = "#{TABLE_PREFIX}-widgets-custom-pk"
      self.primary_key = 'widget_id'
      attr_accessor :sold

      def self.name
        'CustomPkWidget'
      end
    end.tap { |klass| klass.dynamodb = dynamo_client }
  end

  def stored(id, table: 'widgets', key: 'id')
    dynamo_client.get_item(table_name: "#{TABLE_PREFIX}-#{table}", key: { key => id }).item
  end

  describe '.update_counters' do
    it 'adds to existing counters and leaves other attributes alone' do
      link_class.create(id: 'l1', name: 'Pricing', opens: 3)

      record = link_class.update_counters('l1', opens: 2, visitors: 1)

      expect(record.opens).to eq(5)
      expect(record.visitors).to eq(1)
      expect(record.name).to eq('Pricing')
      expect(record).to be_persisted
      expect(record.changed?).to be(false)
    end

    it 'creates a missing row with createdAt, updatedAt and _recent_pk' do
      record = link_class.update_counters('new', opens: 1)

      item = stored('new')
      expect(item['opens']).to eq(1)
      expect(item['createdAt']).to be_a(String)
      expect(item['updatedAt']).to be_a(String)
      expect(item['_recent_pk']).to eq('ALL')
      expect(record.id).to eq('new')
    end

    it 'keeps createdAt when the row already exists' do
      link_class.create(id: 'l1', opens: 0)
      created = stored('l1')['createdAt']
      dynamo_client.update_item(table_name: "#{TABLE_PREFIX}-widgets", key: { 'id' => 'l1' },
                                update_expression: 'SET createdAt = :c', expression_attribute_values: { ':c' => '2020-01-01T00:00:00Z' })

      link_class.update_counters('l1', opens: 1)

      expect(created).to be_a(String)
      expect(stored('l1')['createdAt']).to eq('2020-01-01T00:00:00Z')
    end

    it 'leaves the timestamps out with touch: false' do
      link_class.update_counters('day', { 'n:visits' => 1 }, set_if_missing: { name: 'd' }, touch: false)

      expect(stored('day').keys).to contain_exactly('id', 'n:visits', 'name')
    end

    it 'accepts the counters as a positional hash' do
      link_class.update_counters('l1', { opens: 1 })
      expect(stored('l1')['opens']).to eq(1)
    end

    it 'decrements with a negative amount' do
      link_class.create(id: 'l1', opens: 5)
      expect(link_class.update_counters('l1', opens: -2).opens).to eq(3)
    end

    it 'maps names through to_dynamo_key and dynamo_attribute_map' do
      link_class.dynamo_attribute_map(visitors: 'uniq')

      link_class.update_counters('l1', visitors: 1, set: { last_opened_at: 't1' }, set_if_missing: { first_opened_at: 't0' })

      item = stored('l1')
      expect(item['uniq']).to eq(1)
      expect(item['lastOpenedAt']).to eq('t1')
      expect(item['firstOpenedAt']).to eq('t0')
    end

    it 'writes undeclared names verbatim' do
      link_class.update_counters('day', { 'n:page:/pricing_plans' => 1, 'n:visits' => 2 })

      item = stored('day')
      expect(item['n:page:/pricing_plans']).to eq(1)
      expect(item['n:visits']).to eq(2)
    end

    it 'only fills set_if_missing attributes that are absent, and REMOVEs nil sets' do
      link_class.create(id: 'l1', first_opened_at: 'first', last_opened_at: 'old', name: 'gone')

      record = link_class.update_counters('l1', { opens: 1 }, set: { last_opened_at: 'new', name: nil }, set_if_missing: { first_opened_at: 'later' })

      expect(record.first_opened_at).to eq('first')
      expect(record.last_opened_at).to eq('new')
      expect(stored('l1')).not_to have_key('name')
    end

    it 'works with a custom primary key' do
      custom_pk_class.update_counters('w1', sold: 1)
      record = custom_pk_class.update_counters('w1', sold: 1)

      expect(record.widget_id).to eq('w1')
      expect(stored('w1', table: 'widgets-custom-pk', key: 'widget_id')['sold']).to eq(2)
    end

    context 'with if_exists: true' do
      it 'returns nil and creates nothing when the row is missing' do
        expect(link_class.update_counters('missing', { opens: 1 }, if_exists: true)).to be_nil
        expect(stored('missing')).to be_nil
      end

      it 'updates a row that exists' do
        link_class.create(id: 'l1', opens: 1)
        expect(link_class.update_counters('l1', { opens: 1 }, if_exists: true).opens).to eq(2)
      end
    end

    it 'counts every one of many concurrent increments' do
      link_class.create(id: 'l1', opens: 0)

      Array.new(8) { Thread.new { 5.times { link_class.update_counters('l1', opens: 1) } } }.each(&:join)

      expect(stored('l1')['opens']).to eq(40)
    end

    it 'rejects bad input before calling DynamoDB' do
      expect(dynamo_client).not_to receive(:update_item)

      expect { link_class.update_counters('l1', {}) }.to raise_error(ArgumentError, /at least one counter/)
      expect { link_class.update_counters(nil, opens: 1) }.to raise_error(ArgumentError, /needs an id/)
      expect { link_class.update_counters('l1', opens: '1') }.to raise_error(ArgumentError, /numeric/)
      expect { link_class.update_counters('l1', { opens: 1 }, set: { opens: 2 }) }.to raise_error(ArgumentError, /opens appears more than once/)
      expect { link_class.update_counters('l1', { opens: 1 }, set: { updated_at: 'x' }) }.to raise_error(ArgumentError, /updatedAt/)
      expect { link_class.update_counters('l1', id: 1) }.to raise_error(ArgumentError, /id appears more than once/)
    end

    it 'wraps AccessDenied' do
      error = Aws::DynamoDB::Errors::AccessDeniedException.new(nil, 'denied')
      allow(dynamo_client).to receive(:update_item).and_raise(error)

      expect { link_class.update_counters('l1', opens: 1) }.to raise_error(ActiveItem::AccessDeniedError) { |e| expect(e.operation).to eq('UpdateItem') }
    end
  end

  describe '#increment!' do
    let!(:link) { link_class.create(id: 'l1', name: 'Pricing', opens: 1) }

    it 'adds to the stored value, not the value the record read' do
      link_class.update_counters('l1', opens: 10)

      expect(link.increment!(:opens)).to be(link)
      expect(link.opens).to eq(12)
      expect(stored('l1')['opens']).to eq(12)
    end

    it 'increments several attributes, sets others, and leaves them clean' do
      link.increment!(:opens, :visitors, by: 2, set: { last_opened_at: 't1' }, set_if_missing: { first_opened_at: 't0' })

      expect([link.opens, link.visitors, link.last_opened_at, link.first_opened_at]).to eq([3, 2, 't1', 't0'])
      expect(link.changed?).to be(false)
      expect(link.updated_at).to eq(stored('l1')['updatedAt'])
    end

    it 'keeps unrelated unsaved changes' do
      link.name = 'Renamed'
      link.increment!(:opens)

      expect(link.name).to eq('Renamed')
      expect(link.changed).to eq(['name'])
      expect(stored('l1')['name']).to eq('Pricing')
    end

    it 'returns false and does not bring back a deleted row' do
      link_class.delete('id' => 'l1')

      expect(link.increment!(:opens)).to be(false)
      expect(stored('l1')).to be_nil
    end

    it 'decrement! subtracts' do
      link.decrement!(:opens, by: 3)
      expect(link.opens).to eq(-2)
    end

    it 'refuses new records and undeclared attributes' do
      expect { link_class.new.increment!(:opens) }.to raise_error(ArgumentError, /new ShareLink/)
      expect { link.increment!(:clicks) }.to raise_error(ArgumentError, /no attribute clicks/)
    end
  end
end
