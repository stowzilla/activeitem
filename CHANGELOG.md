# Changelog

## 0.0.2

### Security

- **[Critical]** Pagination cursor validation — decoded JSON is now validated to only contain flat key/value pairs with alphanumeric keys and string/numeric values. Prevents partition traversal via crafted cursors.
- **[Critical]** Remove arbitrary file require from `model_loader.rb` — `safe_constantize_model` now uses `safe_constantize` with class name format validation instead of requiring files from disk.
- **[Medium]** Add jitter to exponential backoff in batch operations to prevent thundering herd.
- **[Low]** Replace `Object.const_get` with `safe_constantize` in `composed_of` to prevent constant hierarchy traversal.

### Fixed

- Fix `set_created_timestamp` callback not setting `@created_at`, causing DynamoDB `Invalid attribute value type` errors on create
- Fix duplicate `id=` method definition (Lint/DuplicateMethods) by using `attr_reader :id` with a custom setter
- Fix duplicate `last` method definition in QueryHelpers
- Fix duplicate branch in Relation `includes` case statement (Lint/DuplicateBranch)
- Use `Comparable#clamp` in Pagination and Relation (Style/ComparableClamp)

### Added

- Documentation comments for all public modules and classes (Style/Documentation)
- `--workdir` option to CI DynamoDB service for `act` compatibility

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
