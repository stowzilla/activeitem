# frozen_string_literal: true

require 'spec_helper'

RSpec.describe DynamoRecord::Configuration do
  describe '#table_name_for' do
    it 'generates table name with prefix and environment' do
      config = DynamoRecord::Configuration.new
      config.table_prefix = 'myapp'
      config.environment = 'prod'
      expect(config.table_name_for('BlogPost')).to eq('myapp-prod-blog-posts')
    end

    it 'generates table name without prefix' do
      config = DynamoRecord::Configuration.new
      config.environment = 'dev'
      expect(config.table_name_for('User')).to eq('dev-users')
    end

    it 'generates table name with no config' do
      config = DynamoRecord::Configuration.new
      expect(config.table_name_for('InventoryItem')).to eq('inventory-items')
    end
  end
end
