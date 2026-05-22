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

  # Convenience validation macros (uniqueness, length, numericality, format)
  # that extend ActiveModel::Validations for DynamoDB-backed models.
  module Validations
    def validates_uniqueness_of(*attributes, **options)
      validates(*attributes, uniqueness: options.empty? || options)
    end

    def validates_length_of(*attributes, **options)
      attributes.each do |attribute|
        validate do
          value = send(attribute)
          next if value.nil?

          length = value.to_s.length

          errors.add(attribute, options[:message] || "is too short (minimum is #{options[:minimum]} characters)") if options[:minimum] && length < options[:minimum]
          errors.add(attribute, options[:message] || "is too long (maximum is #{options[:maximum]} characters)") if options[:maximum] && length > options[:maximum]
          if options[:in] && !options[:in].include?(length)
            errors.add(attribute, options[:message] || "length must be between #{options[:in].min} and #{options[:in].max} characters")
          end
          errors.add(attribute, options[:message] || "must be exactly #{options[:is]} characters") if options[:is] && length != options[:is]
        end
      end
    end

    def validates_numericality_of(*attributes, **options)
      attributes.each do |attribute|
        validate do
          value = send(attribute)
          next if value.nil?

          unless value.is_a?(Numeric) || value.to_s.match?(/\A-?\d+(\.\d+)?\z/)
            errors.add(attribute, options[:message] || 'is not a number')
            next
          end

          num_value = value.to_f

          if options[:only_integer] && num_value != num_value.to_i
            errors.add(attribute, options[:message] || 'must be an integer')
            next
          end

          errors.add(attribute, options[:message] || "must be greater than #{options[:greater_than]}") if options[:greater_than] && num_value <= options[:greater_than]
          if options[:greater_than_or_equal_to] && num_value < options[:greater_than_or_equal_to]
            errors.add(attribute, options[:message] || "must be greater than or equal to #{options[:greater_than_or_equal_to]}")
          end
          errors.add(attribute, options[:message] || "must be less than #{options[:less_than]}") if options[:less_than] && num_value >= options[:less_than]
          if options[:less_than_or_equal_to] && num_value > options[:less_than_or_equal_to]
            errors.add(attribute, options[:message] || "must be less than or equal to #{options[:less_than_or_equal_to]}")
          end
          errors.add(attribute, options[:message] || "must be equal to #{options[:equal_to]}") if options[:equal_to] && num_value != options[:equal_to]
        end
      end
    end

    def validates_format_of(*attributes, **options)
      attributes.each { |attribute| validates attribute, format: options }
    end
  end
end
