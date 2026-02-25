class AppSettings
  @@settings = {}

  def self.[](key)
    @@settings[key]
  end

  def self.[]=(key, value)
    @@settings[key] = value
  end

  def self.clear
    @@settings = {}
  end
end
