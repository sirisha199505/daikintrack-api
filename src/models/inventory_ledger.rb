class App::Models::InventoryLedger < Sequel::Model
  many_to_one :product,      class: 'App::Models::Product'
  many_to_one :product_unit, class: 'App::Models::ProductUnit'
  many_to_one :branch,       class: 'App::Models::Branch'

  MOVEMENT_TYPES = %w[
    purchase sale return inspection restock repair replacement scrap opening
  ].freeze

  def validate
    super
    validates_presence [:movement_type]
    validates_includes MOVEMENT_TYPES, :movement_type if movement_type
  end

  def as_pos
    as_json(only: [
      :id, :movement_type, :product_id, :product_unit_id, :serial_no,
      :qty, :from_status, :to_status, :invoice_no, :party_name,
      :branch_id, :branch_name, :balance_after, :unit_price, :actor,
      :ref_invoice_id, :occurred_at, :created_at
    ]).merge!(product_name: product&.name)
  end
end
