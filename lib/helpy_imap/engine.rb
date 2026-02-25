require 'deface'
require 'mail'
require 'mailman'

module HelpyImap
  class Engine < ::Rails::Engine
    config.autoload_paths += %W(#{config.root}/lib)

    # Exclude overrides directory from Zeitwerk autoloading (Deface handles these)
    initializer 'helpy_imap.zeitwerk' do
      Rails.autoloaders.main.ignore(root.join('app', 'overrides'))
    end

    def self.activate
      cache_klasses = %W(#{config.root}/app/**/*_decorator*.rb #{config.root}/app/overrides/*.rb)
      Dir.glob(cache_klasses) do |klass|
        Rails.application.config.enable_reloading ? load(klass) : require(klass)
      end
    end

    initializer 'helpy_imap.assets' do |app|
      if app.config.respond_to?(:assets)
        app.config.assets.paths << root.join('assets', 'stylesheets', 'helpy_imap').to_s
        app.config.assets.paths << root.join('assets', 'javascripts', 'helpy_imap').to_s
        app.config.assets.precompile += %w( audits.scss )
      end
    end

    config.to_prepare(&method(:activate).to_proc)
  end
end
