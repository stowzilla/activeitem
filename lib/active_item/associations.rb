# frozen_string_literal: true

require 'active_support/concern'
require 'active_support/inflector'
require_relative 'model_loader'

module ActiveItem
  # Provides has_many and belongs_to association macros with lazy loading,
  # preloading support, and dependent record handling (destroy, nullify,
  # restrict).
  module Associations
    extend ActiveSupport::Concern
    include ModelLoader

    included do
      class_attribute :_associations, default: {}
    end

    def check_dependent_associations
      self.class._associations.each do |name, config|
        next unless config[:type] == :has_many && config[:dependent]

        case config[:dependent]
        when :restrict_with_exception
          raise DeleteRestrictionError, name if send(name).limit(1).any?
        when :restrict_with_error
          if send(name).limit(1).any?
            error_message = config[:message] || "Cannot delete #{self.class.name} because dependent #{name} exist"
            errors.add(:base, error_message)
            throw(:abort)
          end
        when :destroy
          send(name).each(&:destroy)
        when :delete_all
          send(name).each(&:delete)
        when :nullify
          foreign_key = config[:foreign_key]
          send(name).each { |record| record.update(foreign_key => nil) }
        end
      end
    end

    class_methods do
      def has_many(name, scope_or_options = nil, options = {})
        if scope_or_options.is_a?(Proc)
          scope = scope_or_options
        elsif scope_or_options.is_a?(Hash)
          options = scope_or_options
          scope = nil
        else
          scope = nil
        end

        association_name = name.to_sym
        class_name = options[:class_name] || name.to_s.singularize.camelize
        foreign_key = options[:foreign_key] || "#{self.name.underscore}_id"
        index_name = options[:index]
        local_key = options[:primary_key] || primary_key

        self._associations = _associations.merge(
          association_name => {
            type: :has_many, class_name: class_name, foreign_key: foreign_key,
            index: index_name, primary_key: local_key, scope: scope,
            dependent: options[:dependent], message: options[:message]
          }
        )

        define_method(association_name) { load_has_many_association(association_name) }

        define_method(:"#{association_name}_count") do
          _preloaded_counts.key?(association_name) ? _preloaded_counts[association_name] : send(association_name).length
        end
      end

      def belongs_to(name, options = {})
        association_name = name.to_sym
        class_name = options[:class_name] || name.to_s.camelize
        foreign_key = options[:foreign_key] || "#{name}_id"
        remote_primary_key = options[:primary_key]
        optional = options.fetch(:optional, false)

        self._associations = _associations.merge(
          association_name => {
            type: :belongs_to, class_name: class_name, foreign_key: foreign_key,
            primary_key: remote_primary_key, optional: optional
          }
        )

        foreign_key_sym = foreign_key.to_sym
        attr_accessor foreign_key_sym unless method_defined?(foreign_key_sym) || private_method_defined?(foreign_key_sym)

        validates foreign_key_sym, presence: true unless optional

        define_method(association_name) { load_belongs_to_association(association_name) }

        define_method("#{association_name}=") { |record| set_belongs_to_association(association_name, record) }

        default_foreign_key = "#{association_name}_id"
        return unless foreign_key.to_s != default_foreign_key

        define_method(default_foreign_key) { send(foreign_key) }
        define_method("#{default_foreign_key}=") { |value| send("#{foreign_key}=", value) }
      end
    end

    private

    def load_has_many_association(name)
      config = self.class._associations[name]
      return Relation.new(Object, conditions: { _empty: true }) unless config

      return Relation.new(nil, preloaded_records: _preloaded_associations[name], class_name: config[:class_name]) if _preloaded_associations.key?(name)

      local_key_value = send(config[:primary_key])
      return Relation.new(nil, conditions: { _empty: true }, class_name: config[:class_name]) if local_key_value.nil?

      conditions = { config[:foreign_key].to_sym => local_key_value }
      relation = Relation.new(nil, conditions: conditions, index_name: config[:index],
                                   class_name: config[:class_name], owner: self)

      if config[:scope]
        if config[:scope].arity.zero?
          relation.instance_exec(&config[:scope]) || relation
        else
          config[:scope].call(relation)
        end
      else
        relation
      end
    end

    def load_belongs_to_association(name)
      config = self.class._associations[name]
      return nil unless config

      cache_var = :"@_association_cache_#{name}"
      return instance_variable_get(cache_var) if instance_variable_defined?(cache_var)

      foreign_key_value = send(config[:foreign_key])
      return nil if foreign_key_value.nil?

      klass = safe_constantize_model(config[:class_name])

      begin
        record = klass.find(foreign_key_value)
      rescue ActiveItem::RecordNotFound
        raise unless config[:optional]

        record = nil
      end
      instance_variable_set(cache_var, record)
      record
    end

    def set_belongs_to_association(name, record)
      config = self.class._associations[name]
      return unless config

      cache_var = :"@_association_cache_#{name}"
      instance_variable_set(cache_var, record)

      if record.nil?
        send("#{config[:foreign_key]}=", nil)
      else
        pk = config[:primary_key] || record.class.primary_key
        send("#{config[:foreign_key]}=", record.send(pk))
      end

      hook_method = :"after_set_#{name}_association"
      send(hook_method, record) if respond_to?(hook_method, true)
    end
  end
end
