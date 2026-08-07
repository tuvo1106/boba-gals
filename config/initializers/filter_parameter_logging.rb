# Be sure to restart your server when you modify this file.

# Configure parameters to be partially matched (e.g. passw matches password) and filtered from the log file.
# Use this to limit dissemination of sensitive information.
# See the ActiveSupport::ParameterFilter documentation for supported notations and behaviors.
Rails.application.config.filter_parameters += [
  :passw, :email, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn, :cvv, :cvc,

  # DESIGN.md §13.5: customer_phone is collected for the one SMS on ready (§9.7)
  # and must never appear in logs, API responses, or any broadcast payload. This
  # covers logs; spec/config/data_hygiene_spec.rb holds the line on the rest.
  :customer_phone
]
