# frozen_string_literal: true

module ActiveItem
  # Atomic counters: one UpdateItem that ADDs to numeric attributes, so two
  # writers incrementing at the same time both count. `save` can't do this; it
  # SETs the value the record read.
  #
  # @example Class level, no read; creates the row if it's missing
  #   ShareLink.update_counters(id, opens: 1, visitors: 1)
  #
  # @example Only touch a row that exists
  #   ShareLink.update_counters(id, { opens: 1 }, if_exists: true) # => nil when missing
  #
  # @example Instance level, refreshes the record from the stored row
  #   link.increment!(:opens, set: { last_opened_at: t }, set_if_missing: { first_opened_at: t })
  #   link.decrement!(:stock, by: 2)
  module Counters
    def self.included(base)
      base.extend(ClassMethods)
    end

    # Class-level counter API.
    module ClassMethods
      # ADD `counters` to the row with this id in one UpdateItem, without reading
      # it first. Amounts may be negative.
      #
      # Declared attributes are mapped through `to_dynamo_key`; any other name
      # (e.g. "n:page:/pricing") is used as the DynamoDB attribute name verbatim.
      # `updatedAt` is set, and `createdAt` and `_recent_pk` are set only if
      # missing, unless `touch: false`.
      #
      # @param set [Hash] attributes to SET alongside the counters (nil REMOVEs)
      # @param set_if_missing [Hash] attributes to SET only if absent (if_not_exists)
      # @param if_exists [Boolean] condition on the row existing instead of creating it
      # @param touch [Boolean] false leaves updatedAt, createdAt and _recent_pk alone
      # @return [ActiveItem::Base, nil] the row as stored after the update, or nil
      #   when `if_exists: true` and there is no such row
      def update_counters(id, counters = nil, set: {}, set_if_missing: {}, if_exists: false, touch: true, **more_counters)
        counters = (counters || {}).merge(more_counters)
        item = counter_update_item(id, counters, set: set, set_if_missing: set_if_missing, if_exists: if_exists, touch: touch)
        item && instantiate(item)
      end

      private

      # Runs the UpdateItem and returns the raw ALL_NEW item, or nil when the
      # `if_exists` condition failed.
      def counter_update_item(id, counters, set:, set_if_missing:, if_exists:, touch: true)
        raise_embedded_error!(:update_counters) if respond_to?(:embedded?) && embedded?
        raise ArgumentError, 'update_counters needs an id' if id.nil? || id.to_s.empty?
        raise ArgumentError, 'update_counters needs at least one counter' if counters.empty?

        dynamodb.update_item(counter_update_params(id, counters, set, set_if_missing, if_exists, touch)).attributes
      rescue Aws::DynamoDB::Errors::ConditionalCheckFailedException
        raise unless if_exists

        nil
      rescue Aws::DynamoDB::Errors::AccessDeniedException => e
        raise_access_denied('UpdateItem', e)
      end

      def counter_update_params(id, counters, set, set_if_missing, if_exists, touch)
        names = {}
        values = {}
        sets = []
        removes = []
        adds = []
        claimed = {}
        claim = lambda do |name|
          dynamo_key = counter_dynamo_key(name)
          raise ArgumentError, "#{dynamo_key} appears more than once in update_counters" if claimed.key?(dynamo_key)

          claimed[dynamo_key] = true
          placeholder = "#a#{claimed.size}"
          names[placeholder] = dynamo_key
          placeholder
        end

        claimed[primary_key.to_s] = true
        timestamps = touch ? { 'updatedAt' => '#updatedAt', 'createdAt' => '#createdAt', '_recent_pk' => '#recentPk' } : {}
        timestamps.each_key { |key| claimed[key] = true }

        counters.each do |name, amount|
          raise ArgumentError, "counter #{name} needs a numeric amount, got #{amount.inspect}" unless amount.is_a?(Numeric)

          placeholder = claim.call(name)
          values[":#{placeholder[1..]}"] = amount
          adds << "#{placeholder} :#{placeholder[1..]}"
        end

        set.each do |name, value|
          placeholder = claim.call(name)
          if value.nil?
            removes << placeholder
          else
            values[":#{placeholder[1..]}"] = value
            sets << "#{placeholder} = :#{placeholder[1..]}"
          end
        end

        set_if_missing.each do |name, value|
          raise ArgumentError, "set_if_missing #{name} needs a value" if value.nil?

          placeholder = claim.call(name)
          values[":#{placeholder[1..]}"] = value
          sets << "#{placeholder} = if_not_exists(#{placeholder}, :#{placeholder[1..]})"
        end

        if touch
          timestamps.each { |key, placeholder| names[placeholder] = key }
          values[':now'] = Time.now.utc.iso8601
          values[':recentPk'] = 'ALL'
          sets.unshift('#updatedAt = :now', '#createdAt = if_not_exists(#createdAt, :now)',
                       '#recentPk = if_not_exists(#recentPk, :recentPk)')
        end

        expression = "ADD #{adds.join(', ')}"
        expression = "SET #{sets.join(', ')} #{expression}" if sets.any?
        expression += " REMOVE #{removes.join(', ')}" if removes.any?

        params = {
          table_name: table_name,
          key: { primary_key.to_s => id },
          update_expression: expression,
          expression_attribute_names: names,
          expression_attribute_values: values,
          return_values: 'ALL_NEW'
        }
        if if_exists
          names['#pk'] = primary_key.to_s
          params[:condition_expression] = 'attribute_exists(#pk)'
        end
        params
      end

      # Declared (or explicitly mapped) attributes go through to_dynamo_key;
      # anything else is already a DynamoDB attribute name.
      def counter_dynamo_key(name)
        name = name.to_s
        return to_dynamo_key(name) if attribute_names.include?(name) || dynamo_attribute_map.key?(name)

        name
      end
    end

    # ADD `by` to each attribute on the stored row in one UpdateItem, then
    # refresh those attributes (and the timestamps) from what was stored. The
    # touched attributes are left clean; other unsaved changes are kept.
    #
    # Only updates a row that still exists: a deleted record is not brought
    # back by its counter.
    #
    # @return [self, false] false when the row no longer exists
    def increment!(*attributes, by: 1, set: {}, set_if_missing: {})
      raise ArgumentError, 'increment! needs at least one attribute' if attributes.empty?
      raise ArgumentError, "Cannot increment a new #{self.class.name}; save it first" if new_record?

      attributes = attributes.map(&:to_s)
      touched = attributes + set.keys.map(&:to_s) + set_if_missing.keys.map(&:to_s)
      undeclared = touched - self.class.attribute_names
      raise ArgumentError, "#{self.class.name} has no attribute #{undeclared.join(', ')}" if undeclared.any?

      counters = attributes.to_h { |name| [name, by] }
      item = self.class.send(:counter_update_item, id, counters, set: set, set_if_missing: set_if_missing, if_exists: true)
      return false unless item

      refresh_counter_attributes(item, touched)
      self
    end

    # increment! with the amount negated.
    def decrement!(*attributes, by: 1, set: {}, set_if_missing: {})
      increment!(*attributes, by: -by, set: set, set_if_missing: set_if_missing)
    end

    private

    def refresh_counter_attributes(item, touched)
      fresh = self.class.instantiate(item)
      touched.each { |name| instance_variable_set("@#{name}", fresh.instance_variable_get("@#{name}")) }
      @created_at = fresh.created_at
      @updated_at = fresh.updated_at
      @dbrecord = fresh.dbrecord
      clear_attribute_changes(touched)
    end
  end
end
