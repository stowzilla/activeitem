# frozen_string_literal: true

require 'spec_helper'

# Regression for the returns "Unauthorized" bug (stowzilla).
#
# where(id: [...]) takes the batch_find optimization and returns a Relation
# that is already loaded with the requested records but whose `conditions`
# hash is empty (the ids were consumed into preloaded_records). Relation#first
# used to route through limit(1) -> spawn, producing a fresh, condition-less
# relation that scanned the table and returned an ARBITRARY record — frequently
# one belonging to a different owner. #each/#length/#to_a were unaffected, so
# ownership checks that iterated passed while a later items.first.user_id read
# picked up a stranger's id.
RSpec.describe 'ActiveItem::Relation#first on a preloaded (batch_find) relation' do
  let(:dynamo_client) { @dynamo_client }

  let(:model_class) do
    Class.new(ActiveItem::Base) do
      self.table_name = "#{TABLE_PREFIX}-widgets"
      attr_accessor :owner_id

      def self.name
        'Widget'
      end
    end.tap { |klass| klass.dynamodb = dynamo_client }
  end

  before do
    # Items we will actually request, all owned by "me".
    dynamo_client.put_item(table_name: "#{TABLE_PREFIX}-widgets", item: { 'id' => 'mine-1', 'owner_id' => 'me' })
    dynamo_client.put_item(table_name: "#{TABLE_PREFIX}-widgets", item: { 'id' => 'mine-2', 'owner_id' => 'me' })

    # Foreign items that must never leak through #first. Lower-sorting ids so a
    # naive table scan would surface one of them first.
    dynamo_client.put_item(table_name: "#{TABLE_PREFIX}-widgets", item: { 'id' => 'aaa-other', 'owner_id' => 'someone-else' })
    dynamo_client.put_item(table_name: "#{TABLE_PREFIX}-widgets", item: { 'id' => 'aab-other', 'owner_id' => 'someone-else' })
  end

  it 'returns one of the requested records, not an arbitrary table record' do
    relation = model_class.where(id: %w[mine-1 mine-2])

    expect(%w[mine-1 mine-2]).to include(relation.first.id)
    expect(relation.first.owner_id).to eq('me')
  end

  it 'agrees with #to_a.first' do
    relation = model_class.where(id: %w[mine-1 mine-2])

    expect(relation.first.id).to eq(relation.to_a.first.id)
  end

  it 'keeps #each/#length/#first consistent on the same relation' do
    relation = model_class.where(id: %w[mine-1 mine-2])

    expect(relation.length).to eq(2)
    expect(relation.map(&:owner_id).uniq).to eq(['me'])
    expect(relation.first.owner_id).to eq('me')
  end

  it 'returns nil for an empty preloaded relation rather than scanning' do
    relation = model_class.where(id: %w[does-not-exist])

    expect(relation.first).to be_nil
  end
end
