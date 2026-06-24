Sequel.migration do
  change do
    alter_table(:products) do
      # Lifetime running counters maintained atomically alongside unit/ledger
      # writes. `stock` (existing) remains the canonical AVAILABLE balance =
      # count of product_units in the 'available' status.
      add_column :qty_purchased, Integer, default: 0
      add_column :qty_sold,      Integer, default: 0
      add_column :qty_returned,  Integer, default: 0
    end
  end
end
