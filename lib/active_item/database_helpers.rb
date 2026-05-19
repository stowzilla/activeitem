# frozen_string_literal: true

require 'set'

module ActiveItem
  module DatabaseHelpers
    def get(key)
      response = dynamodb.get_item(table_name: table_name, key: key)
      response.item
    rescue Aws::DynamoDB::Errors::AccessDeniedException => e
      raise_access_denied('GetItem', e)
    end

    def put(item)
      dynamodb.put_item(table_name: table_name, item: item)
    rescue Aws::DynamoDB::Errors::AccessDeniedException => e
      raise_access_denied('PutItem', e)
    end

    def delete(key)
      dynamodb.delete_item(table_name: table_name, key: key)
    rescue Aws::DynamoDB::Errors::AccessDeniedException => e
      raise_access_denied('DeleteItem', e)
    end

    def exists?(key)
      !get(key).nil?
    end

    def query(key_condition_expression:, expression_attribute_values:, **options)
      query_params = {
        table_name: table_name,
        key_condition_expression: key_condition_expression,
        expression_attribute_values: expression_attribute_values
      }.merge(options)

      response = dynamodb.query(query_params)
      response.items
    rescue Aws::DynamoDB::Errors::AccessDeniedException => e
      raise_access_denied('Query', e)
    end

    def scan(limit: nil, filter_expression: nil, expression_attribute_names: nil, expression_attribute_values: nil, projection_expression: nil)
      params = { table_name: table_name }
      params[:limit] = limit if limit
      params[:filter_expression] = filter_expression if filter_expression
      params[:expression_attribute_names] = expression_attribute_names if expression_attribute_names
      params[:expression_attribute_values] = expression_attribute_values if expression_attribute_values
      params[:projection_expression] = projection_expression if projection_expression

      items = []
      seen_ids = Set.new
      last_evaluated_key = nil

      loop do
        params[:exclusive_start_key] = last_evaluated_key if last_evaluated_key
        response = dynamodb.scan(params)

        response.items.each do |item|
          pk_value = item[primary_key.to_s]
          unless seen_ids.include?(pk_value)
            seen_ids.add(pk_value)
            items << item
          end
        end

        last_evaluated_key = response.last_evaluated_key
        break unless last_evaluated_key
        break if limit && items.length >= limit
      end

      items
    rescue Aws::DynamoDB::Errors::AccessDeniedException => e
      raise_access_denied('Scan', e)
    end

    private

    def raise_access_denied(operation, original_error)
      raise ActiveItem::AccessDeniedError.new(model_name: name, table: table_name,
                                                operation: operation, original_error: original_error)
    end
  end
end
