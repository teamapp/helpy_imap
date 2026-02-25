class Post < ActiveRecord::Base
  belongs_to :topic
  belongs_to :user

  attr_accessor :screenshots, :attachments
end
