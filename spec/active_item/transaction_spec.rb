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

  describe '#put' do
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
end
