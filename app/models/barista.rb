# A worker. Authenticates to the KDS with a PIN, exchanged for a station token
# (§13.3). The PIN is bcrypt-digested and never stored or logged in the clear.
class Barista < ApplicationRecord
  has_secure_password :pin, validations: false

  belongs_to :store
  has_many :order_items, dependent: :nullify

  validates :name, presence: true
end
