# Changelog

## 0.0.1

- Initial release
- Core ORM: find, save, create, update, destroy
- Chainable query builder (Relation) with where, not, limit, order, select
- Associations: has_many, belongs_to with dependent options
- Callbacks: before/after save, create, update, destroy, validation
- Dirty tracking: attribute_changed?, changes, previous_changes
- Validations: uniqueness, length, numericality, format (via ActiveModel)
- Transactions: TransactWriteItems and TransactGetItems
- Pagination: cursor-based with PaginatedResult
- Composed of: value object aggregation
- Batch operations: batch_find, batch_write
- Configurable table naming, logger, and DynamoDB client
