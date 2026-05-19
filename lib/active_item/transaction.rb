# frozen_string_literal: true

module ActiveItem
  class Transaction
    MAX_ITEMS = 100

    attr_reader :operations

    def initialize
      @operations = []
    end

    def put(record, condition: nil)
      record.instance_variable_set(:@id, SecureRandom.uuid) unless record.id
      pk = record.class.primary_key
      record.instance_variable_set(:"@#{pk}", record.id) if pk != 'id'
      now = Time.now.utc.iso8601
      record.instance_variable_set(:@created_at, now) unless record.created_at
      record.instance_variable_set(:@updated_at, now)

      item = record.send(:build_dynamodb_item).merge(
        'createdAt' => record.created_at,
        'updatedAt' => record.updated_at
      )

      op = { put: { table_name: record.class.table_name, item: item } }
      op[:put][:condition_expression] = condition if condition

      @operations << { op: op, record: record, type: :put }
    end

    def delete(record)
      @operations << {
        op: { delete: { table_name: record.class.table_name, key: { record.class.primary_key.to_s => record.id } } },
        record: record, type: :delete
      }
    end

    def update(record)
      changes = record.changes
      return if changes.empty?

      set_parts = []
      remove_parts = []
      attr_values = {}
      attr_names = {}

      changes.each_with_index do |(field, (_old_val, new_val)), idx|
        dynamo_key = record.class.to_dynamo_key(field)
        if new_val.nil?
          remove_parts << "#f#{idx}"
          attr_names["#f#{idx}"] = dynamo_key
        else
          set_parts << "#f#{idx} = :v#{idx}"
          attr_names["#f#{idx}"] = dynamo_key
          attr_values[":v#{idx}"] = new_val
        end
      end

      set_parts << "updatedAt = :ts"
      attr_values[':ts'] = Time.now.utc.iso8601

      update_expression = "SET #{set_parts.join(', ')}"
      update_expression += " REMOVE #{remove_parts.join(', ')}" if remove_parts.any?

      @operations << {
        op: {
          update: {
            table_name: record.class.table_name,
            key: { record.class.primary_key.to_s => record.id },
            update_expression: update_expression,
            expression_attribute_names: attr_names.any? ? attr_names : nil,
            expression_attribute_values: attr_values
          }.compact
        },
        record: record, type: :update
      }
    end

    def execute!
      return if @operations.empty?
      raise TransactionError, "DynamoDB transactions are limited to #{MAX_ITEMS} items (got #{@operations.length})" if @operations.length > MAX_ITEMS

      transact_items = @operations.map { |o| o[:op] }
      client = @operations.first[:record].class.dynamodb
      client.transact_write_items(transact_items: transact_items)

      @operations.each do |o|
        o[:record].instance_variable_set(:@new_record, false) if o[:type] == :put
      end
    rescue Aws::DynamoDB::Errors::TransactionCanceledException => e
      raise TransactionError, "Transaction cancelled: #{e.message}"
    rescue Aws::DynamoDB::Errors::ValidationException => e
      raise TransactionError, "Transaction validation failed: #{e.message}"
    end
  end
end
