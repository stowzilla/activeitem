# frozen_string_literal: true

require 'ostruct'
require 'activeitem'
require_relative 'support/dynamodb_local_helper'

# Tables used across specs and their GSI definitions
TABLES = {
  'test-dev-users' => {
    gsis: [
      { index_name: 'EmailIndex', key_schema: [{ attribute_name: 'email', key_type: 'HASH' }] },
      { index_name: 'StatusIndex', key_schema: [{ attribute_name: 'status', key_type: 'HASH' }, { attribute_name: 'createdAt', key_type: 'RANGE' }] }
    ]
  },
  'test-dev-widgets' => { gsis: [] },
  'test-dev-widgets-custom-pk' => { key_schema: [{ attribute_name: 'widget_id', key_type: 'HASH' }], gsis: [] },
  'test-dev-things' => { gsis: [] },
  'test-dev-items' => {
    gsis: [
      { index_name: 'StatusIndex', key_schema: [{ attribute_name: 'status', key_type: 'HASH' }, { attribute_name: 'createdAt', key_type: 'RANGE' }] },
      { index_name: 'CustomerIndex', key_schema: [{ attribute_name: 'customerId', key_type: 'HASH' }] }
    ]
  },
  'test-dev-events' => {
    gsis: [
      { index_name: 'CustomerIndex',
        key_schema: [{ attribute_name: 'customerId', key_type: 'HASH' }, { attribute_name: 'createdAt', key_type: 'RANGE' }] }
    ]
  },
  'test-dev-customers' => { gsis: [] },
  'test-dev-authors' => { gsis: [] },
  'test-dev-books' => {
    gsis: [
      { index_name: 'AuthorIndex', key_schema: [{ attribute_name: 'authorId', key_type: 'HASH' }] }
    ]
  },
  'test-dev-parents' => { gsis: [] },
  'test-dev-children' => {
    gsis: [
      { index_name: 'ParentIndex', key_schema: [{ attribute_name: 'parentId', key_type: 'HASH' }] }
    ]
  },
  'test-dev-scoped-users' => {
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
