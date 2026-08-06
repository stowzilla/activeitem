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

  # Raised when attempting to perform table-level operations on an embedded
  # model (one that has self.embedded = true and no DynamoDB table).
  class EmbeddedModelError < StandardError; end

  # Raised when a DynamoDB put/update fails because the item exceeds the
  # 400KB size limit — typically due to large embedded collections.
  class ItemTooLargeError < StandardError
    attr_reader :model_name, :table

    def initialize(model_name:, table:, original_error: nil)
      @model_name = model_name
      @table = table
      msg = "Item exceeds DynamoDB's 400KB limit when saving #{model_name} to #{table}. " \
            'The embedded collection(s) may have too many records. ' \
            'Consider reducing the number of embedded items or moving them to a separate table.'
      msg += " (Original: #{original_error.message})" if original_error
      super(msg)
    end
  end

  # Raised when a GSI key attribute has an invalid type.
  # DynamoDB GSI keys must be String, Number (Integer/Float/BigDecimal), or Binary (StringIO).
  class InvalidGsiKeyTypeError < StandardError
    attr_reader :model_name, :attribute, :index_name, :value, :value_type

    def initialize(model_name:, attribute:, index_name:, value:)
      @model_name = model_name
      @attribute = attribute
      @index_name = index_name
      @value = value
      @value_type = value.class.name
      super("#{model_name}##{attribute} has invalid type #{@value_type} for GSI '#{index_name}'. " \
            'GSI keys must be String, Numeric (Integer/Float/BigDecimal), or Binary (StringIO).')
    end
  end
end
