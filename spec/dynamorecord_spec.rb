# frozen_string_literal: true

require_relative 'spec_helper'

RSpec.describe DynamoRecord do
  it 'has a version number' do
    expect(DynamoRecord::VERSION).to eq('0.0.1')
  end

  describe '.configure' do
    it 'yields configuration' do
      DynamoRecord.configure do |config|
        config.table_prefix = 'myapp'
        config.environment = 'test'
      end
      expect(DynamoRecord.configuration.table_prefix).to eq('myapp')
      expect(DynamoRecord.configuration.environment).to eq('test')
    end
  end

  describe '.logger' do
    it 'defaults to NullLogger' do
      config = DynamoRecord::Configuration.new
      expect(config.logger).to be_a(DynamoRecord::NullLogger)
    end
  end
end
