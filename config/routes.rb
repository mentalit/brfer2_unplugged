Rails.application.routes.draw do
  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  get "up" => "rails/health#show", as: :rails_health_check

  # Defines the root path route ("/")
  root "stores#index"

  resources :stores, shallow: true do
    
    resources :articles do

      collection do
        post :import
        get :totals
        get :non_srp_4
        get :search
        get :planned_basement

      end
    end
    resources :aisles, shallow: true do
      collection do
        post :import
      end
      resources :sections, shallow: true do
        collection do
          post   :plan_voss
          get    :export_voss
          post   :plan_pallet,   to: "pallet_plans#create"
          get    :export_pallet, to: "pallet_plans#export"
          post   :plan_aisle
          delete :unplan_aisle
          delete :unassign_article
        end
        resources :levels
      end
    end
  end
end