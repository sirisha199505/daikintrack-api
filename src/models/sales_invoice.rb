class App::Models::SalesInvoice < Sequel::Model
  many_to_one :customer, class: 'App::Models::Customer'
  many_to_one :branch,   class: 'App::Models::Branch'
  one_to_many :items,         class: 'App::Models::SalesItem',   key: :sales_invoice_id
  one_to_many :product_units, class: 'App::Models::ProductUnit', key: :sales_invoice_id

  STATUSES = %w[posted cancelled].freeze

  def validate
    super
    validates_presence [:invoice_no]
    validates_unique :invoice_no
    validates_includes STATUSES, :status if status
  end

  def header_pos
    as_json(only: [
      :id, :invoice_no, :customer_id, :branch_id, :customer_name, :branch_name,
      :status, :total_qty, :total_amount, :notes, :actor, :product_details,
      :occurred_at, :created_at, :updated_at
    ])
  end

  def as_pos
    header_pos.merge!(line_count: items.count, unit_count: total_qty)
  end

  def as_detail
    header_pos.merge!(items: items.map(&:as_pos))
  end
end
