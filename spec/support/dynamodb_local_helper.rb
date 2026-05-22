# frozen_string_literal: true

require 'aws-sdk-dynamodb'

module DynamoDBLocalHelper
  ENDPOINT = ENV.fetch('DYNAMODB_ENDPOINT', 'http://localhost:8000')

  def self.client
    @client ||= Aws::DynamoDB::Client.new(
      endpoint: ENDPOINT,
      region: 'us-east-1',
      access_key_id: 'fakeMyKeyId',
      secret_access_key: 'fakeSecretAccessKey'
    )
  end

  def self.create_table(table_name, key_schema: nil, gsis: [])
    key_schema ||= [{ attribute_name: 'id', key_type: 'HASH' }]
    attribute_definitions = key_schema.map { |k| { attribute_name: k[:attribute_name], attribute_type: 'S' } }

    gsis.each do |gsi|
      gsi[:key_schema].each do |k|
        unless attribute_definitions.any? { |ad| ad[:attribute_name] == k[:attribute_name] }
          attribute_definitions << { attribute_name: k[:attribute_name], attribute_type: 'S' }
        end
      end
    end

    params = {
      table_name: table_name,
      key_schema: key_schema,
      attribute_definitions: attribute_definitions,
      billing_mode: 'PAY_PER_REQUEST'
    }

    if gsis.any?
      params[:global_secondary_indexes] = gsis.map do |gsi|
        {
          index_name: gsi[:index_name],
          key_schema: gsi[:key_schema],
          projection: { projection_type: 'ALL' }
        }
      end
    end

    client.create_table(params)
  rescue Aws::DynamoDB::Errors::ResourceInUseException
    # Table already exists — fine
  end

  def self.delete_table(table_name)
    client.delete_table(table_name: table_name)
  rescue Aws::DynamoDB::Errors::ResourceNotFoundException
    # Already gone
  end

  def self.truncate_table(table_name)
    scan = client.scan(table_name: table_name)
    # Determine the key schema to build delete keys
    desc = client.describe_table(table_name: table_name)
    key_attrs = desc.table.key_schema.map(&:attribute_name)

    scan.items.each do |item|
      key = key_attrs.each_with_object({}) { |k, h| h[k] = item[k] }
      client.delete_item(table_name: table_name, key: key)
    end
  end
end
