# frozen_string_literal: true

require "uri"

class IsbfLearningCollectionFormUrlValidator
  def initialize(_options = nil)
  end

  def valid_value?(value)
    uri = URI.parse(value)
    uri.is_a?(URI::HTTP) && uri.host.present?
  rescue URI::InvalidURIError, TypeError
    false
  end

  def error_message
    I18n.t("isbf_learning.invalid_collection_form_url")
  end
end
