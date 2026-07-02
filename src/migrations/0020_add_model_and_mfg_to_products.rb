Sequel.migration do
  change do
    alter_table(:products) do
      # Daikin model number extracted from the scanned QR/barcode string
      # (e.g. "RZMF125BRV169"). Free text — the catalog mapping lives on the
      # frontend (daikinMapping.js), so we only persist the raw code here.
      add_column :model_number, String

      # Manufacturing date as printed on the unit, kept in the "MM-YYYY" form
      # the scan carries (e.g. "11-2025"). Stored as text to preserve the
      # month-year granularity exactly rather than coercing to a full Date.
      add_column :manufacturing_date, String

      # Trailing suffix that follows the manufacturing date in the scanned
      # string (e.g. "G") — a plant/serial code the operator may want on record.
      add_column :serial_code, String

      add_index :model_number
    end
  end
end
