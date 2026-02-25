class User < ActiveRecord::Base
  def self.create_password
    SecureRandom.hex(8)
  end
end
