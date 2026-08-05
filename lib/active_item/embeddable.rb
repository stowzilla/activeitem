# frozen_string_literal: true

require 'active_support/concern'

module ActiveItem
  # Mixin for models that are stored embedded within a parent record
  # rather than in their own DynamoDB table.
  #
  # Usage:
  #   class Thing < ActiveItem::Base
  #     self.embedded = true
  #     attr_accessor :name, :weight
  #   end
  #
  # Embedded models:
  # - Cannot be queried directly (no table)
  # - Cannot call find, where, all, count, etc.
  # - Are serialized/deserialized by their parent
  # - Still support validations, callbacks, and dirty tracking
  module Embeddable
    extend ActiveSupport::Concern

    included do
      class_attribute :embedded, default: false
    end

    class_methods do
      def embedded?
        embedded == true
      end
    end

    # Instance methods — prevent direct save/destroy on embedded models
    # are handled in Base#save and Base#destroy directly.

    # Serialize this embedded record to a DynamoDB-compatible hash.
    def to_embedded_hash
      item = { 'id' => id || SecureRandom.uuid }

      self.class.attribute_names.each do |attr_name|
        next if attr_name == 'id' || attr_name == 'dbrecord'

        value = instance_variable_get("@#{attr_name}")
        next if value.nil?

        dynamo_key = self.class.to_dynamo_key(attr_name)
        item[dynamo_key] = value
      end

      item['createdAt'] = @created_at if @created_at
      item['updatedAt'] = @updated_at if @updated_at
      item
    end

    # Hydrate an embedded record from a DynamoDB hash.
    def self.from_embedded_hash(klass, hash)
      record = klass.allocate
      record.instance_variable_set(:@id, hash['id'])
      record.instance_variable_set(:@new_record, false)
      record.instance_variable_set(:@created_at, hash['createdAt'])
      record.instance_variable_set(:@updated_at, hash['updatedAt'])

      klass.attribute_names.each do |attr_name|
        next if attr_name == 'id' || attr_name == 'dbrecord'

        value = nil
        found = false
        klass.dynamo_key_variants(attr_name).each do |key|
          next unless hash.key?(key)

          value = hash[key]
          found = true
          break
        end

        record.instance_variable_set("@#{attr_name}", value) if found
      end

      record.send(:clear_changes_information) if record.respond_to?(:clear_changes_information, true)
      record
    end
  end
end
