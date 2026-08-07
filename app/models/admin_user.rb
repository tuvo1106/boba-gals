# Dashboard and config auth (§13.4). One user, no roles, no signup — created by
# seed or console. Exists from the first deploy because PATCH
# /admin/scheduler_config changes live scheduler behavior and must never be open.
class AdminUser < ApplicationRecord
  has_secure_password

  validates :email, presence: true, uniqueness: { case_sensitive: false }

  normalizes :email, with: ->(email) { email.strip.downcase }
end
