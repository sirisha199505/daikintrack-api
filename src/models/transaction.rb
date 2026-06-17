class App::Models::Transaction < Sequel::Model
  many_to_one :branch,  class: 'App::Models::Branch'
  many_to_one :product, class: 'App::Models::Product'

  TYPES = %w[in out].freeze

  def validate
    super
    validates_presence [:txn_type, :quantity]
    validates_includes TYPES, :txn_type
  end

  def as_pos
    as_json(only: [
      :id, :invoice_no, :txn_type, :branch_id, :product_id,
      :quantity, :actor, :status, :product_name, :barcode,
      :category, :branch_name, :occurred_at, :created_at
    ])
  end
end
