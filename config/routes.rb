Rails.application.routes.draw do
  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  get "up" => "rails/health#show", as: :rails_health_check

  # Defines the root path route ("/")
  root "stores#index"

  resources :stores, shallow: true do
    resources :articles do
      collection do
        post :import
      end
    end
    resources :aisles, shallow: true do
      collection do
        post :import
      end
      resources :sections, shallow: true do
        resources :levels
      end
    end
  end
end