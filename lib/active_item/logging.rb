# frozen_string_literal: true

module ActiveItem
  # Minimal logger that discards all output. Used as default when no logger configured.
  class NullLogger
    def info(*); end
    def warn(*); end
    def error(*); end
    def debug(*); end
  end

  # Provides a +dynamo_logger+ helper that delegates to the globally
  # configured ActiveItem logger.
  module Logging
    private

    def dynamo_logger
      ActiveItem.logger
    end
  end
end
