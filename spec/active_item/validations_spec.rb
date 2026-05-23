# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'ActiveItem Validations' do
  let(:dynamo_client) { @dynamo_client }

  let(:model_class) do
    Class.new(ActiveItem::Base) do
      self.table_name = "#{TABLE_PREFIX}-items"

      attr_accessor :name, :email, :age, :code

      validates :name, presence: true, length: { minimum: 2, maximum: 50 }
      validates :age, numericality: { greater_than: 0 }
      validates :email, format: { with: /\A[^@]+@[^@]+\z/, message: 'is invalid' }

      def self.name
        'Item'
      end
    end.tap { |klass| klass.dynamodb = dynamo_client }
  end

  it 'validates presence' do
    record = model_class.new(email: 'a@b.com', age: 5)
    expect(record.valid?).to be false
    expect(record.errors[:name]).to include("can't be blank")
  end

  it 'validates length minimum' do
    record = model_class.new(name: 'A', email: 'a@b.com', age: 5)
    expect(record.valid?).to be false
    expect(record.errors[:name].first).to include('too short')
  end

  it 'validates length maximum' do
    record = model_class.new(name: 'A' * 51, email: 'a@b.com', age: 5)
    expect(record.valid?).to be false
    expect(record.errors[:name].first).to include('too long')
  end

  it 'validates numericality' do
    record = model_class.new(name: 'Valid', email: 'a@b.com', age: -1)
    expect(record.valid?).to be false
    expect(record.errors[:age].first).to include('greater than')
  end

  it 'validates format' do
    record = model_class.new(name: 'Valid', email: 'not-an-email', age: 5)
    expect(record.valid?).to be false
    expect(record.errors[:email]).to include('is invalid')
  end

  it 'passes when all valid' do
    record = model_class.new(name: 'Valid', email: 'a@b.com', age: 5)
    expect(record.valid?).to be true
  end

  it 'prevents save when invalid' do
    record = model_class.new(email: 'a@b.com', age: 5)
    expect(record.save).to be false

    # Verify nothing was written
    scan = dynamo_client.scan(table_name: "#{TABLE_PREFIX}-items")
    expect(scan.items).to be_empty
  end
end
