Sequel.migration do
  change do
    create_table(:product_units) do
      primary_key :id

      # The unique serial number for one physical unit.
      String :serial_no, null: false

      foreign_key :product_id, :products, on_delete: :cascade
      foreign_key :branch_id,  :branches, on_delete: :set_null

      # ---- Purchase side (how the unit entered stock) ----
      foreign_key :purchase_invoice_id, :purchase_invoices, on_delete: :set_null
      foreign_key :purchase_item_id,    :purchase_items,    on_delete: :set_null
      foreign_key :supplier_id,         :suppliers,         on_delete: :set_null
      Integer  :cost_price, default: 0
      DateTime :purchased_at

      # ---- Sale side (null until the unit is sold) ----
      foreign_key :sales_invoice_id, :sales_invoices, on_delete: :set_null
      foreign_key :sales_item_id,    :sales_items,    on_delete: :set_null
      foreign_key :customer_id,      :customers,      on_delete: :set_null
      Integer  :sold_price
      DateTime :sold_at

      # Lifecycle status. Only 'available' counts toward sellable stock:
      #   available | reserved | sold | returned |
      #   under_inspection | repair | replaced | damaged
      String :status, null: false, default: 'available'

      # Returns / quarantine metadata.
      String :return_reason
      String :inspection_notes, text: true
      String :disposed_by

      # Party snapshots for fast display / traceability.
      String :supplier_name
      String :customer_name

      Integer :created_by
      Integer :updated_by
      DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
      DateTime :updated_at, default: Sequel::CURRENT_TIMESTAMP

      index :serial_no, unique: true
      index :product_id
      index [:product_id, :status]   # FIFO pick + available counts
      index :status
      index :purchase_invoice_id
      index :sales_invoice_id
      index :branch_id
      index :supplier_id
      index :customer_id
      index :purchased_at
    end
  end
end
