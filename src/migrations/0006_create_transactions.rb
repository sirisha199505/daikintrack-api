Sequel.migration do
  change do
    create_table(:transactions) do
      primary_key :id

      String :invoice_no

      # Movement direction: 'in' = check in, 'out' = check out.
      String :txn_type, null: false

      foreign_key :branch_id, :branches, on_delete: :set_null
      foreign_key :product_id, :products, on_delete: :set_null

      Integer :quantity, null: false, default: 1

      # Who performed the movement (free text, e.g. the branch manager name).
      String :actor
      String :status   # "Checked In" / "Checked Out"

      # Denormalised snapshot so history stays readable even if the
      # product / branch is later renamed or removed.
      String :product_name
      String :barcode
      String :category
      String :branch_name

      # When the movement actually happened.
      DateTime :occurred_at, default: Sequel::CURRENT_TIMESTAMP

      Integer :created_by
      Integer :updated_by
      DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
      DateTime :updated_at, default: Sequel::CURRENT_TIMESTAMP

      index :invoice_no
      index :branch_id
      index :product_id
      index :txn_type
      index :occurred_at
    end
  end
end
