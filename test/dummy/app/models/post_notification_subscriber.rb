class PostNotificationSubscriber
  @@notifications = []

  def self.notify(post)
    @@notifications << { post_id: post.id, topic_id: post.topic_id }
  end

  def self.notifications
    @@notifications
  end

  def self.clear_notifications
    @@notifications = []
  end
end
