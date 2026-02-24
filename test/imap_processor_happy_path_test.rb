require 'test_helper'
require 'imap_processor'

class ImapProcessorHappyPathTest < ActiveSupport::TestCase
  def setup
    @forum = Forum.create!(name: 'Support')
    @existing_user = User.create!(email: 'existing@example.com', name: 'Existing User', password: 'password')

    AppSettings['settings.site_name'] = 'TestSite'
    AppSettings['settings.google_analytics_enabled'] = '0'
    AppSettings['cloudinary.enabled'] = '0'

    # Clear tracking for blackbox assertions
    UserMailer.clear_deliveries
    PostNotificationSubscriber.clear_notifications
  end

  def teardown
    AppSettings.clear
    UserMailer.clear_deliveries
    PostNotificationSubscriber.clear_notifications
  end

  # ============================================
  # ## Happy Path: New Topic Creation
  # ============================================

  test "new email creates topic and post" do
    topic_count_before = Topic.count
    post_count_before = Post.count
    notifications_before = PostNotificationSubscriber.notifications.count

    mail = Mail.new do
      from    'newuser@example.com'
      to      'support@example.com'
      subject 'I need help'
      body    'Please help me with this issue'
    end

    # Blackbox: process completes without error
    assert_nothing_raised do
      ImapProcessor.new(mail).process
    end

    # Blackbox: notification was sent
    assert_equal notifications_before + 1, PostNotificationSubscriber.notifications.count,
      "Notification should be sent for new post"

    # Greybox: verify database state
    assert_equal topic_count_before + 1, Topic.count, "Should create one topic"
    assert_equal post_count_before + 1, Post.count, "Should create one post"
  end

  test "new email from unknown address creates user" do
    user_count_before = User.count
    emails_before = UserMailer.deliveries.count

    mail = Mail.new do
      from    'brandnew@example.com'
      to      'support@example.com'
      subject 'First contact'
      body    'Hello'
    end

    # Blackbox: process completes without error
    assert_nothing_raised do
      ImapProcessor.new(mail).process
    end

    # Blackbox: welcome email was sent
    assert_equal emails_before + 1, UserMailer.deliveries.count,
      "Welcome email should be sent to new user"

    # Greybox: verify database state
    assert_equal user_count_before + 1, User.count, "Should create new user"
    assert User.find_by(email: 'brandnew@example.com'), "User should exist"
  end

  test "new email from existing user does not create duplicate user" do
    user_count_before = User.count
    emails_before = UserMailer.deliveries.count

    mail = Mail.new do
      from    'existing@example.com'
      to      'support@example.com'
      subject 'Another question'
      body    'Hello again'
    end

    # Blackbox: process completes without error
    assert_nothing_raised do
      ImapProcessor.new(mail).process
    end

    # Blackbox: no welcome email sent (user already exists)
    assert_equal emails_before, UserMailer.deliveries.count,
      "No welcome email should be sent for existing user"

    # Greybox: verify database state
    assert_equal user_count_before, User.count, "Should not create duplicate user"
  end

  test "email subject becomes topic name" do
    mail = Mail.new do
      from    'user@example.com'
      to      'support@example.com'
      subject 'Very specific problem description'
      body    'Details here'
    end

    ImapProcessor.new(mail).process

    topic = Topic.last
    assert_equal 'Very specific problem description', topic.name
  end

  test "email without subject uses default topic name" do
    mail = Mail.new do
      from    'user@example.com'
      to      'support@example.com'
      body    'No subject email'
    end
    mail.subject = nil

    ImapProcessor.new(mail).process

    topic = Topic.last
    assert_equal '(No Subject)', topic.name
  end

  # ============================================
  # ## Happy Path: Reply to Own Topic
  # ============================================

  test "owner can reply to their own topic" do
    # Create initial topic owned by existing_user
    topic = @forum.topics.create!(name: 'My ticket', user: @existing_user, private: true)
    initial_post = topic.posts.create!(body: 'Initial question', user: @existing_user, kind: 'first')

    posts_before = topic.posts.count
    notifications_before = PostNotificationSubscriber.notifications.count
    topic_id = topic.id

    mail = Mail.new do
      from    'existing@example.com'
      to      'support@example.com'
      subject "[TestSite]##{topic_id}-My ticket"
      body    'Here is my reply'
    end

    # Blackbox: process completes without error
    assert_nothing_raised do
      ImapProcessor.new(mail).process
    end

    # Blackbox: notification was sent for reply
    assert_equal notifications_before + 1, PostNotificationSubscriber.notifications.count,
      "Notification should be sent for reply"

    # Greybox: verify database state
    topic.reload
    assert_equal posts_before + 1, topic.posts.count, "Owner should be able to reply"
  end

  test "reply post has kind reply" do
    topic = @forum.topics.create!(name: 'My ticket', user: @existing_user, private: true)
    topic.posts.create!(body: 'Initial', user: @existing_user, kind: 'first')
    topic_id = topic.id

    mail = Mail.new do
      from    'existing@example.com'
      to      'support@example.com'
      subject "[TestSite]##{topic_id}-My ticket"
      body    'Reply content'
    end

    ImapProcessor.new(mail).process

    last_post = Post.last
    assert_equal 'reply', last_post.kind
  end

  test "reply is associated with correct topic" do
    topic = @forum.topics.create!(name: 'Target topic', user: @existing_user, private: true)
    topic.posts.create!(body: 'Initial', user: @existing_user, kind: 'first')
    topic_id = topic.id

    mail = Mail.new do
      from    'existing@example.com'
      to      'support@example.com'
      subject "[TestSite]##{topic_id}-Target topic"
      body    'Reply to specific topic'
    end

    ImapProcessor.new(mail).process

    last_post = Post.last
    assert_equal topic.id, last_post.topic_id
  end

  # ============================================
  # ## Happy Path: Forwarded Messages
  # ============================================

  test "forwarded email creates new topic" do
    topic_count_before = Topic.count
    notifications_before = PostNotificationSubscriber.notifications.count

    mail = Mail.new do
      from    'user@example.com'
      to      'support@example.com'
      subject 'Fwd: Customer complaint'
      body    'Forwarding this issue'
    end

    # Blackbox: process completes without error
    assert_nothing_raised do
      ImapProcessor.new(mail).process
    end

    # Blackbox: notification was sent
    assert_equal notifications_before + 1, PostNotificationSubscriber.notifications.count,
      "Notification should be sent for forwarded email"

    # Greybox: verify database state
    assert_equal topic_count_before + 1, Topic.count
    topic = Topic.last
    assert_equal 'Fwd: Customer complaint', topic.name
  end

  test "forwarded email topic is private" do
    mail = Mail.new do
      from    'user@example.com'
      to      'support@example.com'
      subject 'Fwd: Sensitive matter'
      body    'Please handle'
    end

    ImapProcessor.new(mail).process

    topic = Topic.last
    assert topic.private, "Forwarded topic should be private"
  end

  # ============================================
  # ## Happy Path: Team Routing
  # ============================================

  test "plus syntax routes to team" do
    notifications_before = PostNotificationSubscriber.notifications.count

    mail = Mail.new do
      from    'user@example.com'
      to      'support+sales@example.com'
      subject 'Sales question'
      body    'About pricing'
    end

    # Blackbox: process completes without error
    assert_nothing_raised do
      ImapProcessor.new(mail).process
    end

    # Blackbox: notification was sent
    assert_equal notifications_before + 1, PostNotificationSubscriber.notifications.count,
      "Notification should be sent for team-routed email"

    # Greybox: verify database state
    topic = Topic.last
    assert topic.persisted?
  end

  test "non-support address routes to team" do
    mail = Mail.new do
      from    'user@example.com'
      to      'billing@example.com'
      subject 'Billing question'
      body    'About my invoice'
    end

    ImapProcessor.new(mail).process

    topic = Topic.last
    assert topic.persisted?
  end

  test "support address creates topic without team routing" do
    mail = Mail.new do
      from    'user@example.com'
      to      'support@example.com'
      subject 'General question'
      body    'Hello'
    end

    ImapProcessor.new(mail).process

    topic = Topic.last
    assert topic.persisted?
  end

  # ============================================
  # ## Happy Path: Attachments
  # ============================================

  test "email with attachment is processed" do
    notifications_before = PostNotificationSubscriber.notifications.count

    mail = Mail.new do
      from    'user@example.com'
      to      'support@example.com'
      subject 'With attachment'
      body    'See attached'
    end
    mail.attachments['document.pdf'] = 'PDF content here'

    # Blackbox: process completes without error
    assert_nothing_raised do
      ImapProcessor.new(mail).process
    end

    # Blackbox: notification was sent
    assert_equal notifications_before + 1, PostNotificationSubscriber.notifications.count,
      "Notification should be sent for email with attachment"

    # Greybox: verify database state
    post = Post.last
    assert post.persisted?
  end

  test "email with multiple attachments is processed" do
    mail = Mail.new do
      from    'user@example.com'
      to      'support@example.com'
      subject 'Multiple attachments'
      body    'See attached files'
    end
    mail.attachments['file1.pdf'] = 'Content 1'
    mail.attachments['file2.jpg'] = 'Content 2'

    assert_nothing_raised do
      ImapProcessor.new(mail).process
    end

    post = Post.last
    assert post.persisted?
  end

  test "attachment-only email is processed successfully" do
    mail = Mail.new do
      from    'user@example.com'
      to      'support@example.com'
      subject 'Just files'
    end
    mail.attachments['file.pdf'] = 'Content'

    ImapProcessor.new(mail).process

    post = Post.last
    assert post.persisted?, "Post should be created even with attachment only"
  end

  # ============================================
  # ## Happy Path: CC Handling
  # ============================================

  test "CC is captured in post" do
    mail = Mail.new do
      from    'user@example.com'
      to      'support@example.com'
      cc      'manager@example.com'
      subject 'CC test'
      body    'With CC'
    end

    ImapProcessor.new(mail).process

    post = Post.last
    assert_equal 'manager@example.com', post.cc
  end

  test "multiple CC addresses are captured" do
    mail = Mail.new do
      from    'user@example.com'
      to      'support@example.com'
      cc      ['person1@example.com', 'person2@example.com']
      subject 'Multiple CC'
      body    'With multiple CC'
    end

    ImapProcessor.new(mail).process

    post = Post.last
    assert_equal 'person1@example.com,person2@example.com', post.cc
  end

  test "no CC results in nil cc field" do
    mail = Mail.new do
      from    'user@example.com'
      to      'support@example.com'
      subject 'No CC'
      body    'Without CC'
    end

    ImapProcessor.new(mail).process

    post = Post.last
    assert_nil post.cc
  end

  # ============================================
  # ## Happy Path: Email Content
  # ============================================

  test "plain text body is captured" do
    mail = Mail.new do
      from    'user@example.com'
      to      'support@example.com'
      subject 'Plain text'
      body    'This is the message body'
    end

    ImapProcessor.new(mail).process

    post = Post.last
    assert_equal 'This is the message body', post.body
  end

  test "raw email is stored" do
    mail = Mail.new do
      from    'user@example.com'
      to      'support@example.com'
      subject 'Raw test'
      body    'Raw content here'
    end

    ImapProcessor.new(mail).process

    post = Post.last
    assert post.raw_email.present?, "Raw email should be stored"
  end

  # ============================================
  # ## Happy Path: User Creation Details
  # ============================================

  test "display name is used for user name" do
    emails_before = UserMailer.deliveries.count

    mail = Mail.new do
      from    'John Doe <johndoe@example.com>'
      to      'support@example.com'
      subject 'Name test'
      body    'Hello'
    end

    # Blackbox: process completes without error
    assert_nothing_raised do
      ImapProcessor.new(mail).process
    end

    # Blackbox: welcome email was sent (new user)
    assert_equal emails_before + 1, UserMailer.deliveries.count,
      "Welcome email should be sent to new user"

    # Greybox: verify database state
    user = User.find_by(email: 'johndoe@example.com')
    assert_equal 'John Doe', user.name
  end

  test "email is used when no display name" do
    emails_before = UserMailer.deliveries.count

    mail = Mail.new do
      from    'nodisplay@example.com'
      to      'support@example.com'
      subject 'No name test'
      body    'Hello'
    end

    # Blackbox: process completes without error
    assert_nothing_raised do
      ImapProcessor.new(mail).process
    end

    # Blackbox: welcome email was sent (new user)
    assert_equal emails_before + 1, UserMailer.deliveries.count,
      "Welcome email should be sent to new user"

    # Greybox: verify database state
    user = User.find_by(email: 'nodisplay@example.com')
    # Name should be derived from email (alphanumeric only)
    assert user.name.present?
    assert_match(/nodisplayexamplecom/i, user.name)
  end

  test "email lookup is case insensitive" do
    # Create user with lowercase email
    User.create!(email: 'casetest@example.com', name: 'Case Test', password: 'password')
    user_count_before = User.count

    mail = Mail.new do
      from    'CASETEST@EXAMPLE.COM'
      to      'support@example.com'
      subject 'Case test'
      body    'Hello'
    end

    ImapProcessor.new(mail).process

    # Should find existing user despite case difference
    assert_equal user_count_before, User.count, "Should not create duplicate user"
  end

  # ============================================
  # ## Happy Path: Encoding
  # ============================================

  test "UTF-8 content is preserved" do
    mail = Mail.new do
      from    'user@example.com'
      to      'support@example.com'
      subject 'Unicode test'
      body    'Hello émoji: 👋'
    end

    ImapProcessor.new(mail).process

    post = Post.last
    assert post.body.include?('👋'), "Emoji should be preserved"
    assert post.body.include?('é'), "Accented characters should be preserved"
  end

  # ============================================
  # ## Happy Path: Forwarding Detection
  # ============================================

  test "Reply-To is used when FROM equals TO" do
    emails_before = UserMailer.deliveries.count
    notifications_before = PostNotificationSubscriber.notifications.count

    mail = Mail.new do
      from     'forwarder@example.com'
      to       'forwarder@example.com'
      reply_to 'original@example.com'
      subject  'Forwarded message'
      body     'Content'
    end

    # Blackbox: process completes without error
    assert_nothing_raised do
      ImapProcessor.new(mail).process
    end

    # Blackbox: welcome email was sent (new user from Reply-To)
    assert_equal emails_before + 1, UserMailer.deliveries.count,
      "Welcome email should be sent to new user from Reply-To"

    # Blackbox: notification was sent
    assert_equal notifications_before + 1, PostNotificationSubscriber.notifications.count,
      "Notification should be sent"

    # Greybox: verify database state
    user = User.find_by(email: 'original@example.com')
    assert user.present?, "User should be created from Reply-To address"
  end

  # ============================================
  # ## Happy Path: Invalid Email Rejection
  # ============================================

  test "invalid email format is rejected silently" do
    topic_count_before = Topic.count

    mail = Mail.new do
      from    'not-an-email'
      to      'support@example.com'
      subject 'Invalid sender'
      body    'Hello'
    end

    # Should not raise, just return early
    assert_nothing_raised do
      ImapProcessor.new(mail).process
    end

    assert_equal topic_count_before, Topic.count, "No topic should be created"
  end

  # ============================================
  # ## Happy Path: New Topic is Private
  # ============================================

  test "new topic is created as private" do
    mail = Mail.new do
      from    'user@example.com'
      to      'support@example.com'
      subject 'Private by default'
      body    'Hello'
    end

    ImapProcessor.new(mail).process

    topic = Topic.last
    assert topic.private, "New topics should be private by default"
  end

  # ============================================
  # ## Happy Path: First Post Kind
  # ============================================

  test "first post has kind first" do
    mail = Mail.new do
      from    'user@example.com'
      to      'support@example.com'
      subject 'New topic'
      body    'First message'
    end

    ImapProcessor.new(mail).process

    post = Post.last
    assert_equal 'first', post.kind
  end
end
