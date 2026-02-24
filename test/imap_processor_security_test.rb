require 'test_helper'
require 'imap_processor'

class ImapProcessorSecurityTest < ActiveSupport::TestCase
  def setup
    @forum = Forum.create!(name: 'Support')
    @owner = User.create!(email: 'owner@example.com', name: 'Owner', password: 'password')
    @attacker = User.create!(email: 'attacker@example.com', name: 'Attacker', password: 'password')
    @topic = @forum.topics.create!(name: 'Private Ticket', user: @owner, private: true)

    AppSettings['settings.site_name'] = 'TestSite'
    AppSettings['settings.google_analytics_enabled'] = '0'
  end

  def teardown
    AppSettings.clear
  end

  # ============================================
  # #1 Topic Authorization (Blackbox)
  # ============================================

  test "attacker cannot post to another user's topic via crafted subject" do
    # Before: topic has no posts
    assert_equal 0, @topic.posts.count

    topic_id = @topic.id
    mail = Mail.new do
      from    'attacker@example.com'
      to      'support@example.com'
      subject "[TestSite]##{topic_id}-Malicious Reply"
      body    'I should not be able to post here'
    end

    processor = ImapProcessor.new(mail)
    processor.process

    # After: post should NOT be created on the private topic
    # (either rejected, or new topic created instead)
    @topic.reload
    assert_equal 0, @topic.posts.count, "Attacker should not be able to post on another user's topic"
  end

  # ============================================
  # #2 String Splitting Crash (Blackbox)
  # ============================================

  test "malformed subject with sitename but nothing after does not crash" do
    mail = Mail.new do
      from    'user@example.com'
      to      'support@example.com'
      subject '[TestSite]'
      body    'Test body'
    end

    assert_nothing_raised do
      ImapProcessor.new(mail).process
    end
  end

  test "malformed subject with sitename but no hash does not crash" do
    mail = Mail.new do
      from    'user@example.com'
      to      'support@example.com'
      subject '[TestSite]no-hash-here'
      body    'Test body'
    end

    assert_nothing_raised do
      ImapProcessor.new(mail).process
    end
  end

  test "malformed subject with sitename and hash but no number does not crash" do
    mail = Mail.new do
      from    'user@example.com'
      to      'support@example.com'
      subject '[TestSite]#-missing-number'
      body    'Test body'
    end

    assert_nothing_raised do
      ImapProcessor.new(mail).process
    end
  end

  # ============================================
  # #6 PII in Logs (Greybox)
  # ============================================

  test "email addresses are redacted in logs" do
    log_output = StringIO.new
    original_logger = Rails.logger
    Rails.logger = Logger.new(log_output)

    mail = Mail.new do
      from     'sensitive@example.com'
      to       'sensitive@example.com'
      reply_to 'reply@example.com'
      subject  'Test'
      body     'Test body'
    end

    ImapProcessor.new(mail).process

    Rails.logger = original_logger
    log_content = log_output.string

    # Should not contain full email addresses
    refute_match(/sensitive@example\.com/, log_content, "Full email should be redacted")
    refute_match(/reply@example\.com/, log_content, "Reply-to email should be redacted")
  end

  # ============================================
  # #10 Tempfile Cleanup (Greybox)
  # ============================================

  test "tempfiles are closed after attachment processing" do
    mail = Mail.new do
      from    'user@example.com'
      to      'support@example.com'
      subject 'Email with attachment'
      body    'See attached'
    end
    mail.attachments['test.txt'] = 'Test content'

    processor = ImapProcessor.new(mail)

    # Track tempfiles created
    tempfiles_created = []
    original_new = Tempfile.method(:new)
    Tempfile.define_singleton_method(:new) do |*args, **kwargs|
      tf = original_new.call(*args, **kwargs)
      tempfiles_created << tf
      tf
    end

    processor.process

    # Restore original method
    Tempfile.define_singleton_method(:new, original_new)

    # All tempfiles should be closed
    tempfiles_created.each do |tf|
      assert tf.closed?, "Tempfile #{tf.path} should be closed"
    end
  end
end
