# frozen_string_literal: true

require 'active_support/concern'

module DynamoRecord
  module ComposedOf
    extend ActiveSupport::Concern

    def populate_composed_attributes_from_item(item)
      self.class.compositions.each do |part_id, config|
        dynamo_key = self.class.to_dynamo_key(part_id.to_s)
        vo_class = Object.const_get(config[:class_name])

        if item[dynamo_key].is_a?(Hash)
          vo = if vo_class.respond_to?(:from_dynamo_map)
                 vo_class.from_dynamo_map(item[dynamo_key])
               else
                 kwargs = {}
                 config[:mapping].each do |_model_attr, vo_attr|
                   key = self.class.to_dynamo_key(vo_attr.to_s)
                   kwargs[vo_attr] = item[dynamo_key][key] || item[dynamo_key][vo_attr.to_s]
                 end
                 vo_class.new(**kwargs)
               end

          instance_variable_set("@_composed_#{part_id}", vo)
          config[:mapping].each do |model_attr, vo_attr|
            instance_variable_set("@#{model_attr}", vo.send(vo_attr))
          end
        end
      end
    end

    private

    def build_dynamodb_item
      item = super

      self.class.compositions.each do |part_id, config|
        vo = send(part_id)
        dynamo_key = self.class.to_dynamo_key(part_id.to_s)

        if vo.nil?
          item.delete(dynamo_key)
        elsif vo.respond_to?(:to_dynamo_map)
          item[dynamo_key] = vo.to_dynamo_map
        else
          map = {}
          config[:mapping].each do |_model_attr, vo_attr|
            key = self.class.to_dynamo_key(vo_attr.to_s)
            map[key] = vo.send(vo_attr)
          end
          item[dynamo_key] = map.compact
        end

        config[:mapping].each_key do |model_attr|
          flat_key = self.class.to_dynamo_key(model_attr.to_s)
          item.delete(flat_key)
        end
      end

      item
    end

    def perform_update
      return if changes.empty?

      compositions = self.class.compositions
      return super if compositions.empty?

      changed_compositions = {}
      compositions.each do |part_id, config|
        changed_attrs = config[:mapping].keys.map(&:to_s) & changes.keys
        changed_compositions[part_id] = config if changed_attrs.any?
      end

      return super if changed_compositions.empty?

      update_parts = []
      remove_parts = []
      attr_values = {}
      attr_names = {}
      idx = 0

      composed_flat_keys = compositions.values.flat_map { |c| c[:mapping].keys.map(&:to_s) }.to_set

      changes.each do |field, (_old_val, new_val)|
        next if composed_flat_keys.include?(field)
        dynamo_key = self.class.to_dynamo_key(field)
        if new_val.nil?
          remove_parts << "#field#{idx}"
          attr_names["#field#{idx}"] = dynamo_key
        else
          update_parts << "#field#{idx} = :val#{idx}"
          attr_names["#field#{idx}"] = dynamo_key
          attr_values[":val#{idx}"] = new_val
        end
        idx += 1
      end

      changed_compositions.each do |part_id, _config|
        remove_instance_variable("@_composed_#{part_id}") if instance_variable_defined?("@_composed_#{part_id}")
        vo = send(part_id)
        dynamo_key = self.class.to_dynamo_key(part_id.to_s)

        if vo.nil?
          remove_parts << "#field#{idx}"
          attr_names["#field#{idx}"] = dynamo_key
        else
          map_value = vo.respond_to?(:to_dynamo_map) ? vo.to_dynamo_map : vo.to_h
          update_parts << "#field#{idx} = :val#{idx}"
          attr_names["#field#{idx}"] = dynamo_key
          attr_values[":val#{idx}"] = map_value
        end
        idx += 1
      end

      update_parts << 'updatedAt = :updatedAt'
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
    end

    module ClassMethods
      def compositions
        @_compositions ||= {}
      end

      def composed_of(part_id, options = {})
        class_name  = options[:class_name] || part_id.to_s.camelize
        mapping     = options[:mapping] || {}
        allow_nil   = options.fetch(:allow_nil, true)
        constructor = options.fetch(:constructor, :new)
        converter   = options[:converter]

        compositions[part_id] = { class_name: class_name, mapping: mapping, allow_nil: allow_nil,
                                  constructor: constructor, converter: converter }

        define_method(part_id) do
          ivar = "@_composed_#{part_id}"
          return instance_variable_get(ivar) if instance_variable_defined?(ivar)

          vo_class = Object.const_get(class_name)
          values = mapping.map { |model_attr, _vo_attr| send(model_attr) }

          if allow_nil && values.all? { |v| v.nil? || (v.respond_to?(:empty?) && v.empty?) }
            instance_variable_set(ivar, nil)
            return nil
          end

          vo = if constructor.is_a?(Proc)
                 constructor.call(*values)
               else
                 kwargs = {}
                 mapping.each { |model_attr, vo_attr| kwargs[vo_attr] = send(model_attr) }
                 vo_class.send(constructor, **kwargs)
               end

          instance_variable_set(ivar, vo)
        end

        define_method("#{part_id}=") do |value|
          ivar = "@_composed_#{part_id}"

          if value.nil?
            mapping.each_key { |model_attr| send("#{model_attr}=", nil) }
            instance_variable_set(ivar, nil)
          elsif value.is_a?(Object.const_get(class_name))
            mapping.each { |model_attr, vo_attr| send("#{model_attr}=", value.send(vo_attr)) }
            instance_variable_set(ivar, value)
          elsif converter
            converted = converter.is_a?(Proc) ? converter.call(value) : Object.const_get(class_name).send(converter, value)
            send("#{part_id}=", converted)
          elsif value.is_a?(Hash)
            vo = Object.const_get(class_name).new(**value.transform_keys(&:to_sym))
            send("#{part_id}=", vo)
          else
            raise ArgumentError, "Cannot assign #{value.class} to #{part_id}. Expected #{class_name}, Hash, or nil."
          end
        end
      end
    end
  end
end
