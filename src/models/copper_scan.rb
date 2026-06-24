class App::Models::CopperScan < Sequel::Model
  many_to_one :branch, class: 'App::Models::Branch'

  def validate
    super
    validates_presence [:branch_id]
  end

  # Weight in kilograms, derived from the stored grams.
  def weight_kg
    (weight_g.to_f / 1000.0).round(3)
  end

  def as_pos
    as_json(only: [
      :id, :branch_id, :reference_type, :reference_mm, :px_per_mm,
      :length_m, :method, :product, :start_length_m, :remaining_length_m,
      :leftover_weight_g, :kg_per_m, :gauge_system, :gauge_value,
      :diameter_mm, :weight_g, :image, :points, :notes, :actor, :status,
      :created_at, :updated_at
    ]).merge!(
      branch_name: branch&.name,
      weight_kg:   weight_kg
    )
  end

  # Lighter projection for list/report views — omits the heavy base64 image so
  # large lists stay fast; the full image is fetched per-record via GET /:id.
  def as_summary
    as_json(only: [
      :id, :branch_id, :reference_type, :length_m, :method, :product,
      :start_length_m, :remaining_length_m, :leftover_weight_g, :kg_per_m,
      :gauge_system, :gauge_value, :diameter_mm, :weight_g, :notes, :actor,
      :status, :created_at, :updated_at
    ]).merge!(
      branch_name: branch&.name,
      weight_kg:   weight_kg,
      has_image:   !image.to_s.empty?
    )
  end
end
