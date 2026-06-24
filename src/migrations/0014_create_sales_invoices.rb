Sequel.migration do
  change do
    create_table(:sales_invoices) do
      primary_key :id

      # Internal posting number (SINV-2026-xxxx).
      String :invoice_no, null: false

      foreign_key :customer_id, :customers, on_delete: :set_null
      foreign_key :branch_id,   :branches,  on_delete: :set_null

      String :customer_name
      String :branch_name

      String  :status, default: 'posted'   # posted | cancelled
      Integer :total_qty,    default: 0
      Integer :total_amount, default: 0     # whole rupees

      String :notes, text: true
      String :actor

      DateTime :occurred_at, default: Sequel::CURRENT_TIMESTAMP

      Integer :created_by
      Integer :updated_by
      DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
      DateTime :updated_at, default: Sequel::CURRENT_TIMESTAMP

      index :invoice_no, unique: true
      index :customer_id
      index :branch_id
      index :status
      index :occurred_at
    end
  end
end
