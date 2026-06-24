Sequel.migration do
  change do
    create_table(:customers) do
      primary_key :id

      String :name, null: false
      String :code                       # optional internal customer code
      String :gstin
      String :contact                    # contact person
      String :email
      String :phone
      String :address, text: true

      # Customers may be scoped to a branch (null = shared across all branches).
      foreign_key :branch_id, :branches, on_delete: :set_null

      Boolean :active, default: true

      Integer :created_by
      Integer :updated_by
      DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
      DateTime :updated_at, default: Sequel::CURRENT_TIMESTAMP

      index :name
      index :branch_id
      index :active
    end
  end
end
