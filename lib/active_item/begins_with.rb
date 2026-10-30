# frozen_string_literal: true

module ActiveItem
  # A prefix match for `where`, built with ActiveItem.begins_with.
  #
  # On an index's sort key it becomes part of the key condition, so DynamoDB
  # reads only the matching items. On any other attribute it is a filter.
  #
  # @example Prefix search on a GSI (partition = first letters, sort = whole name)
  #   Username.where(search_prefix: 'ab', search_name: ActiveItem.begins_with('abc')).limit(10)
  BeginsWith = Data.define(:prefix) do
    def initialize(prefix:)
      raise ArgumentError, 'begins_with needs a non-empty prefix' if prefix.to_s.empty?

      super(prefix: prefix.to_s)
    end
  end
end
