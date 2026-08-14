module ApplicationCable
  # Connections are deliberately anonymous.
  #
  # There is no single identity to attach here: the KDS authenticates with a
  # station token and the customer board is public. Authorization therefore
  # happens per-channel at subscribe time, where the token can be checked
  # against the store the subscription actually names (§13.3).
  class Connection < ActionCable::Connection::Base
    # `request` is private on ActionCable::Connection::Base — callable here via
    # implicit self, not from a channel's `connection.request`.
    #
    # @return [String]
    def remote_ip
      request.remote_ip
    end
  end
end
