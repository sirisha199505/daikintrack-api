Sequel.migration do
  change do
    create_table(:sales_items) do
      primary_key :id

      foreign_key :sales_invoice_id, :sales_invoices, on_delete: :cascade
      foreign_key :product_id,       :products,       on_delete: :set_null

      String :product_name
      String :barcode

      Integer :quantity,   null: false, default: 1
      Integer :sold_price, default: 0     # per-unit, whole rupees
      Integer :line_total, default: 0     # quantity * sold_price

      DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
      DateTime :updated_at, default: Sequel::CURRENT_TIMESTAMP

      index :sales_invoice_id
      index :product_id
    end
  end
end
