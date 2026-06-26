# frozen_string_literal: true

require_relative 'lib/active_item/version'

Gem::Specification.new do |spec|
  spec.name          = 'activeitem'
  spec.version       = ActiveItem::VERSION
  spec.authors       = ['Andy Davis', 'Adam Dalton']
  spec.email         = ['andy@stowzilla.com', 'adam@stowzilla.com']

  spec.summary       = 'ActiveRecord-like ORM for AWS DynamoDB'
  spec.description   = 'A Rails-inspired ORM for DynamoDB with query builder, associations, callbacks, dirty tracking, validations, transactions, and pagination.'
  spec.homepage      = 'https://github.com/stowzilla/activeitem'
  spec.license       = 'MIT'
  spec.required_ruby_version = '>= 3.2'

  spec.metadata['homepage_uri'] = spec.homepage
  spec.metadata['source_code_uri'] = 'https://github.com/stowzilla/activeitem/tree/master'
  spec.metadata['changelog_uri'] = 'https://github.com/stowzilla/activeitem/blob/main/CHANGELOG.md'
  spec.metadata['rubygems_mfa_required'] = 'true'

  spec.files = Dir['lib/**/*', 'LICENSE.txt', 'README.md', 'CHANGELOG.md']
  spec.require_paths = ['lib']

  spec.add_dependency 'activemodel', '>= 7.0'
  spec.add_dependency 'activesupport', '>= 7.0'
  spec.add_dependency 'aws-sdk-dynamodb', '~> 1.0'

  spec.add_development_dependency 'ostruct'
  spec.add_development_dependency 'parallel_tests', '~> 5.0'
  spec.add_development_dependency 'rake', '~> 13.0'
  spec.add_development_dependency 'rspec', '~> 3.12'
  spec.add_development_dependency 'rubocop', '~> 1.0'
end
