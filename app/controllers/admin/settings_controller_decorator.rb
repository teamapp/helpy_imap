module Admin
  module SettingsControllerDecorator
    # This decorator extends Admin::SettingsController from the main Helpy app
    # It's loaded via config.to_prepare in the engine
  end
end

# Apply the decorator if the controller exists
if defined?(Admin::SettingsController)
  Admin::SettingsController.include(Admin::SettingsControllerDecorator)
end
