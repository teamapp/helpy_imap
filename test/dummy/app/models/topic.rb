class Topic < ActiveRecord::Base
  belongs_to :forum
  belongs_to :user
  belongs_to :assigned_user, class_name: 'User', optional: true
  has_many :posts

  def team_list
    @team_list ||= TeamList.new
  end

  def to_param
    id.to_s
  end
end

class TeamList
  def add(name); end
end
