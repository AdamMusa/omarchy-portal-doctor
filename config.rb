# frozen_string_literal: true

OmarchyUI.configure do
  type :plugin
  id "izeesoft.portal-doctor"
  name "Portal Doctor"
  slug "portal-doctor"
  version "0.1.0"
  author "Adam Moussa Ali"
  license "MIT"
  description "Read-only XDG desktop portal health and backend routing inspector for Wayland sessions."
  entrypoint "main.rb"

  bar_widget do
    display_name "Portal Doctor"
    description "See which desktop portal actually handles screenshots, sharing, and file dialogs."
    category "System"
    default_section :right
  end
end
