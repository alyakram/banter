defmodule Banter.Accounts do
  use Ash.Domain, otp_app: :banter, extensions: [AshAdmin.Domain]

  admin do
    show? true
  end

  resources do
    resource Banter.Accounts.Token

    resource Banter.Accounts.User do
      define :update_user_availability, args: [:id], action: :update_availability
    end
  end
end
