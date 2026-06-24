Sequel.migration do
  change do
    create_table(:purchase_items) do
      primary_key :id

      foreign_key :purchase_invoice_id, :purchase_invoices, on_delete: :cascade
      foreign_key :product_id,          :products,          on_delete: :set_null

      # Snapshots of the product at the time of purchase.
      String :product_name
      String :barcode

      Integer :quantity,   null: false, default: 1
      Integer :cost_price, default: 0     # per-unit, whole rupees
      Integer :line_total, default: 0     # quantity * cost_price

      DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
      DateTime :updated_at, default: Sequel::CURRENT_TIMESTAMP

      index :purchase_invoice_id
      index :product_id
    end
  end
end
