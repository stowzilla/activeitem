# frozen_string_literal: true

require 'active_model'

module ActiveItem
  # ActiveModel validator that checks attribute uniqueness by querying
  # DynamoDB, with optional scope and custom condition support.
  class UniquenessValidator < ActiveModel::EachValidator
    def validate_each(record, attribute, value)
      return if value.nil? || value.to_s.empty?

      conditions = { attribute => value }
      if options[:scope]
        Array(options[:scope]).each do |scope_attr|
          conditions[scope_attr] = record.send(scope_attr)
        end
      end

      existing = record.class.where(**conditions)
      existing = existing.reject { |r| r.id == record.id } if record.id
      existing = existing.select { |r| options[:conditions].call(r) } if options[:conditions]

      record.errors.add(attribute, options[:message] || 'has already been taken') if existing.any?
    end
  end

  # Convenience validation macro for uniqueness (DynamoDB-specific).
  # Length, numericality, and format validations are provided by ActiveModel.
  module Validations
    def validates_uniqueness_of(*attributes, **options)
      validates(*attributes, uniqueness: options.empty? || options)
    end
  end
end
