# frozen_string_literal: true

require 'spec_helper'

class Address
  attr_accessor :street, :city, :state, :zip_code

  def initialize(street: nil, city: nil, state: nil, zip_code: nil)
    @street = street
    @city = city
    @state = state
    @zip_code = zip_code
  end

  def to_h
    { street: street, city: city, state: state, zip_code: zip_code }.compact
  end

  def ==(other)
    other.is_a?(Address) && street == other.street && city == other.city &&
      state == other.state && zip_code == other.zip_code
  end
end

RSpec.describe ActiveItem::ComposedOf do
  let(:fake_dynamo) { @fake_dynamo }

  let(:model_class) do
    Class.new(ActiveItem::Base) do
      self.table_name = 'test-dev-customers'
      attr_accessor :name, :street, :city, :state, :zip_code

      composed_of :address, class_name: 'Address', mapping: {
        street: :street, city: :city, state: :state, zip_code: :zip_code
      }

      def self.name
        'Customer'
      end
    end.tap { |klass| klass.dynamodb = fake_dynamo }
  end

  describe 'reader' do
    it 'builds value object from attributes' do
      record = model_class.new(name: 'Alice', street: '123 Main', city: 'Orlando', state: 'FL', zip_code: '32801')
      address = record.address

      expect(address).to be_a(Address)
      expect(address.street).to eq('123 Main')
      expect(address.city).to eq('Orlando')
    end

    it 'returns nil when all attributes are nil' do
      record = model_class.new(name: 'Alice')
      expect(record.address).to be_nil
    end
  end

  describe 'writer' do
    it 'assigns value object and sets model attributes' do
      record = model_class.new(name: 'Alice')
      record.address = Address.new(street: '456 Oak', city: 'Tampa', state: 'FL', zip_code: '33601')

      expect(record.street).to eq('456 Oak')
      expect(record.city).to eq('Tampa')
    end

    it 'accepts a hash' do
      record = model_class.new(name: 'Alice')
      record.address = { street: '789 Pine', city: 'Miami', state: 'FL', zip_code: '33101' }

      expect(record.street).to eq('789 Pine')
      expect(record.address).to be_a(Address)
    end

    it 'clears attributes when assigned nil' do
      record = model_class.new(name: 'Alice', street: '123 Main', city: 'Orlando')
      record.address = nil

      expect(record.street).to be_nil
      expect(record.city).to be_nil
    end

    it 'raises on invalid type' do
      record = model_class.new(name: 'Alice')
      expect { record.address = 42 }.to raise_error(ArgumentError)
    end
  end

  describe 'persistence' do
    it 'stores composed value as nested map in DynamoDB' do
      record = model_class.new(name: 'Alice', street: '123 Main', city: 'Orlando', state: 'FL', zip_code: '32801')
      record.save

      put_call = fake_dynamo.calls.find { |c| c.first == :put_item }
      item = put_call.last[:item]

      # Flat keys should be removed, nested map should exist
      expect(item).not_to have_key('street')
      expect(item).not_to have_key('city')
      expect(item['address']).to be_a(Hash)
      expect(item['address']['street']).to eq('123 Main')
    end

    it 'populates composed attributes from DynamoDB item' do
      fake_dynamo.seed('test-dev-customers', 'c1', {
        'id' => 'c1', 'name' => 'Bob',
        'address' => { 'street' => '999 Elm', 'city' => 'Jax', 'state' => 'FL', 'zipCode' => '32099' }
      })

      record = model_class.find('c1')
      expect(record.address).to be_a(Address)
      expect(record.street).to eq('999 Elm')
      expect(record.city).to eq('Jax')
    end
  end
end
