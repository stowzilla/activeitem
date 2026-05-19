# frozen_string_literal: true

require 'aws-sdk-dynamodb'
require 'active_support/core_ext/string/inflections'
require 'active_support/core_ext/hash/indifferent_access'
require 'active_support/core_ext/array/extract_options'
require 'active_support/callbacks'
require 'active_support/concern'
require 'active_model'
require 'securerandom'

module DynamoRecord
  class Base
    include ActiveModel::Validations
    include ActiveSupport::Callbacks
    include Associations
    include Logging

    def self.const_missing(name)
      DynamoRecord.const_defined?(name) ? DynamoRecord.const_get(name) : super
    end

    prepend ComposedOf

    extend DatabaseHelpers
    extend QueryHelpers
    extend Validations

    define_callbacks :save, :create, :update, :destroy, :validation
    define_model_callbacks :initialize, only: :after

    attr_accessor :id, :created_at, :updated_at, :dbrecord

    def id=(value)
      @id = (value.to_s.strip.empty? ? nil : value)
    end

    set_callback :create, :before, :generate_primary_key
    set_callback :create, :before, :set_created_timestamp
    set_callback :destroy, :before, :check_dependent_associations

    def initialize(attributes = {})
      @previously_changed = {}
      @pending_changes = {}
      @_preloaded_counts = {}
      @_preloaded_associations = {}
      @new_record = true

      if attributes.is_a?(Hash)
        attributes.each do |key, value|
          setter = "#{key}="
          send(setter, value) if respond_to?(setter)
        end
      end
    end

    def _preloaded_counts
      @_preloaded_counts ||= {}
    end

    def _preloaded_associations
      @_preloaded_associations ||= {}
    end

    def self.attribute_names
      @attribute_names ||= begin
        instance_methods.grep(/\A[a-z_][a-z0-9_]*=\z/).map { |m| m.to_s.chomp('=') }.sort
      end
    end

    def populate_attributes_from_item(item)
      self.class.attribute_names.each do |attr_name|
        next if attr_name == 'id'

        value = nil
        found = false
        self.class.dynamo_key_variants(attr_name).each do |key|
          if item.key?(key)
            value = item[key]
            found = true
            break
          end
        end

        instance_variable_set("@#{attr_name}", value) if found
      end

      @created_at = item['createdAt'] || item['created_at']
      @updated_at = item['updatedAt'] || item['updated_at']

      populate_custom_attributes_from_item(item) if respond_to?(:populate_custom_attributes_from_item, true)
      populate_composed_attributes_from_item(item) if self.class.respond_to?(:compositions) && self.class.compositions.any?
    end

    class << self
      def attr_accessor(*attrs)
        attrs.each do |attr|
          attr_name = attr.to_s

          define_method(attr_name) do
            instance_variable_get("@#{attr_name}")
          end

          define_method("#{attr_name}=") do |value|
            old_value = instance_variable_get("@#{attr_name}")
            instance_variable_set("@#{attr_name}", value)

            if old_value != value && instance_variable_defined?(:@pending_changes)
              @pending_changes ||= {}
              @pending_changes[attr_name] ||= [old_value, nil]
              @pending_changes[attr_name][1] = value
            end
          end
        end
      end

      def primary_key
        @primary_key ||= 'id'
      end

      def primary_key=(value)
        remove_method primary_key.to_sym
        remove_method "#{primary_key}=".to_sym

        @primary_key = value.to_s

        alias_method primary_key.to_sym, :id
        alias_method "#{primary_key}=".to_sym, :id=
      end

      def table_name
        @table_name || default_table_name
      end

      def table_name=(value)
        @table_name = value.to_s
      end

      def dynamodb
        @dynamodb ||= Aws::DynamoDB::Client.new(http_wire_trace: false)
      end

      def dynamodb=(client)
        @dynamodb = client
      end

      def dynamo_attribute_map(mappings = nil)
        if mappings
          @dynamo_attribute_map = mappings.transform_keys(&:to_s)
        else
          @dynamo_attribute_map || {}
        end
      end

      def to_dynamo_key(attr_name)
        attr_str = attr_name.to_s
        return dynamo_attribute_map[attr_str] if dynamo_attribute_map.key?(attr_str)
        attr_str.camelize(:lower)
      end

      def from_dynamo_key(dynamo_key)
        key_str = dynamo_key.to_s
        reverse_map = dynamo_attribute_map.invert
        return reverse_map[key_str] if reverse_map.key?(key_str)
        key_str.underscore
      end

      def dynamo_key_variants(attr_name)
        attr_str = attr_name.to_s
        primary_key = to_dynamo_key(attr_str)
        camel_case = attr_str.camelize(:lower)
        [primary_key, camel_case, attr_str].uniq
      end

      def instantiate(item)
        normalized_item = normalize_dynamodb_values(item)

        record = allocate
        record.instance_variable_set(:@id, normalized_item[self.primary_key])
        record.send(:populate_attributes_from_item, normalized_item)
        record.instance_variable_set(:@new_record, false)
        record.instance_variable_set(:@previously_changed, {})
        record.instance_variable_set(:@pending_changes, {})
        record.instance_variable_set(:@dbrecord, normalized_item)
        record
      end

      def normalize_dynamodb_values(obj)
        case obj
        when BigDecimal
          obj.frac.zero? ? obj.to_i : obj.to_f
        when Hash
          obj.transform_values { |v| normalize_dynamodb_values(v) }
        when Array
          obj.map { |v| normalize_dynamodb_values(v) }
        else
          obj
        end
      end

      def find_or_create_by(attributes, &block)
        record = find_by(**attributes)
        return record if record

        record = new(**attributes)
        block.call(record) if block_given?
        record.save
        record
      end

      # Callback DSL
      def before_save(*args, &block)
        options = args.extract_options!
        if options[:on]
          case options[:on].to_sym
          when :create then set_callback(:create, :before, *args, &block)
          when :update then set_callback(:update, :before, *args, &block)
          else raise ArgumentError, "Invalid on: option '#{options[:on]}'. Must be :create or :update"
          end
        else
          set_callback(:save, :before, *args, &block)
        end
      end

      def after_save(*args, &block)
        options = args.extract_options!
        if options[:on]
          case options[:on].to_sym
          when :create then set_callback(:create, :after, *args, &block)
          when :update then set_callback(:update, :after, *args, &block)
          else raise ArgumentError, "Invalid on: option '#{options[:on]}'. Must be :create or :update"
          end
        else
          set_callback(:save, :after, *args, &block)
        end
      end

      def before_create(*args, &block) = set_callback(:create, :before, *args, &block)
      def after_create(*args, &block) = set_callback(:create, :after, *args, &block)
      def before_update(*args, &block) = set_callback(:update, :before, *args, &block)
      def after_update(*args, &block) = set_callback(:update, :after, *args, &block)
      def before_validation(*args, &block) = set_callback(:validation, :before, *args, &block)
      def after_validation(*args, &block) = set_callback(:validation, :after, *args, &block)
      def before_destroy(*args, &block) = set_callback(:destroy, :before, *args, &block)
      def after_destroy(*args, &block) = set_callback(:destroy, :after, *args, &block)

      def scope(name, body)
        raise ArgumentError, "scope body must be callable (Proc/Lambda)" unless body.respond_to?(:call)
        _scopes[name.to_sym] = body
        define_singleton_method(name) { all.instance_exec(&body) }
      end

      def _scopes
        @_scopes ||= {}
      end

      private

      def default_table_name
        raise "Cannot generate table name for anonymous class" unless name
        DynamoRecord.configuration.table_name_for(name)
      end

      def inherited(subclass)
        super
        subclass.class_eval do
          alias_method primary_key.to_sym, :id
          alias_method "#{primary_key}=".to_sym, :id=
        end
      end
    end

    def new_record?
      @new_record != false
    end

    def persisted?
      !new_record?
    end

    def reload
      raise "Cannot reload a new record" if new_record?
      fresh_record = self.class.find(id)
      raise "Record not found: #{self.class.name} with id #{id}" unless fresh_record

      self.class.attribute_names.each do |attr_name|
        next if attr_name == 'dbrecord'
        value = fresh_record.instance_variable_get("@#{attr_name}")
        instance_variable_set("@#{attr_name}", value)
      end

      @created_at = fresh_record.created_at
      @updated_at = fresh_record.updated_at
      @dbrecord = fresh_record.dbrecord
      @pending_changes = {}
      @previously_changed = {}
      self
    end

    def has_changes_to_save?
      changes.any?
    end

    def to_h
      attributes.with_indifferent_access
    end

    def attributes
      attrs = {}
      pk_name = self.class.primary_key
      pk_value = send(pk_name) rescue instance_variable_get("@#{pk_name}")
      attrs['id'] = pk_value
      attrs[pk_name] = pk_value

      self.class.attribute_names.each do |attr_name|
        next if attr_name == 'dbrecord'
        value = instance_variable_get("@#{attr_name}")
        attrs[attr_name] = value unless value.nil?
      end

      attrs['created_at'] = @created_at
      attrs['updated_at'] = @updated_at
      attrs
    end

    def inspect
      pk_value = send(self.class.primary_key) rescue id
      attr_strs = self.class.attribute_names.filter_map do |attr|
        next if attr == 'dbrecord'
        value = instance_variable_get("@#{attr}")
        next if value.nil?
        "#{attr}: #{value.inspect}"
      end
      "#<#{self.class.name} #{attr_strs.join(', ')}>"
    end

    def update(attributes)
      assign_attributes(attributes)
      save
    end

    def update!(attributes)
      assign_attributes(attributes)
      save!
    end

    def save(validate: true)
      return false if validate && !run_validations

      result = run_callbacks :save do
        if new_record?
          run_callbacks(:create) { perform_create }
        else
          run_callbacks(:update) { perform_update }
        end
      end

      return false if result == false
      changes_applied
      true
    rescue => e
      dynamo_logger.error("Failed to save #{self.class.name}: #{e.message}")
      raise e
    end

    def save!
      raise StandardError, "Validation failed: #{errors.full_messages.join(', ')}" unless save
    end

    def self.create(attributes = {})
      obj = new(attributes)
      obj.save
      obj
    end

    def self.create!(attributes = {})
      obj = new(attributes)
      obj.save!
      obj
    end

    def self.transaction
      txn = Transaction.new
      yield txn
      txn.execute!
    end

    def self.transaction_find(items)
      return [] if items.empty?
      raise TransactionError, "DynamoDB transactions are limited to 100 items (got #{items.length})" if items.length > 100

      transact_items = items.map do |item|
        { get: { table_name: item[:model].table_name, key: { item[:model].primary_key.to_s => item[:key] } } }
      end

      client = items.first[:model].dynamodb
      response = client.transact_get_items(transact_items: transact_items)

      response.responses.each_with_index.map do |resp, idx|
        items[idx][:model].instantiate(resp.item) if resp.item
      end
    rescue Aws::DynamoDB::Errors::TransactionCanceledException => e
      raise TransactionError, "Transaction read cancelled: #{e.message}"
    end

    def destroy
      result = run_callbacks(:destroy) { perform_destroy }
      return false if result == false
      true
    rescue DeleteRestrictionError
      false
    rescue => e
      dynamo_logger.error("Failed to destroy #{self.class.name}: #{e.message}")
      errors.add(:base, e.message)
      false
    end

    def delete
      perform_destroy
      true
    rescue => e
      dynamo_logger.error("Failed to delete #{self.class.name}: #{e.message}")
      false
    end

    def assign_attributes(attributes)
      attributes.each do |key, value|
        setter = "#{key}="
        if respond_to?(setter)
          old_value = send(key)
          @pending_changes[key.to_s] = [old_value, value] if old_value != value
          send(setter, value)
        end
      end
    end

    def attribute_changed?(attr_name)
      @pending_changes.key?(attr_name.to_s)
    end

    def attribute_was(attr_name)
      @pending_changes.dig(attr_name.to_s, 0)
    end

    def changes
      @pending_changes
    end

    def previous_changes
      @previously_changed
    end

    def changes_applied
      @previously_changed = @pending_changes.dup
      @pending_changes = {}
      @new_record = false
    end

    def valid?(context = nil)
      return super(context) if defined?(@running_validations) && @running_validations

      @running_validations = true
      begin
        run_callbacks(:validation) { super(context) }
      ensure
        @running_validations = false
      end
    end

    private

    def generate_primary_key
      @id = nil if @id.to_s.strip.empty?
      @id ||= SecureRandom.uuid

      pk = self.class.primary_key
      instance_variable_set("@#{pk}", @id) if pk != 'id'
    end

    def set_created_timestamp
      @created_at ||= Time.now.utc.iso8601
    end

    def dynamodb
      self.class.dynamodb
    end

    def table_name
      self.class.table_name
    end

    def run_validations
      context = new_record? ? :create : :update
      valid?(context)
    end

    def perform_create
      item = build_dynamodb_item
      item['createdAt'] = @created_at
      item['updatedAt'] = Time.now.utc.iso8601

      dynamodb.put_item(
        table_name: table_name,
        item: item,
        condition_expression: 'attribute_not_exists(#pk)',
        expression_attribute_names: { '#pk' => self.class.primary_key.to_s }
      )

      dynamo_logger.info("#{self.class.name} created (#{self.class.primary_key}: #{id})")
    rescue Aws::DynamoDB::Errors::ConditionalCheckFailedException
      errors.add(:id, "already exists")
      false
    rescue Aws::DynamoDB::Errors::AccessDeniedException => e
      raise DynamoRecord::AccessDeniedError.new(model_name: self.class.name, table: table_name,
                                                operation: 'PutItem', original_error: e)
    end

    def build_dynamodb_item
      item = { self.class.primary_key.to_s => id }

      dynamodb_attributes.each do |attr|
        value = instance_variable_get("@#{attr}")
        next if value.nil?
        dynamo_key = self.class.to_dynamo_key(attr)
        item[dynamo_key] = value
      end

      item
    end

    def dynamodb_attributes
      attrs = self.class.attribute_names - [self.class.primary_key.sub('_id', ''), 'id', 'dbrecord']

      if self.class.respond_to?(:compositions) && self.class.compositions.any?
        composed_attrs = self.class.compositions.values.flat_map { |c| c[:mapping].keys.map(&:to_s) }
        attrs -= composed_attrs
      end

      attrs
    end

    def perform_update
      return if changes.empty?

      update_parts = []
      remove_parts = []
      attr_values = {}
      attr_names = {}

      changes.each_with_index do |(field, (_old_val, new_val)), idx|
        dynamo_key = self.class.to_dynamo_key(field)
        if new_val.nil?
          remove_parts << "#field#{idx}"
          attr_names["#field#{idx}"] = dynamo_key
        else
          update_parts << "#field#{idx} = :val#{idx}"
          attr_names["#field#{idx}"] = dynamo_key
          attr_values[":val#{idx}"] = new_val
        end
      end

      update_parts << "updatedAt = :updatedAt"
      attr_values[':updatedAt'] = Time.now.utc.iso8601

      update_expression = "SET #{update_parts.join(', ')}"
      update_expression += " REMOVE #{remove_parts.join(', ')}" if remove_parts.any?

      params = {
        table_name: table_name,
        key: { self.class.primary_key.to_s => id },
        update_expression: update_expression,
        expression_attribute_values: attr_values
      }
      params[:expression_attribute_names] = attr_names if attr_names.any?

      dynamodb.update_item(params)
    rescue Aws::DynamoDB::Errors::AccessDeniedException => e
      raise DynamoRecord::AccessDeniedError.new(model_name: self.class.name, table: table_name,
                                                operation: 'UpdateItem', original_error: e)
    end

    def perform_destroy
      key = self.class.primary_key.to_s
      dynamodb.delete_item(table_name: table_name, key: { key => send(key) })
      dynamo_logger.info("#{self.class.name} deleted (#{key}: #{send(key)})")
    rescue Aws::DynamoDB::Errors::AccessDeniedException => e
      raise DynamoRecord::AccessDeniedError.new(model_name: self.class.name, table: table_name,
                                                operation: 'DeleteItem', original_error: e)
    end
  end
end
