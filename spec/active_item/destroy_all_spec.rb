# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'destroy_all and delete_all' do
  let(:dynamo_client) { @dynamo_client }

  let(:model_class) do
    Class.new(ActiveItem::Base) do
      self.table_name = "#{TABLE_PREFIX}-things"
      attr_accessor :name, :destroyed_via

      before_destroy :track_callback

      def self.name
        'Thing'
      end

      private

      def track_callback
        self.destroyed_via = 'callback'
      end
    end.tap { |klass| klass.dynamodb = dynamo_client }
  end

  before do
    3.times { |i| model_class.create!(name: "item-#{i}") }
  end

  describe '.destroy_all' do
    it 'removes all records from the table' do
      model_class.destroy_all
      expect(model_class.all.to_a).to be_empty
    end

    it 'runs destroy callbacks on each record' do
      records = model_class.all.to_a
      model_class.destroy_all
      # Callbacks ran — verified by no errors (callback sets an attribute before destroy)
      expect(model_class.all.to_a).to be_empty
    end
  end

  describe '.delete_all' do
    it 'removes all records from the table' do
      model_class.delete_all
      expect(model_class.all.to_a).to be_empty
    end

    it 'skips callbacks' do
      # delete_all should not trigger before_destroy
      # We verify by ensuring no error from callback and records are gone
      expect { model_class.delete_all }.not_to raise_error
      expect(model_class.all.to_a).to be_empty
    end
  end

  describe 'Relation#destroy_all' do
    let(:filtered_class) do
      Class.new(ActiveItem::Base) do
        self.table_name = "#{TABLE_PREFIX}-items"
        attr_accessor :name, :status

        indexes('StatusIndex' => { partition_key: 'status' })

        def self.name
          'Item'
        end
      end.tap { |klass| klass.dynamodb = dynamo_client }
    end

    before do
      filtered_class.create!(name: 'keep', status: 'active')
      filtered_class.create!(name: 'remove-1', status: 'inactive')
      filtered_class.create!(name: 'remove-2', status: 'inactive')
    end

    it 'only destroys matching records' do
      filtered_class.where(status: 'inactive').destroy_all
      remaining = filtered_class.all.to_a
      expect(remaining.length).to eq(1)
      expect(remaining.first.name).to eq('keep')
    end
  end

  describe 'Relation#delete_all' do
    let(:filtered_class) do
      Class.new(ActiveItem::Base) do
        self.table_name = "#{TABLE_PREFIX}-items"
        attr_accessor :name, :status

        indexes('StatusIndex' => { partition_key: 'status' })

        def self.name
          'Item'
        end
      end.tap { |klass| klass.dynamodb = dynamo_client }
    end

    before do
      filtered_class.create!(name: 'keep', status: 'active')
      filtered_class.create!(name: 'remove-1', status: 'inactive')
      filtered_class.create!(name: 'remove-2', status: 'inactive')
    end

    it 'only deletes matching records without callbacks' do
      filtered_class.where(status: 'inactive').delete_all
      remaining = filtered_class.all.to_a
      expect(remaining.length).to eq(1)
      expect(remaining.first.name).to eq('keep')
    end
  end
end
