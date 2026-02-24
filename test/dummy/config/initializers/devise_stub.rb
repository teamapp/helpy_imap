module Devise
  def self.token_generator
    TokenGenerator.new
  end

  class TokenGenerator
    def generate(klass, attr)
      ['token', 'encrypted_token']
    end
  end
end
