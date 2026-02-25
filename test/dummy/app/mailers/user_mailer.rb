class UserMailer
  @@deliveries = []

  def self.new_user(user_id, token)
    @@deliveries << { user_id: user_id, token: token, type: :new_user }
    NullMailer.new
  end

  def self.deliveries
    @@deliveries
  end

  def self.clear_deliveries
    @@deliveries = []
  end
end

class NullMailer
  def deliver_later
    # No-op for testing
  end
end
