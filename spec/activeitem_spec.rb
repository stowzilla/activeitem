# frozen_string_literal: true

require_relative 'spec_helper'

RSpec.describe ActiveItem do
  it 'has a version number' do
    expect(ActiveItem::VERSION).to eq('0.0.2')
  end

  describe '.configure' do
    it 'yields configuration' do
      ActiveItem.configure do |config|
        config.table_prefix = 'myapp'
        config.environment = 'test'
      end
      expect(ActiveItem.configuration.table_prefix).to eq('myapp')
      expect(ActiveItem.configuration.environment).to eq('test')
    end
  end

  describe '.logger' do
    it 'defaults to NullLogger' do
      config = ActiveItem::Configuration.new
      expect(config.logger).to be_a(ActiveItem::NullLogger)
    end
  end
end
