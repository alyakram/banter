defmodule Banter.Accounts do
  use Ash.Domain, otp_app: :banter, extensions: [AshAdmin.Domain]

  admin do
    show? true
  end

  resources do
    resource Banter.Accounts.Token

    resource Banter.Accounts.User do
      # No `args: [:id]` here — :id is the record's primary key, not an
      # argument on :update_availability, so declaring it as one made every
      # call fail with NoSuchInput. Update interfaces already take the record
      # (or its id) as the first positional parameter.
      define :update_user_availability, action: :update_availability
    end
  end
end
