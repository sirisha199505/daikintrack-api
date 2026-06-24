Sequel.migration do
  change do
    create_table(:purchase_invoices) do
      primary_key :id

      # Internal posting number (PINV-2026-xxxx). The supplier's own bill number
      # is captured separately for reconciliation.
      String :invoice_no, null: false
      String :supplier_invoice_no

      foreign_key :supplier_id, :suppliers, on_delete: :set_null
      foreign_key :branch_id,   :branches,  on_delete: :set_null

      # Denormalised snapshots so the document stays readable if a party/branch
      # is later renamed or removed.
      String :supplier_name
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
      index :supplier_id
      index :branch_id
      index :status
      index :occurred_at
    end
  end
end
