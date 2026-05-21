# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'ActiveItem uniqueness validator' do
  let(:fake_dynamo) { @fake_dynamo }

  let(:model_class) do
    Class.new(ActiveItem::Base) do
      self.table_name = 'test-dev-users'
      attr_accessor :email, :name, :org_id

      validates :email, uniqueness: true

      def self.name
        'User'
      end
    end.tap { |klass| klass.dynamodb = fake_dynamo }
  end

  it 'passes when no duplicate exists' do
    record = model_class.new(email: 'unique@example.com', name: 'Alice')
    expect(record.valid?).to be true
  end

  it 'fails when duplicate exists' do
    fake_dynamo.seed('test-dev-users', 'u1', { 'id' => 'u1', 'email' => 'taken@example.com' })

    record = model_class.new(email: 'taken@example.com', name: 'Bob')
    expect(record.valid?).to be false
    expect(record.errors[:email]).to include('has already been taken')
  end

  it 'allows the same record to pass (excludes self by ID)' do
    fake_dynamo.seed('test-dev-users', 'u1', { 'id' => 'u1', 'email' => 'mine@example.com' })

    record = model_class.allocate
    record.instance_variable_set(:@id, 'u1')
    record.instance_variable_set(:@email, 'mine@example.com')
    record.instance_variable_set(:@new_record, false)
    record.instance_variable_set(:@pending_changes, {})
    record.instance_variable_set(:@previously_changed, {})

    expect(record.valid?).to be true
  end

  it 'skips validation when value is nil' do
    record = model_class.new(email: nil, name: 'Alice')
    # Should not fail on uniqueness (may fail on other validations)
    record.valid?
    expect(record.errors[:email]).not_to include('has already been taken')
  end

  describe 'with scope' do
    let(:scoped_model) do
      Class.new(ActiveItem::Base) do
        self.table_name = 'test-dev-scoped-users'
        attr_accessor :email, :name, :org_id

        validates :email, uniqueness: { scope: :org_id }

        def self.name
          'ScopedUser'
        end
      end.tap { |klass| klass.dynamodb = fake_dynamo }
    end

    it 'fails when same email exists in same scope' do
      fake_dynamo.seed('test-dev-scoped-users', 'u1', { 'id' => 'u1', 'email' => 'shared@example.com', 'orgId' => 'org-1' })

      record = scoped_model.new(email: 'shared@example.com', org_id: 'org-1')
      expect(record.valid?).to be false
      expect(record.errors[:email]).to include('has already been taken')
    end
  end
end
