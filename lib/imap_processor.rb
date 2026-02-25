class ImapProcessor

  def initialize(email)
    @email = email
    @tracker = Staccato.tracker(AppSettings['settings.google_analytics_id']) if google_analytics_enabled?
  end

  def process

    # Guard clause to prevent ESPs like Sendgrid from posting over and over again
    # if the email presented is invalid and generates a 500.  Returns a 200
    # error as discussed on https://sendgrid.com/docs/API_Reference/Webhooks/parse.html
    # This error happened with invalid email addresses from PureChat
    return if get_email_from_mail.match(/\A[^@\s]+@([^@\s]+\.)+[^@\s]+\z/).blank?

    # scan users DB for sender email
    @user = User.where("lower(email) = ?", get_email_from_mail.downcase).first
    if @user.nil?
      create_user_from_email
    end
    sitename = AppSettings["settings.site_name"]
    message =  get_content_from_mail
    raw = raw_body_from_mail.nil? ? "" : raw_body_from_mail

    cc = @email.cc&.join ','

    subject = @email.subject || "(No Subject)"
    attachments = @email.attachments

    # Check for reply format: [SiteName]#123-Topic Name
    if subject =~ /\[#{Regexp.escape(sitename)}\]#(\d+)-/
      ticket_number = $1
      topic = Topic.find_by(id: ticket_number)

      # Validate topic exists and user owns it
      if topic.nil? || topic.user_id != @user.id
        return create_new_topic(subject, message, raw, cc)
      end

      #insert post to new topic
      message = "Attachments:" if @email.attachments.present? && @email.body.blank?
      post = topic.posts.create(
        :body => encode_entity(message),
        :raw_email => encode_entity(raw),
        :user_id => @user.id,
        :cc => cc,
        :kind => "reply"
      )

      # Send notification via the new controller-based pattern
      PostNotificationSubscriber.notify(post) if post.persisted?

      # Push array of attachments and send to Cloudinary
      handle_attachments(@email, post)

      if @tracker
        @tracker.event(category: "Email", action: "Inbound", label: "Reply", non_interactive: true)
        @tracker.event(category: "Agent: #{topic.assigned_user.name}", action: "User Replied by Email", label: topic.to_param) unless topic.assigned_user.nil?
      end
    elsif subject.include?("Fwd: ") # this is a forwarded message DOES NOT WORK CURRENTLY

      #parse_forwarded_message(message)
      topic = Forum.first.topics.create!(
        :name => subject,
        :user_id => @user.id,
        :private => true
      )

      #insert post to new topic
      message = "Attachments:" if @email.attachments.present? && @email.body.blank?
      post = topic.posts.create!(
        :body => encode_entity(message),
        :raw_email => encode_entity(raw),
        :user_id => @user.id,
        :cc => cc,
        kind: 'first'
      )

      # Send notification via the new controller-based pattern
      PostNotificationSubscriber.notify(post) if post.persisted?

      # Push array of attachments and send to Cloudinary
      handle_attachments(@email, post)

      # Call to GA
      if @tracker
        @tracker.event(category: "Email", action: "Inbound", label: "Forwarded New Topic", non_interactive: true)
        @tracker.event(category: "Agent: Unassigned", action: "Forwarded New", label: topic.to_param)
      end
    else # this is a new direct message
      create_new_topic(subject, message, raw, cc)
    end
  end

  def encode_entity(entity)
    return nil if entity.nil?
    return entity unless entity.respond_to?('encoding')

    case entity.encoding.name
    when "ASCII-8BIT"
      if entity.force_encoding("utf-8").valid_encoding?
        entity.force_encoding("utf-8")
      elsif entity.force_encoding("iso-8859-1").valid_encoding?
        entity.force_encoding("iso-8859-1").encode('utf-8', invalid: :replace, replace: '?')
      end
    when "UTF-8"
      entity.encode('utf-8', invalid: :replace, replace: '?')
    end
  end

  # Extracted method for creating new topics (used for fallback when reply parsing fails)
  def create_new_topic(subject, message, raw, cc)
    topic = Forum.first.topics.create(:name => subject, :user_id => @user.id, :private => true)

    if get_to_from_mail.include?("+")
      topic.team_list.add(get_to_from_mail.split('+')[1])
      topic.save
    elsif get_to_from_mail != 'support'
      topic.team_list.add(get_to_from_mail)
      topic.save
    end

    message = "Attachments:" if @email.attachments.present? && @email.body.blank?
    post = topic.posts.create(
      :body => encode_entity(message),
      :raw_email => encode_entity(raw),
      :user_id => @user.id,
      :cc => cc,
      :kind => "first"
    )

    PostNotificationSubscriber.notify(post) if post.persisted?
    handle_attachments(@email, post)

    if @tracker
      @tracker.event(category: "Email", action: "Inbound", label: "New Topic", non_interactive: true)
      @tracker.event(category: "Agent: Unassigned", action: "New", label: topic.to_param)
    end
  end

  # Fix #6: Redact email addresses in logs to protect PII
  def redact_email(email)
    return nil if email.nil?
    parts = email.split('@')
    return email if parts.length != 2
    prefix = parts[0].length > 3 ? parts[0][0..2] : parts[0][0]
    "#{prefix}***@#{parts[1]}"
  end

  # Convert Mail::Part attachments (filename, body.decoded, mime_type) to UploadedFile objects for CarrierWave
  # Fix #10: Track tempfiles and close them after processing
  def handle_attachments(email, post)
    return unless email.attachments.present?

    results = email.attachments.map do |attachment|
      convert_mail_attachment_to_uploaded_file(attachment)
    end.compact

    return if results.empty?

    uploaded_files = results.map { |r| r[:uploaded_file] }
    tempfiles = results.map { |r| r[:tempfile] }

    begin
      if cloudinary_enabled?
        post.screenshots = uploaded_files
      else
        post.attachments = uploaded_files
      end
      post.save
    ensure
      # Close all tempfiles to prevent resource leaks
      tempfiles.each { |tf| tf.close unless tf.closed? }
    end
  end

  def convert_mail_attachment_to_uploaded_file(attachment)
    extension = File.extname(attachment.filename)
    basename = File.basename(attachment.filename, extension)

    tempfile = Tempfile.new([basename, extension], binmode: true)
    tempfile.write(attachment.body.decoded)
    tempfile.rewind

    uploaded_file = ActionDispatch::Http::UploadedFile.new(
      filename: attachment.filename,
      type: attachment.mime_type,
      tempfile: tempfile
    )

    # Return both the uploaded file and tempfile for cleanup
    { uploaded_file: uploaded_file, tempfile: tempfile }
  end

  def cloudinary_enabled?
    AppSettings['cloudinary.enabled'] == '1' && AppSettings['cloudinary.cloud_name'].present? && AppSettings['cloudinary.api_key'].present? && AppSettings['cloudinary.api_secret'].present?
  end

  def google_analytics_enabled?
    AppSettings['settings.google_analytics_enabled'] == '1'
  end

  def create_user_from_email
    # create user
    @user = User.new

    @token, enc = Devise.token_generator.generate(User, :reset_password_token)
    @user.reset_password_token = enc
    @user.reset_password_sent_at = Time.now.utc


    @user.email = get_email_from_mail
    @user.name = get_name_from_mail.blank? ? get_email_from_mail.gsub(/[^a-zA-Z]/, '') : get_name_from_mail
    @user.password = User.create_password
    if @user.save
      UserMailer.new_user(@user.id, @token).deliver_later
    end

  end

  def get_name_from_mail
    from_address = @email[:from].addrs.first.address
    to_address = @email.to&.first

    # If forwarding detected, try to extract name from Reply-To
    if to_address.present? && from_address.downcase == to_address.downcase && @email.reply_to.present?
      # Get display name from Reply-To header
      reply_to_name = @email[:reply_to]&.addrs&.first&.display_name
      reply_to_name.present? ? reply_to_name : @email[:from].addrs.first.display_name
    else
      @email[:from].addrs.first.display_name
    end
  end

  def raw_body_from_mail
    if @email.multipart?
      @email.text_part ? @email.text_part.body.decoded : ""
    else
      @email.body.decoded
    end
  end

  def get_email_from_mail
    from_address = @email[:from].addrs.first.address
    to_address = @email.to&.first

    # If FROM and TO are the same (email forwarding loop), use Reply-To instead
    if to_address.present? && from_address.downcase == to_address.downcase && @email.reply_to.present?
      reply_to_address = @email[:reply_to]&.addrs&.first&.address
      Rails.logger.info "[ImapProcessor] Forwarding detected: FROM=#{redact_email(from_address)}, TO=#{redact_email(to_address)}, using REPLY-TO=#{redact_email(reply_to_address)}"
      reply_to_address
    else
      from_address
    end
  end

  def get_to_from_mail
    @email.to&.first&.split('@')&.first || 'support'
  end

  def get_content_from_mail
    @email.multipart? ? (@email.text_part ? @email.text_part.body.decoded : nil) : @email.body.decoded
  end

end
