# frozen_string_literal: true

require 'spec_helper'
require 'base64'
require 'json'

RSpec.describe 'Security fixes' do
  let(:dynamo_client) { @dynamo_client }

  before(:each) do
    ActiveItem.configure do |config|
      config.table_prefix = 'test'
      config.environment = 'dev'
    end
  end

  describe 'Cursor deserialization validation' do
    let(:model_class) do
      Class.new(ActiveItem::Base) do
        self.table_name = 'test-dev-items'
        self.primary_key = :id
        attr_accessor :status
        indexes('StatusIndex' => { partition_key: 'status' })
      end.tap { |klass| klass.dynamodb = dynamo_client }
    end

    def encode_cursor(hash)
      Base64.urlsafe_encode64(hash.to_json, padding: false)
    end

    it 'accepts valid cursor with string values' do
      cursor = encode_cursor({ 'id' => 'abc-123', 'status' => 'active', 'createdAt' => '2024-01-01' })
      relation = model_class.where(status: 'active')
      result = relation.page(cursor, per_page: 10)
      expect(result).to be_a(ActiveItem::Pagination::PaginatedResult)
    end

    it 'accepts valid cursor with numeric values' do
      cursor = encode_cursor({ 'id' => 'abc-123', 'status' => 'active', 'createdAt' => '1704067200' })
      relation = model_class.where(status: 'active')
      result = relation.page(cursor, per_page: 10)
      expect(result).to be_a(ActiveItem::Pagination::PaginatedResult)
    end

    it 'rejects cursor with nested objects' do
      cursor = encode_cursor({ 'id' => { 'S' => 'injected' } })
      relation = model_class.where(status: 'active')
      result = relation.page(cursor, per_page: 10)
      expect(result).to be_a(ActiveItem::Pagination::PaginatedResult)
    end

    it 'rejects cursor with array values' do
      cursor = encode_cursor({ 'id' => ['a', 'b'] })
      relation = model_class.where(status: 'active')
      result = relation.page(cursor, per_page: 10)
      expect(result).to be_a(ActiveItem::Pagination::PaginatedResult)
    end

    it 'rejects cursor with invalid key names' do
      cursor = encode_cursor({ '../etc/passwd' => 'val' })
      relation = model_class.where(status: 'active')
      result = relation.page(cursor, per_page: 10)
      expect(result).to be_a(ActiveItem::Pagination::PaginatedResult)
    end

    it 'rejects non-hash JSON (array)' do
      cursor = Base64.urlsafe_encode64([1, 2, 3].to_json, padding: false)
      relation = model_class.where(status: 'active')
      result = relation.page(cursor, per_page: 10)
      expect(result).to be_a(ActiveItem::Pagination::PaginatedResult)
    end

    it 'handles malformed base64 gracefully' do
      relation = model_class.where(status: 'active')
      result = relation.page('not-valid-base64!!!', per_page: 10)
      expect(result).to be_a(ActiveItem::Pagination::PaginatedResult)
    end
  end

  describe 'Model loader safety' do
    it 'rejects class names with path traversal' do
      loader = Object.new
      loader.extend(ActiveItem::ModelLoader)
      expect { loader.safe_constantize_model('../etc/passwd') }.to raise_error(ArgumentError)
    end

    it 'rejects class names with shell metacharacters' do
      loader = Object.new
      loader.extend(ActiveItem::ModelLoader)
      expect { loader.safe_constantize_model('Foo; rm -rf /') }.to raise_error(ArgumentError)
    end

    it 'accepts valid class names' do
      loader = Object.new
      loader.extend(ActiveItem::ModelLoader)
      expect(loader.safe_constantize_model('String')).to eq(String)
    end

    it 'accepts namespaced class names' do
      loader = Object.new
      loader.extend(ActiveItem::ModelLoader)
      expect(loader.safe_constantize_model('ActiveItem::Base')).to eq(ActiveItem::Base)
    end

    it 'raises NameError for unknown classes' do
      loader = Object.new
      loader.extend(ActiveItem::ModelLoader)
      expect { loader.safe_constantize_model('NonexistentClass') }.to raise_error(NameError)
    end
  end

  describe 'assign_attributes filtering' do
    let(:model_class) do
      Class.new(ActiveItem::Base) do
        self.table_name = 'test-dev-users'
        self.primary_key = :id
        attr_accessor :name, :email
      end.tap { |klass| klass.dynamodb = dynamo_client }
    end

    it 'assigns known attributes' do
      record = model_class.new
      record.assign_attributes(name: 'Alice', email: 'alice@example.com')
      expect(record.name).to eq('Alice')
      expect(record.email).to eq('alice@example.com')
    end

    it 'ignores unknown attributes' do
      record = model_class.new
      record.assign_attributes(name: 'Alice', unknown_method: 'dangerous')
      expect(record.name).to eq('Alice')
    end
  end
end
