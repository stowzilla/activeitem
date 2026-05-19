# frozen_string_literal: true

require_relative 'dynamo_record/version'
require_relative 'dynamo_record/configuration'
require_relative 'dynamo_record/logging'
require_relative 'dynamo_record/errors'
require_relative 'dynamo_record/database_helpers'
require_relative 'dynamo_record/query_helpers'
require_relative 'dynamo_record/relation'
require_relative 'dynamo_record/associations'
require_relative 'dynamo_record/composed_of'
require_relative 'dynamo_record/validations'
require_relative 'dynamo_record/transaction'
require_relative 'dynamo_record/pagination'
require_relative 'dynamo_record/base'

module DynamoRecord
  class << self
    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield(configuration)
    end

    def logger
      configuration.logger
    end
  end
end
