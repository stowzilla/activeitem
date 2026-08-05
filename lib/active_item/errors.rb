# frozen_string_literal: true

module ActiveItem
  class RecordNotFound < StandardError; end
  class TransactionError < StandardError; end

  # Raised by save! when validations fail.
  class RecordInvalid < StandardError
    attr_reader :record

    def initialize(record = nil)
      @record = record
      message = record ? "Validation failed: #{record.errors.full_messages.join(', ')}" : 'Validation failed'
      super(message)
    end
  end

  # Raised when an IAM policy denies a DynamoDB operation on a table.
  class AccessDeniedError < StandardError
    attr_reader :model_name, :table, :operation, :original_error

    def initialize(model_name:, table:, operation:, original_error:)
      @model_name = model_name
      @table = table
      @operation = operation
      @original_error = original_error
      super("#{model_name} is not allowed to #{operation} on #{table}. " \
            'Ensure the IAM role has access to this table.')
    end
  end

  # Raised when batch_write fails to write all items after retries.
  class BatchWriteError < StandardError
    attr_reader :model_name, :table, :failed_count, :total_count

    def initialize(model_name:, table:, failed_count:, total_count:)
      @model_name = model_name
      @table = table
      @failed_count = failed_count
      @total_count = total_count
      super("#{model_name} batch_write failed: #{failed_count} of #{total_count} items could not be written to #{table} after retries (DynamoDB throughput exceeded).")
    end
  end

  # Raised by destroy! when the record is not destroyed.
  class RecordNotDestroyed < StandardError
    attr_reader :record

    def initialize(message = nil, record = nil)
      @record = record
      super(message || 'Failed to destroy the record')
    end
  end

  # Raised when a record cannot be deleted because dependent associations
  # with :restrict_with_exception still exist.
  class DeleteRestrictionError < StandardError
    attr_reader :association_name

    def initialize(association_name)
      @association_name = association_name
      super("Cannot delete record because dependent #{association_name} exist")
    end
  end
end
