Sequel.migration do
  change do
    create_table(:copper_scans) do
      primary_key :id

      foreign_key :branch_id, :branches, on_delete: :cascade

      # Reference object used to calibrate scale (currently the A4 sheet) and the
      # real-world length, in millimetres, of the edge the user tapped.
      String  :reference_type, default: 'a4'
      Float   :reference_mm
      # Calibration result: displayed pixels per millimetre.
      Float   :px_per_mm

      # Measured wire length (metres) from the traced polyline.
      Float   :length_m, null: false, default: 0

      # Wire gauge → diameter → estimated weight.
      String  :gauge_system, default: 'awg' # awg | swg | mm
      String  :gauge_value
      Float   :diameter_mm
      Float   :weight_g, null: false, default: 0

      # Captured photo as a compressed base64 data URL (no file store in this API).
      String  :image, text: true
      # Audit trail of the calibration + traced points (normalised JSON).
      String  :points, text: true
      String  :notes,  text: true

      String  :actor # full name of the user who recorded the scan
      Integer :created_by
      String  :status, default: 'recorded'

      DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
      DateTime :updated_at, default: Sequel::CURRENT_TIMESTAMP

      index :branch_id
      index :created_at
    end
  end
end
