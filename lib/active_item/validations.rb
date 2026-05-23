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

      relation = record.class.where(**conditions)

      if options[:conditions]
        # Custom conditions require loading records for Ruby-side filtering
        existing = relation.to_a
        existing = existing.reject { |r| r.id == record.id } if record.id
        existing = existing.select { |r| options[:conditions].call(r) }
        taken = existing.any?
      elsif record.id
        # Need to exclude current record — fetch up to 2 (current + one other)
        existing = relation.limit(2).to_a
        taken = existing.any? { |r| r.id != record.id }
      else
        # New record — just check if any match exists
        taken = !relation.first.nil?
      end

      record.errors.add(attribute, options[:message] || 'has already been taken') if taken
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
