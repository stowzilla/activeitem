# encoding: utf-8

require_relative 'model_loader'
require_relative 'pagination'

module DynamoRecord
  # Chainable query builder that accumulates conditions and executes lazily
  # Mimics ActiveRecord::Relation behavior
  class Relation
    include Enumerable
    include ModelLoader

    attr_reader :model, :conditions, :index_name, :limit_value, :not_conditions, :ilike, :ilike_exact, :class_name, :owner, :includes_associations, :order_direction, :select_attributes

    def initialize(model, conditions: {}, index_name: nil, limit_value: nil, not_conditions: {}, ilike: false, ilike_exact: false, class_name: nil, owner: nil, preloaded_records: nil, includes_associations: [], order_direction: nil, select_attributes: nil)
      @model = model
      @class_name = class_name  # For lazy loading
      @owner = owner            # The object that owns this association
      @conditions = conditions.dup
      @index_name = index_name
      @limit_value = limit_value
      @not_conditions = not_conditions.dup
      @ilike = ilike           # Use case-insensitive contains() for string conditions
      @ilike_exact = ilike_exact  # Require exact case-insensitive match (Ruby-side filter)
      @loaded = preloaded_records ? true : false
      @records = preloaded_records
      @includes_associations = includes_associations
      @order_direction = order_direction  # :asc or :desc for DynamoDB ScanIndexForward
      @select_attributes = select_attributes  # Projection expression attributes
    end

    # Chainable includes - preload associations to avoid N+1 queries
    #
    # Supports three forms:
    #   Symbol        – full preload (belongs_to uses BatchGetItem, has_many loads records)
    #   Hash :count   – preload only the count (has_many only, uses SELECT COUNT on GSI)
    #   Hash :records – same as symbol form, explicit full preload
    #
    # @example Preload belongs_to and has_many counts
    #   Container.includes(:customer, child_containers: :count, items: :count).all
    #
    # @example Preload belongs_to only
    #   InventoryItem.includes(:customer, :container).where(...)
    #
    def includes(*associations)
      # Normalize into a flat list: symbols stay as-is, hashes get merged
      new_includes = includes_associations.dup
      associations.each do |assoc|
        case assoc
        when Symbol
          new_includes << assoc unless new_includes.include?(assoc)
        when Hash
          new_includes << assoc
        else
          new_includes << assoc
        end
      end

      spawn(includes_associations: new_includes)
    end

    # Chainable where - returns a new Relation with merged conditions
    # When called without arguments, returns a WhereChain for .not() syntax
    def where(**new_conditions)
      # If no conditions, return WhereChain for .not() chaining
      return WhereChain.new(self) if new_conditions.empty?

      # Extract special options
      new_index = new_conditions.delete(:index) || new_conditions.delete(:index_name)
      new_ilike = new_conditions.delete(:ilike)
      new_exact = new_conditions.delete(:exact)

      spawn(
        conditions: conditions.merge(new_conditions),
        index_name: new_index || index_name,
        ilike: new_ilike.nil? ? ilike : new_ilike,
        ilike_exact: new_exact.nil? ? ilike_exact : new_exact
      )
    end

    # Chainable not - returns a WhereChain for negation or a new Relation with negated conditions
    # Usage:
    #   Model.where.not(status: 'deleted')           # Via WhereChain
    #   Model.where(active: true).not(archived: true) # Direct on Relation
    #
    # Supports:
    #   - nil values: where.not(parent_id: nil) -> attribute_exists(parent_id)
    #   - equality: where.not(status: 'deleted') -> status <> 'deleted'
    #   - arrays: where.not(status: ['a', 'b']) -> status NOT IN ('a', 'b')
    #
    def not(**negated_conditions)
      spawn(not_conditions: not_conditions.merge(negated_conditions))
    end

    # Chainable limit
    def limit(value)
      spawn(limit_value: value)
    end

    # Chainable order - sets DynamoDB ScanIndexForward for sort key ordering
    # Only effective when querying a GSI with a sort key.
    #
    # @param direction [Symbol] :asc (default, oldest first) or :desc (newest first)
    # @return [Relation]
    #
    # @example Newest first
    #   BillingEvent.where(customer_id: id).order(:desc)
    #
    # @example Oldest first (default DynamoDB behavior)
    #   ItemChange.where(item_id: id).order(:asc)
    #
    def order(direction = :asc)
      dir = direction.to_sym
      raise ArgumentError, "order must be :asc or :desc, got #{direction.inspect}" unless %i[asc desc].include?(dir)

      spawn(order_direction: dir)
    end

    # Chainable select - adds DynamoDB projection expression to only return specified attributes.
    # Reduces RCU consumption and data transfer for queries that only need a few fields.
    #
    # When called with a block, delegates to Enumerable#select (Rails behavior).
    # The primary key is always included automatically.
    #
    # @param attrs [Array<Symbol>] Attribute names to project
    # @return [Relation]
    #
    # @example Column selection (DynamoDB projection)
    #   InventoryItem.where(customer_id: id).select(:id, :name)
    #
    # @example Enumerable filtering (block)
    #   InventoryItem.where(customer_id: id).select { |i| i.active? }
    #
    def select(*attrs, &block)
      if block_given?
        super(&block)
      else
        spawn(select_attributes: attrs.map(&:to_sym))
      end
    end

    # Cursor-based pagination for DynamoDB
    #
    # @param cursor [String, nil] Base64-encoded LastEvaluatedKey from previous page, or nil for first page
    # @param per_page [Integer] Number of items per page (default: 25, max: 100)
    # @return [Pagination::PaginatedResult] Result with items and pagination metadata
    #
    # @example First page
    #   result = Model.where(status: 'active').page(nil, per_page: 25)
    #   result.items          # => [Model, Model, ...]
    #   result.has_more?      # => true
    #   result.next_cursor    # => "eyJpZCI6IjEyMyJ9"
    #
    # @example Next page
    #   result = Model.where(status: 'active').page(params[:cursor], per_page: 25)
    #
    def page(cursor = nil, per_page: Pagination::DEFAULT_PER_PAGE)
      per_page = [[per_page.to_i, 1].max, Pagination::MAX_PER_PAGE].min

      items, next_cursor = execute_paginated_query(cursor, per_page)
      if includes_associations.any?
        begin
          @_paginated = true
          preload_associations_for_records(items)
        ensure
          @_paginated = false
        end
      end

      Pagination::PaginatedResult.new(items: items, next_cursor: next_cursor, per_page: per_page)
    end

    def none
      Relation.new(resolved_model, conditions: { _empty: true }, includes_associations: includes_associations)
    end

    # Returns self, mirroring ActiveRecord::Relation#all behavior.
    # Allows chaining like: Model.includes(:assoc).all.limit(100)
    def all
      self
    end

    # Execute query and iterate over results
    def each(&block)
      load_records
      @records.each(&block)
    end

    # Get first record
    def first
      limit(1).to_a.first
    end

    # Get last record (loads all, not efficient for large sets)
    def last
      to_a.last
    end

    # Count records
    # When called with a block, delegates to Enumerable#count (Ruby-side filtering)
    # When called without a block, returns the count of loaded records
    #
    # @example Without block
    #   Pickup.where(status: 'pending').count  # => 5
    #
    # @example With block (Rails-like)
    #   Pickup.all.count { |p| p.time_slot == "10-12" }  # => 3
    #
    def count(&block)
      if block_given? || ilike || ilike_exact
        load_records
        return block_given? ? @records.count(&block) : @records.length
      end

      return @records.length if @loaded

      execute_count_query
    end

    # Length/size always return the total count (no block support)
    def length
      load_records
      @records.length
    end
    alias_method :size, :length

    # Check if any records exist
    def any?
      !empty?
    end

    # Check if no records exist
    def empty?
      count == 0
    end

    # Check if records exist matching optional conditions
    def exists?(**additional_conditions)
      if additional_conditions.any?
        where(**additional_conditions).limit(1).any?
      else
        limit(1).any?
      end
    end

    # Convert to array (triggers query execution)
    def to_a
      load_records
      @records
    end
    alias_method :to_ary, :to_a

    # Re-fetch full records from the main table via batch_find, or return
    # already-loaded records if the initial query returned full items.
    #
    # Detects whether the query results contain only key attributes (KEYS_ONLY GSI)
    # or full items, and skips the re-fetch when unnecessary.
    #
    # @example
    #   container.items.load          # full InventoryItem records
    #   container.items.load.count    # works like a normal array
    #
    # @return [Array<DynamoRecord::Base>] Fully-hydrated model instances
    def load
      records = to_a
      return [] if records.empty?

      # Check if records already have full attributes (not just keys)
      # A KEYS_ONLY GSI record will only have the primary key + sort key attributes
      sample = records.first
      attr_count = sample.class.attribute_names.count { |a| sample.instance_variable_get("@#{a}") != nil }

      # If the record has more than just the key attributes, it's already fully hydrated
      return records if attr_count > 2

      resolved_model.batch_find(records.map(&:id))
    end

    # Pluck specific attributes
    def pluck(*attrs)
      to_a.map do |record|
        if attrs.length == 1
          record.send(attrs.first)
        else
          attrs.map { |attr| record.send(attr) }
        end
      end
    end

    # Find by id within the current scope, or find by block (like Enumerable#find)
    #
    # @overload find(id)
    #   Find a record by ID within the current scope
    #   @param id [String] The ID to find
    #   @return [Object, nil] The found record or nil
    #
    # @overload find(&block)
    #   Find the first record matching the block condition (like Enumerable#find/detect)
    #   @yield [record] Evaluates the block for each record
    #   @return [Object, nil] The first record where block returns true, or nil
    #
    # @example Find by ID
    #   User.where(status: 'active').find('user-123')
    #
    # @example Find by block
    #   User.where(status: 'active').find { |u| u.email.include?('@example.com') }
    #
    def find(id = nil, &block)
      if block_given?
        # Delegate to Enumerable#find when block is given (Rails behavior)
        to_a.find(&block)
      elsif id
        # Use direct GetItem instead of scanning — O(1) vs O(n)
        record = resolved_model.find(id)
        preload_associations_for_records([record]) if includes_associations.any?
        record
      else
        raise ArgumentError, 'find requires either an ID or a block'
      end
    rescue DynamoRecord::RecordNotFound
      nil
    end

    # Find by conditions within current scope
    # Always loads records first, then filters in memory
    # This ensures we search through all records in the current scope
    def find_by(**additional_conditions)
      load_records unless @loaded

      # Filter loaded records in memory
      @records.find do |record|
        additional_conditions.all? do |key, value|
          record.send(key) == value
        end
      end
    end

    # Destroy all matching records
    def destroy_all
      to_a.each(&:destroy)
    end

    # Delete all matching records (no callbacks)
    def delete_all
      to_a.each(&:delete)
    end

    # Reload the relation (clear cached records)
    def reload
      @loaded = false
      @records = nil
      self
    end

    # Add a record to this association
    # Sets the foreign key and saves the record
    # Usage: container.items << item
    # @param record [DynamoRecord::Base] Record to add to the association
    # @return [DynamoRecord::Base] The added record
    def <<(record)
      # Get the foreign key from conditions (first condition is the foreign key)
      foreign_key, foreign_value = conditions.first

      # Set the foreign key on the record
      record.send("#{foreign_key}=", foreign_value)

      # Save the record
      record.save!

      # Clear cached records so next access will reload
      reload

      # Return the record for chaining
      record
    end

    # Returns the DynamoDB operation that would be executed, without running it.
    # Analogous to ActiveRecord's .to_sql — shows the operation type, table, index,
    # key conditions, filters, and limits in DynamoDB terms.
    #
    # @return [Hash] Operation details (:operation, :table, :params)
    #
    # @example
    #   ActionLog.where(actor_id: 'user-1').explain
    #   # => { operation: :query, table: "myapp-dev-action-logs", index: "ActorIndex", params: { ... } }
    #
    #   ActionLog.where(status: 'active').not(archived: true).limit(10).explain
    #   # => { operation: :scan, table: "myapp-dev-action-logs", params: { ... } }
    #
    def explain
      return { operation: :none, reason: 'empty relation' } if conditions[:_empty]

      normalized_conditions = normalize_conditions(conditions)
      effective_index = if normalized_conditions.any?
        index_name || resolved_model.send(:detect_index_for_conditions, normalized_conditions)
      end

      if normalized_conditions.empty? && not_conditions.empty?
        params = { table_name: resolved_model.table_name }
        params[:limit] = limit_value if limit_value
        return { operation: :scan, table: resolved_model.table_name, params: params }
      end

      if effective_index && normalized_conditions.any?
        params = build_explain_query_params(effective_index, normalized_conditions)
        { operation: :query, table: resolved_model.table_name, index: effective_index, params: params }
      else
        params = build_explain_scan_params(normalized_conditions)
        { operation: :scan, table: resolved_model.table_name, params: params }
      end
    end

    # For debugging
    def inspect
      if @loaded
        "#<#{self.class.name} [#{@records.map(&:inspect).join(', ')}]>"
      else
        parts = []
        parts << "conditions=#{conditions.inspect}" if conditions.any?
        parts << "not_conditions=#{not_conditions.inspect}" if not_conditions.any?
        parts << "ilike=true" if ilike
        parts << "exact=true" if ilike_exact
        "#<#{self.class.name} (not loaded) #{parts.join(' ')}>"
      end
    end

    # Forward named scope calls to the model's scope registry
    def method_missing(method_name, *args, &block)
      if resolved_model.respond_to?(:_scopes) && resolved_model._scopes.key?(method_name)
        instance_exec(&resolved_model._scopes[method_name])
      else
        super
      end
    end

    def respond_to_missing?(method_name, include_private = false)
      (resolved_model.respond_to?(:_scopes) && resolved_model._scopes.key?(method_name)) || super
    end

    private

    # Spawn a new Relation with overridden attributes, preserving all others.
    # Eliminates repetitive Relation.new(...) calls across chain methods.
    def spawn(**overrides)
      Relation.new(
        overrides.fetch(:model, model),
        conditions: overrides.fetch(:conditions, conditions),
        index_name: overrides.fetch(:index_name, index_name),
        limit_value: overrides.fetch(:limit_value, limit_value),
        not_conditions: overrides.fetch(:not_conditions, not_conditions),
        ilike: overrides.fetch(:ilike, ilike),
        ilike_exact: overrides.fetch(:ilike_exact, ilike_exact),
        class_name: overrides.fetch(:class_name, class_name),
        owner: overrides.fetch(:owner, owner),
        includes_associations: overrides.fetch(:includes_associations, includes_associations),
        order_direction: overrides.fetch(:order_direction, order_direction),
        select_attributes: overrides.fetch(:select_attributes, select_attributes)
      )
    end

    # Resolve the model class lazily
    # This defers loading until query execution to avoid circular dependencies
    def resolved_model
      return @model if @model
      return Object unless @class_name

      # Lazy load the class when first needed
      @model ||= safe_constantize_model(@class_name)
    end

    # Apply Ruby-side filter for case-insensitive matching
    # Called after DynamoDB query returns results when ilike is true
    def apply_ilike_filter(records)
      return records unless ilike

      # Get the string conditions that need case-insensitive matching
      string_conditions = conditions.select { |_, v| v.is_a?(String) }
      return records if string_conditions.empty?

      records.select do |record|
        string_conditions.all? do |attr, expected_value|
          actual_value = record.send(attr)&.to_s&.downcase
          expected_downcase = expected_value.to_s.downcase

          if ilike_exact
            # Exact case-insensitive match
            actual_value == expected_downcase
          else
            # Case-insensitive substring match
            actual_value&.include?(expected_downcase)
          end
        end
      end
    end

    def load_records
      return if @loaded

      @records = execute_query
      preload_associations_for_records(@records) if includes_associations.any?
      @loaded = true
    end

    # Execute a paginated query with cursor support
    # @param cursor [String, nil] Base64-encoded LastEvaluatedKey
    # @param per_page [Integer] Number of items to fetch
    # @return [Array<Array<Model>, String>] [items, next_cursor]
    def execute_paginated_query(cursor, per_page)
      return [[], nil] if conditions[:_empty]

      normalized_conditions = normalize_conditions(conditions)
      exclusive_start_key = decode_cursor(cursor)

      effective_index = index_name || resolved_model.send(:detect_index_for_conditions, normalized_conditions)

      if effective_index && normalized_conditions.any?
        paginated_query_with_index(effective_index, normalized_conditions, exclusive_start_key, per_page)
      else
        paginated_scan_with_conditions(normalized_conditions, exclusive_start_key, per_page)
      end
    rescue Aws::DynamoDB::Errors::AccessDeniedException => e
      raise DynamoRecord::AccessDeniedError.new(model_name: resolved_model.name, table: resolved_model.table_name,
                                                operation: 'PaginatedQuery', original_error: e)
    end

    # Decode Base64 cursor to DynamoDB LastEvaluatedKey
    def decode_cursor(cursor)
      return nil if cursor.nil? || cursor.empty?

      require 'base64'
      require 'json'
      JSON.parse(Base64.urlsafe_decode64(cursor))
    rescue ArgumentError, JSON::ParserError => e
      DynamoRecord.logger.warn("Invalid pagination cursor: #{e.message}")
      nil
    end

    # Encode DynamoDB LastEvaluatedKey to Base64 cursor
    def encode_cursor(last_evaluated_key)
      return nil if last_evaluated_key.nil?

      require 'base64'
      require 'json'
      Base64.urlsafe_encode64(last_evaluated_key.to_json, padding: false)
    end

    # Execute paginated query using GSI
    def paginated_query_with_index(idx_name, normalized_conditions, exclusive_start_key, per_page)
      ruby_partition_key = normalized_conditions.keys.first.to_s
      partition_value = normalized_conditions.values.first

      index_config = resolved_model.indexes[idx_name] || {}
      dynamo_partition_key = index_config[:partition_key]&.to_s || resolved_model.to_dynamo_key(ruby_partition_key)

      params = {
        table_name: resolved_model.table_name,
        index_name: idx_name,
        key_condition_expression: "#pk = :pk_val",
        expression_attribute_names: { '#pk' => dynamo_partition_key },
        expression_attribute_values: { ':pk_val' => partition_value },
        limit: per_page
      }

      params[:exclusive_start_key] = exclusive_start_key if exclusive_start_key
      params[:scan_index_forward] = (order_direction != :desc) unless order_direction.nil?

      # Add sort key and filter conditions (same logic as non-paginated)
      sort_key = index_config[:sort_key]&.to_s
      remaining_conditions = conditions.to_a[1..]

      if sort_key && remaining_conditions.any?
        sort_condition = remaining_conditions.find { |k, _|
          resolved_model.to_dynamo_key(k.to_s) == sort_key || k.to_s == sort_key
        }
        if sort_condition
          _, sort_value = sort_condition
          remaining_conditions = remaining_conditions.reject { |k, _|
            resolved_model.to_dynamo_key(k.to_s) == sort_key || k.to_s == sort_key
          }

          if sort_value.is_a?(Range)
            range_condition = resolved_model.send(:build_sort_key_range_condition, sort_key, sort_value)
            params[:key_condition_expression] += " AND #{range_condition[:expression]}"
            params[:expression_attribute_names].merge!(range_condition[:names])
            params[:expression_attribute_values].merge!(range_condition[:values])
          else
            params[:key_condition_expression] += " AND #sk = :sk_val"
            params[:expression_attribute_names]['#sk'] = sort_key
            params[:expression_attribute_values][':sk_val'] = sort_value
          end
        end
      end

      # Add filter expression for remaining conditions
      filter_parts = []

      if remaining_conditions.any?
        remaining_conditions.each_with_index do |(attr, val), idx|
          expr, names, values = resolved_model.send(:build_condition_expression, attr, val, idx, ilike: ilike)
          filter_parts << expr
          params[:expression_attribute_names].merge!(names)
          params[:expression_attribute_values].merge!(values) if values.any?
        end
      end

      if not_conditions.any?
        not_conditions.each_with_index do |(attr, val), idx|
          expr, names, values = build_not_condition_expression(attr, val, "not#{idx}")
          filter_parts << expr
          params[:expression_attribute_names].merge!(names)
          params[:expression_attribute_values].merge!(values) if values.any?
        end
      end

      params[:filter_expression] = filter_parts.join(' AND ') if filter_parts.any?

      # Fetch items until we have enough that pass the filter
      collected_items = []
      current_cursor = exclusive_start_key
      last_evaluated_key = nil

      loop do
        params[:exclusive_start_key] = current_cursor if current_cursor
        # Fetch more than needed to reduce round trips when filter removes items
        params[:limit] = [per_page * 2, 100].min

        response = resolved_model.dynamodb.query(params)
        items = response.items.map { |item| resolved_model.instantiate(item) }
        items = apply_ilike_filter(items)

        collected_items.concat(items)
        last_evaluated_key = response.last_evaluated_key
        current_cursor = last_evaluated_key

        # Stop if we have enough items or no more pages
        break if collected_items.length >= per_page || last_evaluated_key.nil?
      end

      # Trim to requested page size and determine next cursor
      if collected_items.length > per_page
        [collected_items.take(per_page), encode_cursor(last_evaluated_key || current_cursor)]
      else
        [collected_items, encode_cursor(last_evaluated_key)]
      end
    end

    # Execute paginated scan
    # Keeps fetching until we have per_page items that pass the filter
    def paginated_scan_with_conditions(normalized_conditions, exclusive_start_key, per_page)
      filter_parts = []
      filter_values = {}
      filter_names = {}

      normalized_conditions.each_with_index do |(attr, val), idx|
        expr, names, values = resolved_model.send(:build_condition_expression, attr, val, idx, ilike: ilike)
        filter_parts << expr
        filter_names.merge!(names)
        filter_values.merge!(values) if values.any?
      end

      not_conditions.each_with_index do |(attr, val), idx|
        expr, names, values = build_not_condition_expression(attr, val, "not#{idx}")
        filter_parts << expr
        filter_names.merge!(names)
        filter_values.merge!(values) if values.any?
      end

      params = { table_name: resolved_model.table_name }
      params[:filter_expression] = filter_parts.join(' AND ') if filter_parts.any?
      params[:expression_attribute_names] = filter_names if filter_names.any?
      params[:expression_attribute_values] = filter_values if filter_values.any?

      # Fetch items until we have enough that pass the filter
      collected_items = []
      current_cursor = exclusive_start_key
      last_evaluated_key = nil

      loop do
        params[:exclusive_start_key] = current_cursor if current_cursor
        # Fetch more than needed to reduce round trips when filter removes items
        params[:limit] = [per_page * 2, 100].min

        response = resolved_model.dynamodb.scan(params)
        items = response.items.map { |item| resolved_model.instantiate(item) }
        items = apply_ilike_filter(items)

        collected_items.concat(items)
        last_evaluated_key = response.last_evaluated_key
        current_cursor = last_evaluated_key

        # Stop if we have enough items or no more pages
        break if collected_items.length >= per_page || last_evaluated_key.nil?
      end

      # Trim to requested page size and determine next cursor
      if collected_items.length > per_page
        # We have more items than needed — cursor must point to the last returned item's key
        # so the next page starts right after it (not after the last scanned item)
        last_returned = collected_items[per_page - 1]
        next_key = { resolved_model.primary_key.to_s => last_returned.id }
        [collected_items.take(per_page), encode_cursor(next_key)]
      else
        [collected_items, encode_cursor(last_evaluated_key)]
      end
    end

    def execute_query
      # Handle empty marker (from associations with nil key)
      return [] if conditions[:_empty]

      # Normalize conditions to resolve attribute aliases
      normalized_conditions = normalize_conditions(conditions)

      records = if normalized_conditions.empty? && not_conditions.empty?
        # Direct scan - don't call model.all to avoid recursion
        items = resolved_model.scan(limit: limit_value)
        items.map { |item| resolved_model.instantiate(item) }
      else
        # Determine index to use (use normalized conditions)
        effective_index = index_name || resolved_model.send(:detect_index_for_conditions, normalized_conditions)

        if effective_index && normalized_conditions.any?
          query_with_index_normalized(effective_index, normalized_conditions)
        else
          scan_with_conditions_normalized(normalized_conditions)
        end
      end

      # Apply Ruby-side filter for case-insensitive matching
      apply_ilike_filter(records)
    rescue Aws::DynamoDB::Errors::AccessDeniedException => e
      raise DynamoRecord::AccessDeniedError.new(model_name: resolved_model.name, table: resolved_model.table_name,
                                                operation: 'Query/Scan', original_error: e)
    end

    # Execute a count-only query using DynamoDB SELECT: 'COUNT'
    # Avoids materializing records — returns just the count integer.
    def execute_count_query
      return 0 if conditions[:_empty]

      normalized_conditions = normalize_conditions(conditions)

      effective_index = if normalized_conditions.any?
        index_name || resolved_model.send(:detect_index_for_conditions, normalized_conditions)
      end

      total = 0
      exclusive_start_key = nil

      loop do
        params = if effective_index && normalized_conditions.any?
          build_count_query_params(effective_index, normalized_conditions)
        else
          build_count_scan_params(normalized_conditions)
        end
        params[:exclusive_start_key] = exclusive_start_key if exclusive_start_key

        response = if effective_index && normalized_conditions.any?
          resolved_model.dynamodb.query(params)
        else
          resolved_model.dynamodb.scan(params)
        end

        total += response.count
        exclusive_start_key = response.last_evaluated_key
        break unless exclusive_start_key
      end

      total
    rescue Aws::DynamoDB::Errors::AccessDeniedException => e
      raise DynamoRecord::AccessDeniedError.new(model_name: resolved_model.name, table: resolved_model.table_name,
                                                operation: 'Count', original_error: e)
    end
    def build_count_query_params(idx_name, normalized_conditions)
      ruby_partition_key = normalized_conditions.keys.first.to_s
      partition_value = normalized_conditions.values.first

      index_config = resolved_model.indexes[idx_name] || {}
      dynamo_partition_key = index_config[:partition_key]&.to_s || resolved_model.to_dynamo_key(ruby_partition_key)

      params = {
        table_name: resolved_model.table_name,
        index_name: idx_name,
        select: 'COUNT',
        key_condition_expression: '#pk = :pk_val',
        expression_attribute_names: { '#pk' => dynamo_partition_key },
        expression_attribute_values: { ':pk_val' => partition_value }
      }

      # Sort key condition
      sort_key = index_config[:sort_key]&.to_s
      remaining_conditions = conditions.to_a[1..]

      if sort_key && remaining_conditions.any?
        sort_condition = remaining_conditions.find { |k, _|
          resolved_model.to_dynamo_key(k.to_s) == sort_key || k.to_s == sort_key
        }
        if sort_condition
          _, sort_value = sort_condition
          remaining_conditions = remaining_conditions.reject { |k, _|
            resolved_model.to_dynamo_key(k.to_s) == sort_key || k.to_s == sort_key
          }

          if sort_value.is_a?(Range)
            range_condition = resolved_model.send(:build_sort_key_range_condition, sort_key, sort_value)
            params[:key_condition_expression] += " AND #{range_condition[:expression]}"
            params[:expression_attribute_names].merge!(range_condition[:names])
            params[:expression_attribute_values].merge!(range_condition[:values])
          else
            params[:key_condition_expression] += " AND #sk = :sk_val"
            params[:expression_attribute_names]['#sk'] = sort_key
            params[:expression_attribute_values][':sk_val'] = sort_value
          end
        end
      end

      # Filter expressions (remaining conditions + not_conditions)
      filter_parts = []

      if remaining_conditions.any?
        remaining_conditions.each_with_index do |(attr, val), idx|
          expr, names, values = resolved_model.send(:build_condition_expression, attr, val, idx, ilike: false)
          filter_parts << expr
          params[:expression_attribute_names].merge!(names)
          params[:expression_attribute_values].merge!(values) if values.any?
        end
      end

      if not_conditions.any?
        not_conditions.each_with_index do |(attr, val), idx|
          expr, names, values = build_not_condition_expression(attr, val, "not#{idx}")
          filter_parts << expr
          params[:expression_attribute_names].merge!(names)
          params[:expression_attribute_values].merge!(values) if values.any?
        end
      end

      params[:filter_expression] = filter_parts.join(' AND ') if filter_parts.any?
      params
    end

    # Build scan params for a count-only scan
    def build_count_scan_params(normalized_conditions)
      filter_parts = []
      filter_names = {}
      filter_values = {}

      normalized_conditions.each_with_index do |(attr, val), idx|
        expr, names, values = resolved_model.send(:build_condition_expression, attr, val, idx, ilike: false)
        filter_parts << expr
        filter_names.merge!(names)
        filter_values.merge!(values) if values.any?
      end

      not_conditions.each_with_index do |(attr, val), idx|
        expr, names, values = build_not_condition_expression(attr, val, "not#{idx}")
        filter_parts << expr
        filter_names.merge!(names)
        filter_values.merge!(values) if values.any?
      end

      params = { table_name: resolved_model.table_name, select: 'COUNT' }
      params[:filter_expression] = filter_parts.join(' AND ') if filter_parts.any?
      params[:expression_attribute_names] = filter_names if filter_names.any?
      params[:expression_attribute_values] = filter_values if filter_values.any?
      params
    end

    # Build query params for explain (same logic as query_with_index_normalized but no execution)
    def build_explain_query_params(idx_name, normalized_conditions)
      ruby_partition_key = normalized_conditions.keys.first.to_s
      partition_value = normalized_conditions.values.first

      index_config = resolved_model.indexes[idx_name] || {}
      dynamo_partition_key = index_config[:partition_key]&.to_s || resolved_model.to_dynamo_key(ruby_partition_key)

      params = {
        table_name: resolved_model.table_name,
        index_name: idx_name,
        key_condition_expression: "#pk = :pk_val",
        expression_attribute_names: { '#pk' => dynamo_partition_key },
        expression_attribute_values: { ':pk_val' => partition_value }
      }

      sort_key = index_config[:sort_key]&.to_s
      remaining_conditions = conditions.to_a[1..]

      if sort_key && remaining_conditions.any?
        sort_condition = remaining_conditions.find { |k, _|
          resolved_model.to_dynamo_key(k.to_s) == sort_key || k.to_s == sort_key
        }
        if sort_condition
          _, sort_value = sort_condition
          remaining_conditions = remaining_conditions.reject { |k, _|
            resolved_model.to_dynamo_key(k.to_s) == sort_key || k.to_s == sort_key
          }

          if sort_value.is_a?(Range)
            range_condition = resolved_model.send(:build_sort_key_range_condition, sort_key, sort_value)
            params[:key_condition_expression] += " AND #{range_condition[:expression]}"
            params[:expression_attribute_names].merge!(range_condition[:names])
            params[:expression_attribute_values].merge!(range_condition[:values])
          else
            params[:key_condition_expression] += " AND #sk = :sk_val"
            params[:expression_attribute_names]['#sk'] = sort_key
            params[:expression_attribute_values][':sk_val'] = sort_value
          end
        end
      end

      filter_parts = []

      if remaining_conditions.any?
        remaining_conditions.each_with_index do |(attr, val), idx|
          expr, names, values = resolved_model.send(:build_condition_expression, attr, val, idx, ilike: ilike)
          filter_parts << expr
          params[:expression_attribute_names].merge!(names)
          params[:expression_attribute_values].merge!(values) if values.any?
        end
      end

      if not_conditions.any?
        not_conditions.each_with_index do |(attr, val), idx|
          expr, names, values = build_not_condition_expression(attr, val, "not#{idx}")
          filter_parts << expr
          params[:expression_attribute_names].merge!(names)
          params[:expression_attribute_values].merge!(values) if values.any?
        end
      end

      params[:filter_expression] = filter_parts.join(' AND ') if filter_parts.any?
      params[:limit] = limit_value if limit_value
      params[:scan_index_forward] = (order_direction != :desc) unless order_direction.nil?
      apply_projection_expression!(params)
      params
    end

    # Build scan params for explain (same logic as scan_with_conditions_normalized but no execution)
    def build_explain_scan_params(normalized_conditions)
      filter_parts = []
      filter_names = {}
      filter_values = {}

      normalized_conditions.each_with_index do |(attr, val), idx|
        expr, names, values = resolved_model.send(:build_condition_expression, attr, val, idx, ilike: ilike)
        filter_parts << expr
        filter_names.merge!(names)
        filter_values.merge!(values) if values.any?
      end

      not_conditions.each_with_index do |(attr, val), idx|
        expr, names, values = build_not_condition_expression(attr, val, "not#{idx}")
        filter_parts << expr
        filter_names.merge!(names)
        filter_values.merge!(values) if values.any?
      end

      proj_expr, proj_names = build_projection_expression
      filter_names.merge!(proj_names) if proj_names

      params = { table_name: resolved_model.table_name }
      params[:filter_expression] = filter_parts.join(' AND ') if filter_parts.any?
      params[:expression_attribute_names] = filter_names if filter_names.any?
      params[:expression_attribute_values] = filter_values if filter_values.any?
      params[:projection_expression] = proj_expr if proj_expr
      params[:limit] = limit_value if limit_value
      params
    end

    # Normalize conditions to resolve attribute aliases based on association metadata
    # When a belongs_to association has a custom foreign_key, queries using the
    # association name + _id should be converted to the actual foreign_key
    # e.g., belongs_to :customer, foreign_key: :user_id
    #       where(customer_id: ...) -> where(user_id: ...)
    def normalize_conditions(conds)
      normalized = {}

      conds.each do |key, value|
        key_str = key.to_s

        # Check if this key matches an association name pattern (association_name + _id)
        # and if that association has a different foreign_key
        resolved_key = resolve_association_foreign_key(key_str) || key_str

        normalized[resolved_key.to_sym] = value
      end

      normalized
    end

    # Resolve association-based attribute names to their actual foreign keys
    # e.g., customer_id -> user_id if belongs_to :customer, foreign_key: :user_id
    def resolve_association_foreign_key(attr_name)
      return nil unless attr_name.end_with?('_id')

      # Extract the association name (remove _id suffix)
      association_name = attr_name.chomp('_id').to_sym

      # Check if this association exists
      associations = resolved_model._associations || {}
      association_config = associations[association_name]

      return nil unless association_config
      return nil unless association_config[:type] == :belongs_to

      # Get the foreign key from the association
      foreign_key = association_config[:foreign_key]

      # If the foreign key is different from the attribute name, return it
      foreign_key.to_s != attr_name ? foreign_key.to_s : nil
    end

    def query_with_index_normalized(idx_name, normalized_conditions)
      # Get the partition key from conditions (Ruby snake_case)
      ruby_partition_key = normalized_conditions.keys.first.to_s
      partition_value = normalized_conditions.values.first

      # Get the actual DynamoDB partition key name from the index definition
      # The index definition stores the DynamoDB key name (which may be camelCase)
      index_config = resolved_model.indexes[idx_name] || {}
      dynamo_partition_key = index_config[:partition_key]&.to_s || resolved_model.to_dynamo_key(ruby_partition_key)

      if partition_value.is_a?(Array)
        raise ArgumentError, "Array values not supported for partition key queries. Use scan instead."
      end

      if partition_value.is_a?(Range)
        raise ArgumentError, "Range values not supported for partition key queries. Use scan instead."
      end

      params = {
        table_name: resolved_model.table_name,
        index_name: idx_name,
        key_condition_expression: "#pk = :pk_val",
        expression_attribute_names: { '#pk' => dynamo_partition_key },
        expression_attribute_values: { ':pk_val' => partition_value }
      }

      # Add sort key condition if present and index has a sort key
      sort_key = index_config[:sort_key]&.to_s

      remaining_conditions = conditions.to_a[1..]

      if sort_key && remaining_conditions.any?
        # Find the sort key condition by matching the DynamoDB key name
        sort_condition = remaining_conditions.find { |k, _|
          resolved_model.to_dynamo_key(k.to_s) == sort_key || k.to_s == sort_key
        }
        if sort_condition
          _, sort_value = sort_condition
          remaining_conditions = remaining_conditions.reject { |k, _|
            resolved_model.to_dynamo_key(k.to_s) == sort_key || k.to_s == sort_key
          }

          if sort_value.is_a?(Range)
            range_condition = resolved_model.send(:build_sort_key_range_condition, sort_key, sort_value)
            params[:key_condition_expression] += " AND #{range_condition[:expression]}"
            params[:expression_attribute_names].merge!(range_condition[:names])
            params[:expression_attribute_values].merge!(range_condition[:values])
          else
            params[:key_condition_expression] += " AND #sk = :sk_val"
            params[:expression_attribute_names]['#sk'] = sort_key
            params[:expression_attribute_values][':sk_val'] = sort_value
          end
        end
      end

      # Add remaining conditions as filter expression
      filter_parts = []

      if remaining_conditions.any?
        remaining_conditions.each_with_index do |(attr, val), idx|
          expr, names, values = resolved_model.send(:build_condition_expression, attr, val, idx, ilike: ilike)
          filter_parts << expr
          params[:expression_attribute_names].merge!(names)
          params[:expression_attribute_values].merge!(values) if values.any?
        end
      end

      # Add NOT conditions to filter expression
      if not_conditions.any?
        not_conditions.each_with_index do |(attr, val), idx|
          expr, names, values = build_not_condition_expression(attr, val, "not#{idx}")
          filter_parts << expr
          params[:expression_attribute_names].merge!(names)
          params[:expression_attribute_values].merge!(values) if values.any?
        end
      end

      params[:filter_expression] = filter_parts.join(' AND ') if filter_parts.any?
      params[:limit] = limit_value if limit_value
      params[:scan_index_forward] = (order_direction != :desc) unless order_direction.nil?

      # Add projection expression if select() was used
      apply_projection_expression!(params)

      # Auto-paginate through all DynamoDB pages (1MB limit per page)
      all_items = []
      exclusive_start_key = nil

      loop do
        params[:exclusive_start_key] = exclusive_start_key if exclusive_start_key
        response = resolved_model.dynamodb.query(params)
        all_items.concat(response.items.map { |item| resolved_model.instantiate(item) })
        exclusive_start_key = response.last_evaluated_key
        break unless exclusive_start_key
        break if limit_value && all_items.length >= limit_value
      end

      all_items
    end

    def scan_with_conditions_normalized(normalized_conditions)
      filter_parts = []
      filter_values = {}
      filter_names = {}

      normalized_conditions.each_with_index do |(attr, val), idx|
        expr, names, values = resolved_model.send(:build_condition_expression, attr, val, idx, ilike: ilike)
        filter_parts << expr
        filter_names.merge!(names)
        filter_values.merge!(values) if values.any?
      end

      # Add NOT conditions
      not_conditions.each_with_index do |(attr, val), idx|
        expr, names, values = build_not_condition_expression(attr, val, "not#{idx}")
        filter_parts << expr
        filter_names.merge!(names)
        filter_values.merge!(values) if values.any?
      end

      # Build projection expression if select() was used
      proj_expr, proj_names = build_projection_expression
      filter_names.merge!(proj_names) if proj_names

      items = resolved_model.scan(
        filter_expression: filter_parts.any? ? filter_parts.join(' AND ') : nil,
        expression_attribute_names: filter_names.any? ? filter_names : nil,
        expression_attribute_values: filter_values.any? ? filter_values : nil,
        projection_expression: proj_expr,
        limit: limit_value
      )

      items.map { |item| resolved_model.instantiate(item) }
    end

    # Build a DynamoDB projection expression from select_attributes.
    # Always includes the primary key. Returns [expression_string, names_hash] or [nil, nil].
    def build_projection_expression
      return [nil, nil] unless select_attributes&.any?

      pk = resolved_model.primary_key.to_s
      attrs = select_attributes.map(&:to_s)
      attrs << pk unless attrs.include?(pk) || attrs.include?('id')

      names = {}
      placeholders = attrs.each_with_index.map do |attr, i|
        placeholder = "#proj#{i}"
        names[placeholder] = resolved_model.to_dynamo_key(attr)
        placeholder
      end

      # Always include the raw primary key if it differs from 'id'
      unless names.values.include?(pk)
        placeholder = "#proj_pk"
        names[placeholder] = pk
        placeholders << placeholder
      end

      [placeholders.join(', '), names]
    end

    # Apply projection expression to a params hash (for query operations).
    # Merges projection attribute names into existing expression_attribute_names.
    def apply_projection_expression!(params)
      proj_expr, proj_names = build_projection_expression
      return unless proj_expr

      params[:projection_expression] = proj_expr
      params[:expression_attribute_names] = (params[:expression_attribute_names] || {}).merge(proj_names)
    end

    # Build a NOT condition expression for a single attribute
    # Supports:
    # - nil values: attribute_exists (NOT NULL)
    # - Simple values: <> (not equal)
    # - Array values: NOT IN
    #
    # @param attr [String, Symbol] Attribute name (Ruby snake_case)
    # @param val [Object] Value to negate
    # @param idx [String] Index for unique placeholder names
    # @return [Array<String, Hash, Hash>] [expression, attribute_names, attribute_values]
    def build_not_condition_expression(attr, val, idx)
      attr_str = attr.to_s
      # Convert to DynamoDB camelCase
      dynamo_attr = resolved_model.to_dynamo_key(attr_str)

      # Handle nil - use attribute_exists (opposite of attribute_not_exists)
      if val.nil?
        return ["attribute_exists(#attr#{idx})", { "#attr#{idx}" => dynamo_attr }, {}]
      end

      # Handle array values (NOT IN)
      if val.is_a?(Array)
        placeholders = val.map.with_index { |_, i| ":val#{idx}_#{i}" }
        values = {}
        val.each_with_index { |v, i| values[":val#{idx}_#{i}"] = v }
        return ["NOT (#attr#{idx} IN (#{placeholders.join(', ')}))", { "#attr#{idx}" => dynamo_attr }, values]
      end

      # Simple not equal
      ["#attr#{idx} <> :val#{idx}", { "#attr#{idx}" => dynamo_attr }, { ":val#{idx}" => val }]
    end

    # Preload associations for a collection of records
    # Mimics Rails eager loading to avoid N+1 queries
    #
    # Supports:
    #   - Symbol associations: full preload (belongs_to via BatchGetItem)
    #   - Hash with :count: preload only the count (has_many via SELECT COUNT on GSI)
    #
    # @example
    #   includes(:customer)                          # belongs_to batch preload
    #   includes(child_containers: :count)           # has_many count preload
    #   includes(:customer, items: :count)           # mixed
    def preload_associations_for_records(records)
      return if records.empty? || includes_associations.empty?

      includes_associations.each do |assoc_entry|
        case assoc_entry
        when Symbol
          preload_symbol_association(records, assoc_entry)
        when Hash
          assoc_entry.each do |assoc_name, mode|
            preload_hash_association(records, assoc_name, mode)
          end
        end
      end
    end

    # Preload a symbol-form association (full preload)
    def preload_symbol_association(records, assoc_name)
      assoc_config = resolved_model._associations[assoc_name]
      raise ArgumentError, "Unknown association: #{assoc_name}" unless assoc_config

      case assoc_config[:type]
      when :belongs_to
        preload_belongs_to(records, assoc_name, assoc_config)
      when :has_many
        preload_has_many_records(records, assoc_name, assoc_config)
      end
    end

    # Preload a hash-form association (:count or :records)
    def preload_hash_association(records, assoc_name, mode)
      assoc_config = resolved_model._associations[assoc_name]
      raise ArgumentError, "Unknown association: #{assoc_name}" unless assoc_config

      case mode
      when :count
        raise ArgumentError, "count preloading only supported for has_many (got #{assoc_config[:type]} for #{assoc_name})" unless assoc_config[:type] == :has_many
        preload_has_many_counts(records, assoc_name, assoc_config)
      when :records
        preload_symbol_association(records, assoc_name)
      else
        raise ArgumentError, "Unknown includes mode: #{mode} for #{assoc_name}. Use :count or :records"
      end
    end

    # Preload belongs_to associations using batch_find
    def preload_belongs_to(records, assoc_name, config)
      foreign_key = config[:foreign_key]
      assoc_class = safe_constantize_model(config[:class_name])

      # Collect all foreign key values
      foreign_ids = records.filter_map { |r| r.send(foreign_key) }.uniq
      return if foreign_ids.empty?

      # Batch load associated records
      associated_records = assoc_class.batch_find(foreign_ids).index_by(&:id)

      # Cache associations on each record
      records.each do |record|
        fk_value = record.send(foreign_key)
        record.instance_variable_set(:"@_association_cache_#{assoc_name}", associated_records[fk_value])
      end
    end

    # Preload has_many counts efficiently.
    #
    # Strategy selection:
    # 1. Self-referential + full table loaded → count from loaded records (0 DB calls)
    # 2. GSI index available → parallel SELECT COUNT queries per parent (N fast indexed calls)
    # 3. Fallback → single projected scan of child table grouped in Ruby
    #
    # @param records [Array] Parent records
    # @param assoc_name [Symbol] Association name (e.g., :child_containers)
    # @param config [Hash] Association config from _associations
    def preload_has_many_counts(records, assoc_name, config)
      foreign_key = config[:foreign_key]
      assoc_class = safe_constantize_model(config[:class_name])
      local_key = config[:primary_key] || resolved_model.primary_key
      dynamo_fk = assoc_class.to_dynamo_key(foreign_key)
      index_name = config[:index]

      parent_ids = Set.new
      records.each do |r|
        pk = r.send(local_key)
        parent_ids << pk if pk
      end

      counts_by_parent = if assoc_class == resolved_model && conditions.empty? && not_conditions.empty? && !@_paginated
        # Self-referential with full table loaded — count in memory
        tally = Hash.new(0)
        records.each do |r|
          fk_val = r.send(foreign_key)
          tally[fk_val] += 1 if fk_val && parent_ids.include?(fk_val)
        end
        tally
      elsif index_name
        query_counts_via_index(assoc_class, index_name, dynamo_fk, parent_ids)
      else
        scan_and_count_foreign_keys(assoc_class, dynamo_fk, parent_ids)
      end

      records.each do |record|
        pk_value = record.send(local_key)
        record._preloaded_counts[assoc_name] = counts_by_parent[pk_value] || 0
      end
    end

    # Use GSI SELECT COUNT queries to get counts per parent ID.
    # Each query is a lightweight indexed count — no data transfer, just a number.
    # Uses thread pool for parallel execution when multiple parent IDs exist.
    #
    # @param assoc_class [Class] The associated model class
    # @param index_name [String] GSI index name
    # @param dynamo_fk [String] The DynamoDB attribute name for the foreign key
    # @param parent_ids [Set] Set of parent key values to count for
    # @return [Hash] { parent_id => count }
    def query_counts_via_index(assoc_class, index_name, dynamo_fk, parent_ids)
      return {} if parent_ids.empty?

      client = assoc_class.dynamodb
      table = assoc_class.table_name
      counts = {}
      mutex = Mutex.new

      # Bounded parallel GSI count queries — each is a tiny indexed operation
      # Upper bound on concurrent DynamoDB queries to avoid spawning one thread per parent_id
      max_concurrency = 10

      parent_ids.each_slice(max_concurrency) do |batch|
        threads = batch.map do |pid|
          Thread.new do
            count = 0
            exclusive_start_key = nil
            loop do
              params = {
                table_name: table, index_name: index_name, select: 'COUNT',
                key_condition_expression: '#pk = :pk',
                expression_attribute_names: { '#pk' => dynamo_fk },
                expression_attribute_values: { ':pk' => pid }
              }
              params[:exclusive_start_key] = exclusive_start_key if exclusive_start_key
              response = client.query(params)
              count += response.count
              exclusive_start_key = response.last_evaluated_key
              break unless exclusive_start_key
            end
            mutex.synchronize { counts[pid] = count }
          end
        end
        threads.each(&:join)
      end

      counts
    end

    # Scan a table projecting only the foreign key attribute, then count occurrences
    # for each parent ID. Uses pagination to handle tables larger than 1MB.
    # Fallback when no GSI index is available.
    #
    # @param assoc_class [Class] The associated model class
    # @param dynamo_fk [String] The DynamoDB attribute name for the foreign key
    # @param parent_ids [Set] Set of parent key values to count for
    # @return [Hash] { parent_id => count }
    def scan_and_count_foreign_keys(assoc_class, dynamo_fk, parent_ids)
      client = assoc_class.dynamodb
      counts = Hash.new(0)
      exclusive_start_key = nil

      loop do
        params = {
          table_name: assoc_class.table_name,
          projection_expression: '#fk',
          expression_attribute_names: { '#fk' => dynamo_fk }
        }
        params[:exclusive_start_key] = exclusive_start_key if exclusive_start_key

        response = client.scan(params)
        response.items.each do |item|
          fk_val = item[dynamo_fk]
          counts[fk_val] += 1 if fk_val && parent_ids.include?(fk_val)
        end

        exclusive_start_key = response.last_evaluated_key
        break unless exclusive_start_key
      end

      counts
    end

    # Preload has_many records (full preload, not just counts)
    # Loads all associated records in batch and caches them on each parent.
    #
    # @param records [Array] Parent records
    # @param assoc_name [Symbol] Association name
    # @param config [Hash] Association config from _associations
    def preload_has_many_records(records, assoc_name, config)
      foreign_key = config[:foreign_key]
      index_name = config[:index]
      assoc_class = safe_constantize_model(config[:class_name])
      local_key = config[:primary_key] || resolved_model.primary_key

      dynamo_key = assoc_class.to_dynamo_key(foreign_key)
      client = assoc_class.dynamodb

      # Load all associated records grouped by foreign key — parallel execution
      records_by_parent = Hash.new { |h, k| h[k] = [] }
      mutex = Mutex.new
      max_concurrency = 10

      parent_ids = records.filter_map { |r| r.send(local_key) }.uniq

      parent_ids.each_slice(max_concurrency) do |batch|
        threads = batch.map do |pk_value|
          Thread.new do
            items = if index_name
              all_items = []
              exclusive_start_key = nil
              loop do
                params = {
                  table_name: assoc_class.table_name, index_name: index_name,
                  key_condition_expression: '#pk = :pk',
                  expression_attribute_names: { '#pk' => dynamo_key },
                  expression_attribute_values: { ':pk' => pk_value }
                }
                params[:exclusive_start_key] = exclusive_start_key if exclusive_start_key
                response = client.query(params)
                all_items.concat(response.items)
                exclusive_start_key = response.last_evaluated_key
                break unless exclusive_start_key
              end
              all_items
            else
              all_items = []
              exclusive_start_key = nil
              loop do
                params = {
                  table_name: assoc_class.table_name,
                  filter_expression: '#fk = :fk',
                  expression_attribute_names: { '#fk' => dynamo_key },
                  expression_attribute_values: { ':fk' => pk_value }
                }
                params[:exclusive_start_key] = exclusive_start_key if exclusive_start_key
                response = client.scan(params)
                all_items.concat(response.items)
                exclusive_start_key = response.last_evaluated_key
                break unless exclusive_start_key
              end
              all_items
            end

            instantiated = items.map { |item| assoc_class.instantiate(item) }
            mutex.synchronize { records_by_parent[pk_value] = instantiated }
          end
        end
        threads.each(&:join)
      end

      # Cache on each record as a preloaded Relation
      records.each do |record|
        pk_value = record.send(local_key)
        associated = records_by_parent[pk_value] || []
        record._preloaded_associations[assoc_name] = associated
      end
    end
  end

  # WhereChain enables the where.not(...) syntax
  # Returns a Relation with negated conditions
  #
  # @example
  #   Container.where.not(parent_container_id: nil)  # Has a parent
  #   Container.where.not(status: 'deleted')         # Not deleted
  #   Container.where.not(status: ['a', 'b'])        # Not in array
  #
  class WhereChain
    def initialize(relation)
      @relation = relation
    end

    def not(**conditions)
      @relation.not(**conditions)
    end
  end
end
