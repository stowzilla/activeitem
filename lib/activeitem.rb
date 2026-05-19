# frozen_string_literal: true

require_relative 'active_item/version'
require_relative 'active_item/configuration'
require_relative 'active_item/logging'
require_relative 'active_item/errors'
require_relative 'active_item/database_helpers'
require_relative 'active_item/query_helpers'
require_relative 'active_item/relation'
require_relative 'active_item/associations'
require_relative 'active_item/composed_of'
require_relative 'active_item/validations'
require_relative 'active_item/transaction'
require_relative 'active_item/pagination'
require_relative 'active_item/base'

module ActiveItem
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
