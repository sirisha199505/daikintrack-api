Sequel.migration do
  change do
    create_table(:products) do
      primary_key :id

      String :name, null: false

      foreign_key :branch_id, :branches, on_delete: :cascade
      foreign_key :category_id, :categories, on_delete: :set_null

      # 13-digit EAN-style barcode used by the scanner.
      String :barcode

      Integer :stock, default: 0
      Integer :low_stock_threshold, default: 10

      # Unit price stored in whole rupees (matches the frontend seed values).
      Integer :price, default: 0

      Boolean :active, default: true

      Integer :created_by
      Integer :updated_by
      DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
      DateTime :updated_at, default: Sequel::CURRENT_TIMESTAMP

      index :barcode, unique: true
      index :branch_id
      index :category_id
      index :active
    end
  end
end
