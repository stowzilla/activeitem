# frozen_string_literal: true

require 'ostruct'
require 'activeitem'
require_relative 'support/dynamodb_local_helper'

# parallel_tests sets TEST_ENV_NUMBER for each worker ('' for first, '2', '3', etc.)
TEST_WORKER = ENV.fetch('TEST_ENV_NUMBER', '')
TABLE_PREFIX = "test#{TEST_WORKER}-dev"

# Tables used across specs and their GSI definitions
TABLES = {
  "#{TABLE_PREFIX}-users" => {
    gsis: [
      { index_name: 'EmailIndex', key_schema: [{ attribute_name: 'email', key_type: 'HASH' }] },
      { index_name: 'StatusIndex', key_schema: [{ attribute_name: 'status', key_type: 'HASH' }, { attribute_name: 'createdAt', key_type: 'RANGE' }] }
    ]
  },
  "#{TABLE_PREFIX}-widgets" => { gsis: [] },
  "#{TABLE_PREFIX}-widgets-custom-pk" => { key_schema: [{ attribute_name: 'widget_id', key_type: 'HASH' }], gsis: [] },
  "#{TABLE_PREFIX}-things" => { gsis: [] },
  "#{TABLE_PREFIX}-items" => {
    gsis: [
      { index_name: 'StatusIndex', key_schema: [{ attribute_name: 'status', key_type: 'HASH' }, { attribute_name: 'createdAt', key_type: 'RANGE' }] },
      { index_name: 'CustomerIndex', key_schema: [{ attribute_name: 'customerId', key_type: 'HASH' }] }
    ]
  },
  "#{TABLE_PREFIX}-events" => {
    gsis: [
      { index_name: 'CustomerIndex', key_schema: [{ attribute_name: 'customerId', key_type: 'HASH' }, { attribute_name: 'createdAt', key_type: 'RANGE' }] }
    ]
  },
  "#{TABLE_PREFIX}-customers" => { gsis: [] },
  "#{TABLE_PREFIX}-authors" => { gsis: [] },
  "#{TABLE_PREFIX}-books" => {
    gsis: [
      { index_name: 'AuthorIndex', key_schema: [{ attribute_name: 'authorId', key_type: 'HASH' }] }
    ]
  },
  "#{TABLE_PREFIX}-parents" => { gsis: [] },
  "#{TABLE_PREFIX}-children" => {
    gsis: [
      { index_name: 'ParentIndex', key_schema: [{ attribute_name: 'parentId', key_type: 'HASH' }] }
    ]
  },
  "#{TABLE_PREFIX}-scoped-users" => {
    gsis: [
      { index_name: 'EmailOrgIndex', key_schema: [{ attribute_name: 'email', key_type: 'HASH' }, { attribute_name: 'orgId', key_type: 'RANGE' }] }
    ]
  }
}.freeze

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.filter_run_when_matching :focus
  config.order = :random

  config.before(:suite) do
    ActiveItem.configure do |c|
      c.table_prefix = "test#{TEST_WORKER}"
      c.environment = 'dev'
    end

    DynamoDBLocalHelper.verify_connectivity!

    TABLES.each do |table_name, opts|
      DynamoDBLocalHelper.create_table(table_name, key_schema: opts[:key_schema], gsis: opts[:gsis])
    end
  end

  config.after(:suite) do
    TABLES.each_key do |table_name|
      DynamoDBLocalHelper.delete_table(table_name)
    end
  end

  config.before(:each) do
    @dynamo_client = DynamoDBLocalHelper.client
  end

  config.after(:each) do
    TABLES.each_key do |table_name|
      DynamoDBLocalHelper.truncate_table(table_name)
    end
  end
end
