# encoding: utf-8

require_relative 'relation'

module ActiveItem
  module QueryHelpers

    def find(id)
      record = get({ primary_key.to_s => id })
      raise ActiveItem::RecordNotFound, "Couldn't find #{name} with '#{primary_key}'=#{id}" unless record
      instantiate(record)
    end

    # Batch find multiple records by primary key using DynamoDB's BatchGetItem
    # Much more efficient than multiple .find() calls
    #
    # @example
    #   Customer.batch_find(['cust-1', 'cust-2', 'cust-3'])
    #   # => [#<Customer id="cust-1">, #<Customer id="cust-2">, #<Customer id="cust-3">]
    #
    # @param ids [Array] Array of primary key values
    # @return [Array] Array of model instances (silently skips IDs not found)
    def batch_find(ids)
      return [] if ids.empty?

      results = []
      ids.each_slice(100) do |id_chunk|
        keys = id_chunk.map { |id| { primary_key.to_s => id } }
        request = { table_name => { keys: keys } }

        # Retry loop for unprocessed keys (DynamoDB may throttle under load)
        max_retries = 5
        retries = 0

        while request&.any?
          response = dynamodb.batch_get_item(request_items: request)

          items = response.responses[table_name] || []
          results.concat(items.map { |item| instantiate(item) })

          # Check for unprocessed keys and retry with exponential backoff + jitter
          unprocessed = response.unprocessed_keys
          if unprocessed&.any?
            retries += 1
            break if retries > max_retries

            sleep(0.05 * (2**retries) * (0.5 + rand * 0.5))
            request = unprocessed
          else
            break
          end
        end
      end

      results
    rescue Aws::DynamoDB::Errors::AccessDeniedException => e
      raise ActiveItem::AccessDeniedError.new(model_name: name, table: table_name,
                                                operation: 'BatchGetItem', original_error: e)
    end

    # Batch write multiple records using DynamoDB's BatchWriteItem
    # Much more efficient than individual PutItem calls (25 items per request vs 1)
    #
    # WARNING: This bypasses callbacks (before_create, after_create, etc.),
    # validations, and conditional writes (attribute_not_exists). Records are
    # written as raw PutItem operations. Use this only when you need raw
    # throughput and are confident the data is already valid.
    #
    # @example
    #   items = 30.times.map { |i| InventoryItem.new(name: "Item #{i}", ...) }
    #   InventoryItem.batch_write(items)
    #
    # @param records [Array<ActiveItem::Base>] Records to write
    # @return [Array<ActiveItem::Base>] The records with IDs and timestamps assigned
    def batch_write(records)
      return [] if records.empty?

      now = Time.now.utc.iso8601

      # Prepare each record: assign ID and timestamps
      records.each do |record|
        record.instance_variable_set(:@id, SecureRandom.uuid) unless record.id
        pk = primary_key
        record.instance_variable_set(:"@#{pk}", record.id) if pk != 'id'
        record.instance_variable_set(:@created_at, now) unless record.created_at
        record.instance_variable_set(:@updated_at, now)
      end

      # DynamoDB BatchWriteItem limit is 25 items per request
      records.each_slice(25) do |chunk|
        write_requests = chunk.map do |record|
          { put_request: { item: record.send(:build_dynamodb_item).merge('createdAt' => record.created_at, 'updatedAt' => record.updated_at) } }
        end

        request = { table_name => write_requests }
        max_retries = 5
        retries = 0

        while request&.any?
          response = dynamodb.batch_write_item(request_items: request)

          unprocessed = response.unprocessed_items
          if unprocessed&.any?
            retries += 1
            break if retries > max_retries

            sleep(0.05 * (2**retries) * (0.5 + rand * 0.5))
            request = unprocessed
          else
            break
          end
        end
      end

      records.each { |r| r.instance_variable_set(:@new_record, false) }
      records
    rescue Aws::DynamoDB::Errors::AccessDeniedException => e
      raise ActiveItem::AccessDeniedError.new(model_name: name, table: table_name,
                                                operation: 'BatchWriteItem', original_error: e)
    end

    def find_by(**conditions)
      where(**conditions).first
    end

    # Chainable where method with GSI support - returns a Relation for lazy evaluation
    #
    # @example Simple query
    #   Pickup.where(status: 'pending')
    #
    # @example Chained queries (Rails-like!)
    #   slots = AvailabilitySlot.where(employee_id: '123')
    #   slots = slots.where(zip_code: '32780') if zip_code?
    #   slots.each { |s| puts s.id }
    #
    # @example With explicit index
    #   Pickup.where(customer_id: '123', index: 'CustomerIndex')
    #
    # @example Auto-detected index (if model defines indexes)
    #   Pickup.where(customer_id: '123')  # Uses CustomerIndex if defined
    #
    # @example Multiple conditions (first is partition key, rest are filters)
    #   Pickup.where(status: 'pending', pickup_date: '2024-01-15')
    #
    # @example Negation with where.not (Rails-like!)
    #   Container.where.not(parent_container_id: nil)  # Has a parent
    #   Container.where(status: 'active').not(archived: true)
    #
    # @example Case-insensitive search (ilike option)
    #   Container.where(name: 'box', ilike: true)              # Substring match
    #   Container.where(name: 'box', ilike: true, exact: true) # Exact case-insensitive
    #
    # @example Batch find by primary key (automatically uses BatchGetItem)
    #   Customer.where(customer_id: ['cust-1', 'cust-2', 'cust-3'])
    #   # Equivalent to: Customer.batch_find(['cust-1', 'cust-2', 'cust-3'])
    #
    def where(**conditions)
      # If no conditions, return a Relation that supports .not() chaining
      return Relation.new(self) if conditions.empty?

      # Extract special options
      index_name = conditions.delete(:index) || conditions.delete(:index_name)
      ilike = conditions.delete(:ilike) || false
      exact = conditions.delete(:exact) || false

      # Optimization: Detect primary key array queries and use batch_find
      # This makes Customer.where(customer_id: [ids]) automatically efficient
      # Also supports .where(id: [ids]) since 'id' is aliased to the primary key
      if conditions.size == 1 && !index_name
        key = conditions.keys.first.to_s
        value = conditions.values.first

        # Check if querying primary key with an array
        # Accept both the actual primary key name (e.g., 'customer_id') and 'id' (the alias)
        is_primary_key_query = key == primary_key.to_s || key == 'id'

        if is_primary_key_query && value.is_a?(Array)
          # Return a Relation wrapping the batch_find results
          # This allows further chaining like .where(...).map(&:to_h)
          return Relation.new(self, preloaded_records: batch_find(value))
        end
      end

      Relation.new(self, conditions: conditions, index_name: index_name, ilike: ilike, ilike_exact: exact)
    end

    # Returns a Relation for all records (enables chaining from .all)
    def all(limit: nil)
      if limit
        Relation.new(self, limit_value: limit)
      else
        Relation.new(self)
      end
    end

    # Returns a Relation with associations to preload (enables chaining from .includes)
    def includes(*associations)
      Relation.new(self, includes_associations: associations.flatten)
    end

    # Recent records, newest first. Single query against RecentIndex GSI.
    #
    # Requires a RecentIndex GSI on the DynamoDB table with a fixed partition key
    # (default: _recent_pk = "ALL") and createdAt as the sort key.
    #
    # @param limit [Integer] max records to return (default 50)
    # @return [Relation] chainable relation sorted newest-first
    def recent(limit: 50)
      where(_recent_pk: 'ALL', index: 'RecentIndex').order(:desc).limit(limit)
    end

    # Most recent record. Convenience wrapper around .recent.
    def last
      recent(limit: 1).first
    end

    def none
      Relation.new(self).none
    end

    # Convenience method that immediately returns array (for backwards compat)
    def all_records(limit: nil)
      items = scan(limit: limit)
      items.map { |item| instantiate(item) }
    end

    def first
      all.first
    end

    def last
      all.last
    end

    # Count records with optional conditions or block
    #
    # @example Count all records
    #   Customer.count  # => 42
    #
    # @example Count with conditions
    #   Customer.count(status: 'active')  # => 30
    #
    # @example Count with block (Rails-like, loads all records)
    #   Customer.count { |c| c.email.include?('@gmail.com') }  # => 15
    #
    def count(**conditions, &block)
      if block_given?
        # Block provided - load all records and count with Ruby
        all.count(&block)
      elsif conditions.empty?
        # No conditions, no block - use efficient DynamoDB COUNT
        response = dynamodb.scan(
          table_name: table_name,
          select: 'COUNT'
        )
        response.count
      else
        # Conditions provided - delegate to where().count
        where(**conditions).count
      end
    end

    # Rails-like exists? method that accepts attribute conditions or a single ID
    #
    # @example Check by primary key (single ID)
    #   Customer.exists?('cust-123')
    #   EmailSuppression.exists?('test@example.com')
    #
    # @example Check by primary key (hash)
    #   Customer.exists?(id: 'cust-123')
    #   EmailSuppression.exists?(email: 'test@example.com')
    #
    # @example Check by any attributes
    #   Customer.exists?(email: 'test@example.com', status: 'active')
    #   Pickup.exists?(customer_id: 'cust-123', status: 'pending')
    #
    # @param id_or_conditions [String, Hash] Primary key value or attribute conditions
    # @return [Boolean] true if a record exists matching the conditions
    def exists?(id_or_conditions = nil, **conditions)
      # Handle single ID parameter: Customer.exists?('cust-123')
      if id_or_conditions.is_a?(String) && conditions.empty?
        return !!get({ primary_key.to_s => id_or_conditions })
      end

      # Merge positional hash with keyword arguments if both provided
      if id_or_conditions.is_a?(Hash)
        conditions = id_or_conditions.merge(conditions)
      end

      # If checking by primary key only, use the efficient get operation
      if conditions.keys.size == 1 && conditions.key?(primary_key.to_sym)
        return !!get({ primary_key.to_s => conditions[primary_key.to_sym] })
      end

      # For other conditions, use where with limit 1 and count
      where(**conditions).limit(1).count > 0
    end

    def delete_all
      all.destroy_all
    end

    # Define GSI indexes for the model
    # This enables automatic index detection in where() queries
    #
    # @example
    #   class Pickup < ActiveItem::Base
    #     indexes(
    #       'CustomerIndex' => { partition_key: 'customer_id' },
    #       'StatusIndex' => { partition_key: 'status', sort_key: 'pickup_date' },
    #       'EmployeeIndex' => { partition_key: 'assigned_employee_id', sort_key: 'pickup_date' }
    #     )
    #   end
    #
    RECENT_INDEX = { 'RecentIndex' => { partition_key: '_recent_pk', sort_key: 'createdAt' } }.freeze

    def indexes(index_definitions = nil)
      if index_definitions
        @index_definitions = index_definitions
      else
        RECENT_INDEX.merge(@index_definitions || {})
      end
    end

    private

    # Detect which index to use based on query conditions
    # Used by Relation class
    def detect_index_for_conditions(conditions)
      return nil if indexes.empty?

      ruby_partition_key = conditions.keys.first.to_s
      partition_value = conditions.values.first

      # Can't use GSI query with nil value - must scan with attribute_not_exists
      return nil if partition_value.nil?

      # Convert Ruby attribute name to DynamoDB key name for comparison
      dynamo_partition_key = to_dynamo_key(ruby_partition_key)

      # First, try to find an index with the converted partition key
      indexes.each do |index_name, config|
        if config[:partition_key].to_s == dynamo_partition_key
          return index_name
        end
      end

      # Also try the original Ruby key (for legacy indexes defined with snake_case)
      indexes.each do |index_name, config|
        if config[:partition_key].to_s == ruby_partition_key
          return index_name
        end
      end

      # If not found, check if this is an association-based attribute
      # e.g., customer_id might map to user_id via belongs_to :customer, foreign_key: :user_id
      resolved_key = resolve_association_foreign_key_for_query(ruby_partition_key)

      if resolved_key
        dynamo_resolved_key = to_dynamo_key(resolved_key)
        indexes.each do |index_name, config|
          pk = config[:partition_key].to_s
          if pk == dynamo_resolved_key || pk == resolved_key
            return index_name
          end
        end
      end

      nil
    end

    # Resolve association-based attribute names to their actual foreign keys for queries
    # e.g., customer_id -> user_id if belongs_to :customer, foreign_key: :user_id
    def resolve_association_foreign_key_for_query(attr_name)
      return nil unless attr_name.end_with?('_id')

      # Extract the association name (remove _id suffix)
      association_name = attr_name.chomp('_id').to_sym

      # Check if this association exists
      associations = _associations || {}
      association_config = associations[association_name]

      return nil unless association_config
      return nil unless association_config[:type] == :belongs_to

      # Get the foreign key from the association
      foreign_key = association_config[:foreign_key]

      # If the foreign key is different from the attribute name, return it
      foreign_key.to_s != attr_name ? foreign_key.to_s : nil
    end

    # Build a condition expression for a single attribute
    # Supports:
    # - Simple attributes: { status: 'active' }
    # - Dot notation for nested: { 'address.zip_code' => '12345' }
    # - Nested hash syntax: { address: { zip_code: '12345' } }
    # - Array values (IN): { status: ['active', 'pending'] }
    # - Range values (BETWEEN): { date: Date.today..Date.today + 7 }
    # - Beginless range (<=): { date: ..Date.today }
    # - Endless range (>=): { date: Date.today.. }
    # - Model objects: { parent_container: container } -> uses container.id
    #
    # Note: Attribute names are converted from Ruby snake_case to DynamoDB camelCase
    #
    # @param attr [String, Symbol] Attribute name (can include dots for nested)
    # @param val [Object] Value to match (can be Hash for nested, Array for IN, Range for BETWEEN, nil for NOT EXISTS, or a ActiveItem model)
    # @param idx [Integer] Index for unique placeholder names
    # @param ilike [Boolean] If true, use case-insensitive contains() matching
    # @return [Array<String, Hash, Hash>] [expression, attribute_names, attribute_values]
    def build_condition_expression(attr, val, idx, ilike: false)
      attr_str = attr.to_s

      # Convert Ruby snake_case to DynamoDB camelCase for the attribute name
      dynamo_attr = to_dynamo_key(attr_str)

      # Handle nil - use attribute_not_exists (DynamoDB doesn't support = NULL)
      if val.nil?
        return ["attribute_not_exists(#attr#{idx})", { "#attr#{idx}" => dynamo_attr }, {}]
      end

      # Handle case-insensitive search with ilike option
      # Uses DynamoDB's `contains` function with downcased value
      if ilike && val.is_a?(String)
        return build_ilike_condition(dynamo_attr, val, idx)
      end

      # Handle ActiveItem model objects - extract primary key value
      # This allows queries like: Container.where(parent_container: some_container)
      # Also converts association name to foreign key (parent_container -> parent_container_id)
      if val.is_a?(ActiveItem::Base)
        val = val.send(val.class.primary_key)
        # Convert association name to foreign key if it doesn't already end with _id
        attr_str = "#{attr_str}_id" unless attr_str.end_with?('_id')
        dynamo_attr = to_dynamo_key(attr_str)
      end

      # Handle nested hash syntax: { address: { zip_code: '12345' } }
      if val.is_a?(Hash)
        return build_nested_hash_conditions(dynamo_attr, val, idx)
      end

      # Handle dot notation: 'address.zip_code'
      if attr_str.include?('.')
        return build_dot_notation_condition(attr_str, val, idx)
      end

      # Handle Range values (BETWEEN, >=, <=)
      if val.is_a?(Range)
        return build_range_condition(dynamo_attr, val, idx)
      end

      # Handle array values (IN clause)
      if val.is_a?(Array)
        return build_in_condition(dynamo_attr, val, idx)
      end

      # Simple equality condition (use placeholder for reserved words)
      build_simple_condition(dynamo_attr, val, idx)
    end

    # Build case-insensitive condition using DynamoDB's contains function
    # Note: This is a substring match. For exact case-insensitive matching,
    # use exact: true which adds Ruby-side filtering.
    #
    # @param attr [String] Attribute name
    # @param val [String] Search value (will be downcased)
    # @param idx [Integer] Index for unique placeholder names
    # @return [Array<String, Hash, Hash>] [expression, attribute_names, attribute_values]
    def build_ilike_condition(attr, val, idx)
      # For case-insensitive search, we can't rely on DynamoDB's case-sensitive contains()
      # Instead, we'll return a condition that matches more broadly and filter in Ruby
      # We use attribute_exists to ensure the field exists, then filter everything in Ruby
      [
        "attribute_exists(#attr#{idx})",
        { "#attr#{idx}" => attr },
        {}
      ]
    end

    # Build condition for nested hash: { address: { zip_code: '12345' } }
    # Converts nested keys to camelCase for DynamoDB compatibility
    def build_nested_hash_conditions(parent_attr, nested_hash, base_idx)
      expressions = []
      all_names = {}
      all_values = {}

      nested_hash.each_with_index do |(nested_key, nested_val), nested_idx|
        dynamo_nested_key = to_dynamo_key(nested_key.to_s)
        full_path = "#{parent_attr}.#{dynamo_nested_key}"
        idx = "#{base_idx}_#{nested_idx}"

        if nested_val.is_a?(Hash)
          # Recursively handle deeper nesting
          expr, names, values = build_nested_hash_conditions(full_path, nested_val, idx)
          expressions << expr
          all_names.merge!(names)
          all_values.merge!(values)
        else
          expr, names, values = build_dot_notation_condition(full_path, nested_val, idx)
          expressions << expr
          all_names.merge!(names)
          all_values.merge!(values)
        end
      end

      [expressions.join(' AND '), all_names, all_values]
    end

    # Build condition for dot notation: 'address.zip_code' => '12345'
    def build_dot_notation_condition(attr_path, val, idx)
      parts = attr_path.split('.')

      # Build path expression with attribute name placeholders
      path_placeholders = parts.map.with_index { |_, i| "#attr#{idx}_#{i}" }
      path_expr = path_placeholders.join('.')

      # Build attribute names map
      names = {}
      parts.each_with_index do |part, i|
        names["#attr#{idx}_#{i}"] = part
      end

      if val.is_a?(Array)
        # IN clause for nested attribute
        placeholders = val.map.with_index { |_, i| ":val#{idx}_#{i}" }
        values = {}
        val.each_with_index { |v, i| values[":val#{idx}_#{i}"] = v }
        ["#{path_expr} IN (#{placeholders.join(', ')})", names, values]
      else
        ["#{path_expr} = :val#{idx}", names, { ":val#{idx}" => val }]
      end
    end

    # Build IN condition for array values
    def build_in_condition(attr, values_array, idx)
      placeholders = values_array.map.with_index { |_, i| ":val#{idx}_#{i}" }
      values = {}
      values_array.each_with_index { |v, i| values[":val#{idx}_#{i}"] = v }

      # Use placeholder for attribute name (handles reserved words)
      ["#attr#{idx} IN (#{placeholders.join(', ')})", { "#attr#{idx}" => attr }, values]
    end

    # Build simple equality condition
    def build_simple_condition(attr, val, idx)
      # Use placeholder for attribute name (handles reserved words like 'status')
      ["#attr#{idx} = :val#{idx}", { "#attr#{idx}" => attr }, { ":val#{idx}" => val }]
    end

    # Build Range condition (BETWEEN, >=, <=)
    # Supports:
    # - Full range: date: Date.today..Date.today + 7 -> BETWEEN
    # - Beginless range: date: ..Date.today -> <=
    # - Endless range: date: Date.today.. -> >=
    #
    # @param attr [String] Attribute name
    # @param range [Range] Range value
    # @param idx [Integer] Index for unique placeholder names
    # @return [Array<String, Hash, Hash>] [expression, attribute_names, attribute_values]
    def build_range_condition(attr, range, idx)
      names = { "#attr#{idx}" => attr }

      # Normalize range values to strings (for dates, times, etc.)
      range_begin = normalize_range_value(range.begin)
      range_end = normalize_range_value(range.end)

      if range_begin.nil?
        # Beginless range: ..end_value (<=)
        values = { ":val#{idx}" => range_end }
        ["#attr#{idx} <= :val#{idx}", names, values]
      elsif range_end.nil?
        # Endless range: start_value.. (>=)
        values = { ":val#{idx}" => range_begin }
        ["#attr#{idx} >= :val#{idx}", names, values]
      else
        # Full range: start..end (BETWEEN)
        values = {
          ":val#{idx}_start" => range_begin,
          ":val#{idx}_end" => range_end
        }
        ["#attr#{idx} BETWEEN :val#{idx}_start AND :val#{idx}_end", names, values]
      end
    end

    # Normalize range values to DynamoDB-compatible strings
    # Handles Date, Time, DateTime, ActiveSupport::TimeWithZone
    def normalize_range_value(value)
      return nil if value.nil?

      case value
      when Date
        value.to_s # YYYY-MM-DD format
      when Time, DateTime
        value.utc.iso8601
      else
        # ActiveSupport::TimeWithZone or already a string
        value.respond_to?(:to_date) ? value.to_date.to_s : value.to_s
      end
    end

    # Build sort key condition for Range values in GSI queries
    # Returns the key condition expression part and values for sort key
    def build_sort_key_range_condition(sort_key, range, placeholder_prefix = 'sk')
      range_begin = normalize_range_value(range.begin)
      range_end = normalize_range_value(range.end)

      if range_begin.nil?
        # Beginless range: ..end_value (<=)
        {
          expression: "##{placeholder_prefix} <= :#{placeholder_prefix}_val",
          names: { "##{placeholder_prefix}" => sort_key },
          values: { ":#{placeholder_prefix}_val" => range_end }
        }
      elsif range_end.nil?
        # Endless range: start_value.. (>=)
        {
          expression: "##{placeholder_prefix} >= :#{placeholder_prefix}_val",
          names: { "##{placeholder_prefix}" => sort_key },
          values: { ":#{placeholder_prefix}_val" => range_begin }
        }
      else
        # Full range: BETWEEN
        {
          expression: "##{placeholder_prefix} BETWEEN :#{placeholder_prefix}_start AND :#{placeholder_prefix}_end",
          names: { "##{placeholder_prefix}" => sort_key },
          values: {
            ":#{placeholder_prefix}_start" => range_begin,
            ":#{placeholder_prefix}_end" => range_end
          }
        }
      end
    end

  end
end
