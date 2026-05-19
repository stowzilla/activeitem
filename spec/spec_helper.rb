# frozen_string_literal: true

require 'ostruct'
require 'dynamorecord'

# Stub the DynamoDB client for unit tests
class FakeDynamoClient
  attr_reader :calls

  def initialize
    @calls = []
    @items = {} # table_name => { pk_value => item }
  end

  def put_item(params)
    @calls << [:put_item, params]
    table = params[:table_name]
    @items[table] ||= {}
    item = params[:item]
    pk_key = item.keys.first # Assume first key is PK
    pk_val = item[pk_key]

    # Check condition expression for uniqueness
    if params[:condition_expression]&.include?('attribute_not_exists') && @items[table][pk_val]
      raise Aws::DynamoDB::Errors::ConditionalCheckFailedException.new(nil, 'Item already exists')
    end

    @items[table][pk_val] = item
    OpenStruct.new
  end

  def get_item(params)
    @calls << [:get_item, params]
    table = params[:table_name]
    key_value = params[:key].values.first
    item = (@items[table] || {})[key_value]
    OpenStruct.new(item: item)
  end

  def delete_item(params)
    @calls << [:delete_item, params]
    table = params[:table_name]
    key_value = params[:key].values.first
    (@items[table] || {}).delete(key_value)
    OpenStruct.new
  end

  def update_item(params)
    @calls << [:update_item, params]
    OpenStruct.new
  end

  def query(params)
    @calls << [:query, params]
    OpenStruct.new(items: [], last_evaluated_key: nil)
  end

  def scan(params)
    @calls << [:scan, params]
    table = params[:table_name]
    items = (@items[table] || {}).values

    if params[:select] == 'COUNT'
      OpenStruct.new(count: items.length, items: [], last_evaluated_key: nil)
    else
      OpenStruct.new(items: items, last_evaluated_key: nil)
    end
  end

  def batch_get_item(params)
    @calls << [:batch_get_item, params]
    results = {}
    params[:request_items].each do |table_name, config|
      results[table_name] = config[:keys].filter_map do |key|
        key_value = key.values.first
        (@items[table_name] || {})[key_value]
      end
    end
    OpenStruct.new(responses: results, unprocessed_keys: {})
  end

  def batch_write_item(params)
    @calls << [:batch_write_item, params]
    params[:request_items].each do |table_name, requests|
      @items[table_name] ||= {}
      requests.each do |req|
        if req[:put_request]
          item = req[:put_request][:item]
          pk_val = item.values.first
          @items[table_name][pk_val] = item
        end
      end
    end
    OpenStruct.new(unprocessed_items: {})
  end

  def transact_write_items(params)
    @calls << [:transact_write_items, params]
    OpenStruct.new
  end

  def transact_get_items(params)
    @calls << [:transact_get_items, params]
    responses = params[:transact_items].map { OpenStruct.new(item: nil) }
    OpenStruct.new(responses: responses)
  end

  # Inject an item directly (for test setup)
  def seed(table_name, pk_value, item)
    @items[table_name] ||= {}
    @items[table_name][pk_value] = item
  end
end

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.filter_run_when_matching :focus
  config.order = :random

  config.before(:each) do
    @fake_dynamo = FakeDynamoClient.new
  end
end
