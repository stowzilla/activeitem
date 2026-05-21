# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'ActiveItem callback :on option' do
  let(:fake_dynamo) { @fake_dynamo }

  let(:model_class) do
    Class.new(ActiveItem::Base) do
      self.table_name = 'test-dev-things'
      attr_accessor :name, :audit_log

      before_save :log_create, on: :create
      before_save :log_update, on: :update

      def self.name
        'Thing'
      end

      private

      def log_create
        self.audit_log = 'created'
      end

      def log_update
        self.audit_log = 'updated'
      end
    end.tap { |klass| klass.dynamodb = fake_dynamo }
  end

  it 'runs before_save on: :create only during creation' do
    record = model_class.new(name: 'Test')
    record.save
    expect(record.audit_log).to eq('created')
  end

  it 'runs before_save on: :update only during update' do
    record = model_class.new(name: 'Test')
    record.save
    record.audit_log = nil

    record.name = 'Updated'
    record.save
    expect(record.audit_log).to eq('updated')
  end

  it 'does not run on: :update callback during create' do
    update_ran = false
    klass = Class.new(ActiveItem::Base) do
      self.table_name = 'test-dev-things'
      attr_accessor :name

      before_save :check_update, on: :update

      def self.name
        'Thing2'
      end

      private

      def check_update
        # Should not run on create
      end
    end
    klass.dynamodb = fake_dynamo

    allow_any_instance_of(klass).to receive(:check_update) { update_ran = true }

    record = klass.new(name: 'Test')
    record.save
    expect(update_ran).to be false
  end

  describe 'after_save with :on option' do
    let(:after_model) do
      Class.new(ActiveItem::Base) do
        self.table_name = 'test-dev-things'
        attr_accessor :name, :hook_result

        after_save :after_create_hook, on: :create
        after_save :after_update_hook, on: :update

        def self.name
          'AfterThing'
        end

        private

        def after_create_hook
          self.hook_result = 'after_create'
        end

        def after_update_hook
          self.hook_result = 'after_update'
        end
      end.tap { |klass| klass.dynamodb = fake_dynamo }
    end

    it 'runs after_save on: :create after creation' do
      record = after_model.new(name: 'Test')
      record.save
      expect(record.hook_result).to eq('after_create')
    end

    it 'runs after_save on: :update after update' do
      record = after_model.new(name: 'Test')
      record.save
      record.hook_result = nil

      record.name = 'Changed'
      record.save
      expect(record.hook_result).to eq('after_update')
    end
  end
end
