Sequel.migration do
  change do
    # Product classification captured on the Check-In / Check-Out screen,
    # sourced from the client's mapping sheet. Stored as a JSON array of
    # { category, type, capacity, unit } rows entered by the operator.
    alter_table(:purchase_invoices) do
      add_column :product_details, :jsonb, default: '[]'
    end
    alter_table(:sales_invoices) do
      add_column :product_details, :jsonb, default: '[]'
    end
  end
end
