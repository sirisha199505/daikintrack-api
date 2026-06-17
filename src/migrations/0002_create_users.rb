Sequel.migration do
  change do
    create_table(:users) do
      primary_key :id

      String :full_name
      String :username, size: 60
      String :email, size: 100
      String :encoded_password, size: 200

      Integer :client_id

      # Role: 1 = admin, 2 = store_manager, 3 = distributor
      Integer :role, default: 3

      Integer :parent_id

      # The hub / warehouse a store_manager or distributor belongs to.
      Integer :branch_id

      String :device_uuid
      String :phone_number
      jsonb :phone_numbers, default: '{}'

      column :logged_in_ips, 'text[]', default: '{}'
      column :property_ids, 'Integer[]', default: '{}'

      jsonb :tokens, default: '{}'

      jsonb :authorization, default: '{}'

      jsonb :extras, default: '{}'

      String :current_session_id, text: true

      # Password reset flow (referenced by the User model / Users service).
      String :reset_token
      DateTime :reset_sent_at

      String :status, default: 'Active'

      DateTime :last_logged_in_at
      TrueClass :active, :default => true

      Integer :created_by
      Integer :updated_by
      DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
      DateTime :updated_at, default: Sequel::CURRENT_TIMESTAMP

      index :username, unique: true
      index :email
      index :branch_id
      index :reset_token
    end
  end
end
