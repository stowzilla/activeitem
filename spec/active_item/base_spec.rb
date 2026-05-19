# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ActiveItem::Base do
  let(:fake_dynamo) { @fake_dynamo }

  before do
    ActiveItem.configure do |config|
      config.table_prefix = 'test'
      config.environment = 'dev'
    end
  end

  # Define a test model
  let(:model_class) do
    Class.new(ActiveItem::Base) do
      self.table_name = 'test-dev-users'

      attr_accessor :email, :name, :status

      def self.name
        'User'
      end
    end.tap { |klass| klass.dynamodb = fake_dynamo }
  end

  describe '.table_name' do
    it 'uses explicit table name when set' do
      expect(model_class.table_name).to eq('test-dev-users')
    end

    it 'generates table name from configuration' do
      klass = Class.new(ActiveItem::Base) do
        def self.name
          'BlogPost'
        end
      end
      expect(klass.table_name).to eq('test-dev-blog-posts')
    end
  end

  describe '#new' do
    it 'assigns attributes from hash' do
      record = model_class.new(email: 'test@example.com', name: 'Test')
      expect(record.email).to eq('test@example.com')
      expect(record.name).to eq('Test')
    end

    it 'marks record as new' do
      record = model_class.new
      expect(record.new_record?).to be true
      expect(record.persisted?).to be false
    end
  end

  describe '#save (create)' do
    it 'generates a UUID primary key' do
      record = model_class.new(email: 'test@example.com')
      record.save
      expect(record.id).to match(/\A[0-9a-f-]{36}\z/)
    end

    it 'sets created_at timestamp' do
      record = model_class.new(email: 'test@example.com')
      record.save
      expect(record.created_at).not_to be_nil
    end

    it 'marks record as persisted after save' do
      record = model_class.new(email: 'test@example.com')
      record.save
      expect(record.persisted?).to be true
      expect(record.new_record?).to be false
    end

    it 'calls put_item on DynamoDB' do
      record = model_class.new(email: 'test@example.com', name: 'Alice')
      record.save
      expect(fake_dynamo.calls.last.first).to eq(:put_item)
      params = fake_dynamo.calls.last.last
      expect(params[:table_name]).to eq('test-dev-users')
      expect(params[:item]['email']).to eq('test@example.com')
    end

    it 'returns false when id already exists' do
      fake_dynamo.seed('test-dev-users', 'existing-id', { 'id' => 'existing-id' })
      record = model_class.new(email: 'test@example.com')
      record.id = 'existing-id'
      expect(record.save).to be false
      expect(record.errors[:id]).to include('already exists')
    end
  end

  describe '#save (update)' do
    let(:existing_record) do
      record = model_class.allocate
      record.instance_variable_set(:@id, 'user-1')
      record.instance_variable_set(:@email, 'old@example.com')
      record.instance_variable_set(:@new_record, false)
      record.instance_variable_set(:@pending_changes, {})
      record.instance_variable_set(:@previously_changed, {})
      record
    end

    it 'calls update_item with changed attributes' do
      existing_record.email = 'new@example.com'
      existing_record.save
      expect(fake_dynamo.calls.last.first).to eq(:update_item)
    end

    it 'does nothing when no changes' do
      existing_record.save
      expect(fake_dynamo.calls).to be_empty
    end
  end

  describe '#destroy' do
    it 'calls delete_item on DynamoDB' do
      record = model_class.new(email: 'test@example.com')
      record.save
      record.destroy
      expect(fake_dynamo.calls.last.first).to eq(:delete_item)
    end
  end

  describe '.find' do
    it 'returns instantiated record when found' do
      fake_dynamo.seed('test-dev-users', 'user-1', { 'id' => 'user-1', 'email' => 'found@example.com', 'name' => 'Found' })
      record = model_class.find('user-1')
      expect(record.id).to eq('user-1')
      expect(record.email).to eq('found@example.com')
      expect(record.persisted?).to be true
    end

    it 'raises RecordNotFound when not found' do
      expect { model_class.find('nonexistent') }.to raise_error(ActiveItem::RecordNotFound)
    end
  end

  describe '.batch_find' do
    it 'returns multiple records' do
      fake_dynamo.seed('test-dev-users', 'u1', { 'id' => 'u1', 'email' => 'a@b.com' })
      fake_dynamo.seed('test-dev-users', 'u2', { 'id' => 'u2', 'email' => 'c@d.com' })
      results = model_class.batch_find(['u1', 'u2'])
      expect(results.length).to eq(2)
    end

    it 'returns empty array for empty input' do
      expect(model_class.batch_find([])).to eq([])
    end
  end

  describe 'dirty tracking' do
    it 'tracks attribute changes' do
      record = model_class.new(email: 'old@example.com')
      record.instance_variable_set(:@new_record, false)
      record.instance_variable_set(:@pending_changes, {})
      record.email = 'new@example.com'
      expect(record.attribute_changed?(:email)).to be true
      expect(record.changes['email']).to eq(['old@example.com', 'new@example.com'])
    end

    it 'clears changes after save' do
      record = model_class.new(email: 'test@example.com')
      record.save
      expect(record.changes).to be_empty
    end
  end

  describe 'callbacks' do
    it 'runs before_create callbacks' do
      klass = Class.new(model_class) do
        before_create :set_default_status

        private

        def set_default_status
          self.status = 'active'
        end
      end
      klass.dynamodb = fake_dynamo
      klass.table_name = 'test-dev-users'

      record = klass.new(email: 'test@example.com')
      record.save
      expect(record.status).to eq('active')
    end
  end

  describe 'custom primary key' do
    let(:custom_pk_class) do
      Class.new(ActiveItem::Base) do
        self.table_name = 'test-dev-widgets'
        self.primary_key = :widget_id

        attr_accessor :name

        def self.name
          'Widget'
        end
      end.tap { |klass| klass.dynamodb = fake_dynamo }
    end

    it 'uses custom primary key for storage' do
      record = custom_pk_class.new(name: 'Sprocket')
      record.save
      params = fake_dynamo.calls.last.last
      expect(params[:item]).to have_key('widget_id')
      expect(record.widget_id).to eq(record.id)
    end
  end

  describe '.create!' do
    it 'creates and returns a persisted record' do
      record = model_class.create!(email: 'new@example.com')
      expect(record.persisted?).to be true
      expect(record.email).to eq('new@example.com')
    end
  end

  describe '#to_h' do
    it 'returns attributes as hash' do
      record = model_class.new(email: 'test@example.com', name: 'Test')
      record.instance_variable_set(:@id, 'abc')
      h = record.to_h
      expect(h['email']).to eq('test@example.com')
      expect(h['name']).to eq('Test')
      expect(h['id']).to eq('abc')
    end
  end
end
