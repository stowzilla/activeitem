# frozen_string_literal: true

require 'active_support/inflector'

module ActiveItem
  module ModelLoader
    def safe_constantize_model(class_name)
      return class_name.constantize if Object.const_defined?(class_name)

      file_name = class_name.underscore
      # Try common model paths
      ['.', 'models', 'app/models'].each do |dir|
        path = File.join(dir, "#{file_name}.rb")
        if File.exist?(path)
          require path
          break
        end
      end

      class_name.constantize
    end
  end
end
