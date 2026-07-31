# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ActiveItem::Configuration do
  describe '#initialize' do
    it 'defaults table_prefix to ENV["APP_NAME"]' do
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with('APP_NAME', nil).and_return('myapp')
      config = ActiveItem::Configuration.new
      expect(config.table_prefix).to eq('myapp')
    end

    it 'defaults environment to ENV["ENVIRONMENT"]' do
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with('ENVIRONMENT', nil).and_return('prod')
      config = ActiveItem::Configuration.new
      expect(config.environment).to eq('prod')
    end

    it 'defaults to nil when ENV vars are not set' do
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with('APP_NAME', nil).and_return(nil)
      allow(ENV).to receive(:fetch).with('ENVIRONMENT', nil).and_return(nil)
      config = ActiveItem::Configuration.new
      expect(config.table_prefix).to be_nil
      expect(config.environment).to be_nil
    end
  end

  describe '#table_name_for' do
    it 'generates table name with prefix and environment' do
      config = ActiveItem::Configuration.new
      config.table_prefix = 'myapp'
      config.environment = 'prod'
      expect(config.table_name_for('BlogPost')).to eq('myapp-prod-blog-posts')
    end

    it 'generates table name without prefix' do
      config = ActiveItem::Configuration.new
      config.table_prefix = nil
      config.environment = 'dev'
      expect(config.table_name_for('User')).to eq('dev-users')
    end

    it 'generates table name with no config' do
      config = ActiveItem::Configuration.new
      config.table_prefix = nil
      config.environment = nil
      expect(config.table_name_for('InventoryItem')).to eq('inventory-items')
    end
  end
end
