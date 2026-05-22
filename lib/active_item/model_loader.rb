# frozen_string_literal: true

require 'active_support/inflector'

module ActiveItem
  # Utility for resolving association class names to constants, attempting
  # common model file paths when the constant is not yet loaded.
  module ModelLoader
    def safe_constantize_model(class_name)
      raise ArgumentError, "Invalid class name: #{class_name}" unless class_name.match?(/\A[A-Z][A-Za-z0-9]*(::[A-Z][A-Za-z0-9]*)*\z/)

      class_name.safe_constantize || raise(NameError, "Unknown model: #{class_name}")
    end
  end
end
