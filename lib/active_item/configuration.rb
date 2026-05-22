# frozen_string_literal: true

require 'logger'

module ActiveItem
  # Holds global settings for ActiveItem including logger, table prefix, and
  # environment. Used to derive DynamoDB table names from model class names.
  class Configuration
    attr_accessor :logger, :table_prefix, :environment

    def initialize
      @logger = NullLogger.new
      @table_prefix = nil
      @environment = nil
    end

    # Generates table name from model class name using configured prefix/env
    # Pattern: {prefix}-{env}-{model-name-pluralized}
    # If no prefix configured, just uses the model name pluralized+dasherized
    def table_name_for(class_name)
      base = class_name.underscore.dasherize.pluralize
      parts = [table_prefix, environment, base].compact
      parts.join('-')
    end
  end
end
