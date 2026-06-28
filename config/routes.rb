Rails.application.routes.draw do
  root "documents#index"

  post "rename", to: "documents#rename"
  post "rename/:batch_id/start", to: "documents#start", as: :rename_start
  get  "rename/:batch_id/status", to: "documents#rename_status", as: :rename_status
  get  "status", to: "documents#status"
  get  "download/:id", to: "documents#download", as: :download
  post "download_all/:batch_id", to: "documents#download_all", as: :download_all

  # Reveal health status on /up that returns 200 if the app boots with no exceptions.
  get "up" => "rails/health#show", as: :rails_health_check
  mount GoodJob::Engine => 'good_job'
end
