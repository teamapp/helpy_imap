class UserMailer
  def self.new_user(user_id, token)
    NullMailer.new
  end
end

class NullMailer
  def deliver_later
    # No-op for testing
  end
end
