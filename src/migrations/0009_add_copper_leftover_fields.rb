Sequel.migration do
  change do
    alter_table(:copper_scans) do
      # How the measurement was taken:
      #   trace  – polyline traced over a reference-calibrated photo (existing)
      #   coil   – one loop measured × number of turns (existing)
      #   weight – leftover coil weighed; length derived from kg/m (new, accurate)
      add_column :method, String, default: 'trace'

      # Known coil product the leftover belongs to (e.g. '5/8" x 0.70 x 15m'),
      # and the full starting length of that coil in metres.
      add_column :product,        String
      add_column :start_length_m, Float

      # Weight-mode results: the weighed leftover (grams), the copper-per-metre
      # used to convert it, and the resulting remaining length (metres).
      # `length_m` continues to hold the headline number — for weight scans that
      # is the USED (consumed) length = start − remaining.
      add_column :leftover_weight_g,   Float
      add_column :kg_per_m,            Float
      add_column :remaining_length_m,  Float
    end
  end
end
