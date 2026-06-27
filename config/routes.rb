Rails.application.routes.draw do
  root "documents#index"

  post "rename", to: "documents#rename"
  get  "status", to: "documents#status"
  get  "download/:id", to: "documents#download", as: :download
  post "download_all", to: "documents#download_all"

  # Reveal health status on /up that returns 200 if the app boots with no exceptions.
  get "up" => "rails/health#show", as: :rails_health_check
end
