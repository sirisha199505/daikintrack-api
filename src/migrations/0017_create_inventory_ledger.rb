Sequel.migration do
  change do
    create_table(:inventory_ledgers) do
      primary_key :id

      # purchase | sale | return | inspection | restock |
      # repair | replacement | scrap | opening
      String :movement_type, null: false

      foreign_key :product_id,      :products,      on_delete: :set_null
      foreign_key :product_unit_id, :product_units, on_delete: :set_null
      String :serial_no                       # snapshot of the unit serial

      # Net effect on available stock: +1 in, -1 out, 0 for status-only moves
      # (e.g. sold -> under_inspection within quarantine).
      Integer :qty, null: false, default: 0

      # Status transition captured for quarantine / lifecycle moves.
      String :from_status
      String :to_status

      String :invoice_no                      # snapshot (purchase or sales)
      String :party_name                      # supplier or customer snapshot
      foreign_key :branch_id, :branches, on_delete: :set_null
      String :branch_name

      Integer :balance_after                  # product available balance AFTER
      Integer :unit_price                     # cost or sold price snapshot
      String  :actor
      Integer :ref_invoice_id                 # purchase_invoice_id / sales_invoice_id

      DateTime :occurred_at, default: Sequel::CURRENT_TIMESTAMP
      Integer  :created_by
      DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP

      index :movement_type
      index :product_id
      index [:product_id, :occurred_at]       # per-product stock ledger, ordered
      index :serial_no
      index :invoice_no
      index :branch_id
      index :occurred_at
    end
  end
end
