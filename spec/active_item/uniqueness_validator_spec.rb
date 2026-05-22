# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'ActiveItem uniqueness validator' do
  let(:dynamo_client) { @dynamo_client }

  let(:model_class) do
    Class.new(ActiveItem::Base) do
      self.table_name = 'test-dev-users'
      attr_accessor :email, :name, :org_id

      validates :email, uniqueness: true

      def self.name
        'User'
      end
    end.tap { |klass| klass.dynamodb = dynamo_client }
  end

  it 'passes when no duplicate exists' do
    record = model_class.new(email: 'unique@example.com', name: 'Alice')
    expect(record.valid?).to be true
  end

  it 'fails when duplicate exists' do
    model_class.create!(email: 'taken@example.com', name: 'First')

    record = model_class.new(email: 'taken@example.com', name: 'Bob')
    expect(record.valid?).to be false
    expect(record.errors[:email]).to include('has already been taken')
  end

  it 'allows the same record to pass (excludes self by ID)' do
    existing = model_class.create!(email: 'mine@example.com', name: 'Me')

    # Reload to simulate a persisted record
    record = model_class.find(existing.id)
    expect(record.valid?).to be true
  end

  it 'skips validation when value is nil' do
    record = model_class.new(email: nil, name: 'Alice')
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
      end.tap { |klass| klass.dynamodb = dynamo_client }
    end

    it 'fails when same email exists in same scope' do
      scoped_model.create!(email: 'shared@example.com', org_id: 'org-1', name: 'First')

      record = scoped_model.new(email: 'shared@example.com', org_id: 'org-1')
      expect(record.valid?).to be false
      expect(record.errors[:email]).to include('has already been taken')
    end
  end
end
