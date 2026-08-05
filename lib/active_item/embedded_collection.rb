# frozen_string_literal: true

require 'securerandom'

module ActiveItem
  # In-memory collection for embedded model instances.
  # Provides Enumerable access plus ActiveItem-flavored query methods
  # (where, find, build, etc.) that operate on the already-loaded array.
  class EmbeddedCollection
    include Enumerable

    attr_reader :records, :association_name, :owner, :target_class

    def initialize(owner:, association_name:, target_class:, records: [])
      @owner = owner
      @association_name = association_name
      @target_class = target_class
      @records = records.dup
    end

    def each(&block)
      @records.each(&block)
    end

    def length
      @records.length
    end
    alias size length
    alias count length

    def empty?
      @records.empty?
    end

    def any?(&block)
      block ? @records.any?(&block) : @records.any?
    end

    def first
      @records.first
    end

    def last
      @records.last
    end

    def to_a
      @records.dup
    end

    # In-memory find by ID.
    def find(id)
      record = @records.find { |r| r.id == id }
      raise ActiveItem::RecordNotFound, "Couldn't find #{@target_class.name} with id '#{id}'" unless record

      record
    end

    # In-memory filtering by attribute conditions.
    # Returns a new EmbeddedCollection with matching records.
    def where(conditions = {})
      filtered = @records.select do |record|
        conditions.all? do |attr, value|
          record.send(attr) == value
        end
      end

      self.class.new(
        owner: @owner,
        association_name: @association_name,
        target_class: @target_class,
        records: filtered
      )
    end

    # Build a new embedded record, add it to the collection, and mark
    # the parent as dirty.
    def build(attributes = {})
      record = @target_class.new(attributes)
      record.instance_variable_set(:@id, SecureRandom.uuid) unless record.id
      record.instance_variable_set(:@_embedded_parent, @owner)
      @records << record
      mark_owner_dirty!
      record
    end

    # Build, validate, and persist by saving the parent.
    # Matches ActiveRecord semantics where create! actually persists.
    def create!(attributes = {})
      record = build(attributes)
      unless record.valid?
        @records.delete(record)
        mark_owner_dirty!
        raise ActiveItem::RecordInvalid.new(record)
      end

      @owner.save!
      record
    end

    # Remove a record from the collection by reference or ID.
    def delete(record_or_id)
      record = record_or_id.is_a?(String) ? find(record_or_id) : record_or_id
      @records.delete(record)
      mark_owner_dirty!
      record
    end
    alias destroy delete

    # Replace the entire collection.
    def replace(new_records)
      @records = new_records.dup
      mark_owner_dirty!
      self
    end

    def <<(record)
      record.instance_variable_set(:@_embedded_parent, @owner)
      @records << record
      mark_owner_dirty!
      self
    end
    alias push <<

    def inspect
      "#<#{self.class.name} [#{@records.map(&:inspect).join(', ')}]>"
    end

    private

    def mark_owner_dirty!
      attr_name = @association_name.to_s
      @owner.send("#{attr_name}_will_change!") if @owner.respond_to?("#{attr_name}_will_change!", true)
    end
  end
end
