# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ActiveItem::Transaction do
  let(:dynamo_client) { @dynamo_client }

  let(:model_class) do
    Class.new(ActiveItem::Base) do
      self.table_name = "#{TABLE_PREFIX}-things"
      attr_accessor :name

      def self.name
        'Thing'
      end
    end.tap { |klass| klass.dynamodb = dynamo_client }
  end

  let(:other_model_class) do
    Class.new(ActiveItem::Base) do
      self.table_name = "#{TABLE_PREFIX}-other-things"
      attr_accessor :title

      def self.name
        'OtherThing'
      end
    end.tap { |klass| klass.dynamodb = dynamo_client }
  end

  before do
    # Ensure other_things table exists

    dynamo_client.describe_table(table_name: "#{TABLE_PREFIX}-other-things")
  rescue Aws::DynamoDB::Errors::ResourceNotFoundException
    dynamo_client.create_table(
      table_name: "#{TABLE_PREFIX}-other-things",
      key_schema: [{ attribute_name: 'id', key_type: 'HASH' }],
      attribute_definitions: [{ attribute_name: 'id', attribute_type: 'S' }],
      billing_mode: 'PAY_PER_REQUEST'
    )
  end

  describe '.active?' do
    it 'returns false outside a transaction' do
      expect(ActiveItem::Transaction.active?).to be false
    end

    it 'returns true inside a transaction' do
      model_class.transaction do
        expect(ActiveItem::Transaction.active?).to be true
      end
    end

    it 'returns false after transaction completes' do
      model_class.transaction do
        # inside
      end
      expect(ActiveItem::Transaction.active?).to be false
    end

    it 'returns false after transaction raises' do
      begin
        model_class.transaction do
          raise 'boom'
        end
      rescue StandardError
        # expected
      end
      expect(ActiveItem::Transaction.active?).to be false
    end
  end

  describe '#put (explicit API)' do
    it 'adds a put operation' do
      txn = ActiveItem::Transaction.new
      record = model_class.new(name: 'Widget')
      txn.put(record)
      expect(txn.operations.length).to eq(1)
      expect(txn.operations.first[:type]).to eq(:put)
    end

    it 'assigns id and timestamps' do
      txn = ActiveItem::Transaction.new
      record = model_class.new(name: 'Widget')
      txn.put(record)
      expect(record.id).not_to be_nil
      expect(record.created_at).not_to be_nil
    end
  end

  describe '#execute!' do
    it 'persists records to DynamoDB' do
      txn = ActiveItem::Transaction.new
      record = model_class.new(name: 'Widget')
      txn.put(record)
      txn.execute!

      resp = dynamo_client.get_item(table_name: "#{TABLE_PREFIX}-things", key: { 'id' => record.id })
      expect(resp.item['name']).to eq('Widget')
    end

    it 'marks put records as persisted' do
      txn = ActiveItem::Transaction.new
      record = model_class.new(name: 'Widget')
      txn.put(record)
      txn.execute!
      expect(record.persisted?).to be true
    end

    it 'raises TransactionError when exceeding 100 items' do
      txn = ActiveItem::Transaction.new
      101.times { txn.put(model_class.new(name: 'x')) }
      expect { txn.execute! }.to raise_error(ActiveItem::TransactionError, /limited to 100/)
    end

    it 'does nothing when empty' do
      txn = ActiveItem::Transaction.new
      expect { txn.execute! }.not_to raise_error
    end
  end

  describe 'transactional saves (implicit API)' do
    describe 'save inside transaction' do
      it 'enrolls new record save as put' do
        record = model_class.new(name: 'Gadget')

        model_class.transaction do
          record.save!
        end

        expect(record.persisted?).to be true
        resp = dynamo_client.get_item(table_name: "#{TABLE_PREFIX}-things", key: { 'id' => record.id })
        expect(resp.item['name']).to eq('Gadget')
      end

      it 'enrolls existing record save as update' do
        record = model_class.create!(name: 'Original')

        model_class.transaction do
          record.name = 'Updated'
          record.save!
        end

        resp = dynamo_client.get_item(table_name: "#{TABLE_PREFIX}-things", key: { 'id' => record.id })
        expect(resp.item['name']).to eq('Updated')
      end

      it 'commits multiple saves atomically' do
        record1 = model_class.new(name: 'First')
        record2 = model_class.new(name: 'Second')

        model_class.transaction do
          record1.save!
          record2.save!
        end

        expect(record1.persisted?).to be true
        expect(record2.persisted?).to be true

        resp1 = dynamo_client.get_item(table_name: "#{TABLE_PREFIX}-things", key: { 'id' => record1.id })
        resp2 = dynamo_client.get_item(table_name: "#{TABLE_PREFIX}-things", key: { 'id' => record2.id })
        expect(resp1.item['name']).to eq('First')
        expect(resp2.item['name']).to eq('Second')
      end

      it 'supports cross-model transactions' do
        thing = model_class.new(name: 'Thing')
        other = other_model_class.new(title: 'Other')

        model_class.transaction do
          thing.save!
          other.save!
        end

        expect(thing.persisted?).to be true
        expect(other.persisted?).to be true
      end
    end

    describe 'destroy inside transaction' do
      it 'enrolls destroy in the transaction' do
        record = model_class.create!(name: 'ToDelete')
        record_id = record.id

        model_class.transaction do
          record.destroy!
        end

        resp = dynamo_client.get_item(table_name: "#{TABLE_PREFIX}-things", key: { 'id' => record_id })
        expect(resp.item).to be_nil
      end

      it 'commits save and destroy atomically' do
        existing = model_class.create!(name: 'Existing')
        existing_id = existing.id
        new_record = model_class.new(name: 'New')

        model_class.transaction do
          existing.destroy!
          new_record.save!
        end

        resp_existing = dynamo_client.get_item(table_name: "#{TABLE_PREFIX}-things", key: { 'id' => existing_id })
        resp_new = dynamo_client.get_item(table_name: "#{TABLE_PREFIX}-things", key: { 'id' => new_record.id })
        expect(resp_existing.item).to be_nil
        expect(resp_new.item['name']).to eq('New')
      end
    end

    describe 'rollback on exception' do
      it 'does not persist changes when exception raised before commit' do
        record = model_class.new(name: 'NeverSaved')

        expect do
          model_class.transaction do
            record.save!
            raise 'Abort!'
          end
        end.to raise_error('Abort!')

        # Record should have an ID assigned but not be in DynamoDB
        expect(record.id).not_to be_nil
        resp = dynamo_client.get_item(table_name: "#{TABLE_PREFIX}-things", key: { 'id' => record.id })
        expect(resp.item).to be_nil
      end
    end

    describe 'validation inside transaction' do
      let(:validated_class) do
        Class.new(ActiveItem::Base) do
          self.table_name = "#{TABLE_PREFIX}-things"
          attr_accessor :name

          validates :name, presence: true

          def self.name
            'ValidatedThing'
          end
        end.tap { |klass| klass.dynamodb = dynamo_client }
      end

      it 'raises RecordInvalid when save! fails validation' do
        record = validated_class.new(name: nil)

        expect do
          model_class.transaction do
            record.save!
          end
        end.to raise_error(ActiveItem::RecordInvalid)
      end

      it 'returns false when save fails validation' do
        record = validated_class.new(name: nil)
        result = nil

        model_class.transaction do
          result = record.save
        end

        expect(result).to be false
      end
    end

    describe 'mixed explicit and implicit API' do
      it 'supports using both APIs in the same transaction' do
        record1 = model_class.new(name: 'Implicit')
        record2 = model_class.new(name: 'Explicit')

        model_class.transaction do |txn|
          record1.save!
          txn.put(record2)
        end

        expect(record1.persisted?).to be true
        expect(record2.persisted?).to be true
      end
    end

    describe 'empty transaction' do
      it 'handles empty transaction block gracefully' do
        expect do
          model_class.transaction do
            # nothing
          end
        end.not_to raise_error
      end
    end
  end
end
