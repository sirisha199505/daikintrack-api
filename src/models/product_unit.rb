class App::Models::ProductUnit < Sequel::Model
  many_to_one :product,  class: 'App::Models::Product'
  many_to_one :branch,   class: 'App::Models::Branch'
  many_to_one :supplier, class: 'App::Models::Supplier'
  many_to_one :customer, class: 'App::Models::Customer'
  many_to_one :purchase_invoice, class: 'App::Models::PurchaseInvoice'
  many_to_one :sales_invoice,    class: 'App::Models::SalesInvoice'

  # Only AVAILABLE counts toward sellable stock. RETURNED / UNDER_INSPECTION /
  # REPAIR / DAMAGED are held out of stock (quarantine); REPLACED / SOLD are gone.
  STATUSES = %w[available reserved sold returned under_inspection repair replaced damaged].freeze

  # Statuses that physically sit in quarantine awaiting a disposition.
  QUARANTINE = %w[returned under_inspection repair].freeze

  def validate
    super
    validates_presence [:serial_no, :product_id, :status]
    validates_unique :serial_no
    validates_includes STATUSES, :status if status
  end

  # Collision-safe serial generation, mirroring Products#generate_barcode.
  # The unique index is the real guard; the retry avoids the rare race.
  def self.generate_serial(product)
    prefix = "SN-#{product.id}-"
    100.times do
      candidate = "#{prefix}#{SecureRandom.alphanumeric(8).upcase}"
      return candidate unless where(serial_no: candidate).first
    end
    raise "Unable to generate a unique serial number"
  end

  def as_pos
    as_json(only: [
      :id, :serial_no, :product_id, :branch_id, :status,
      :purchase_invoice_id, :purchase_item_id, :supplier_id, :cost_price, :purchased_at,
      :sales_invoice_id, :sales_item_id, :customer_id, :sold_price, :sold_at,
      :return_reason, :inspection_notes, :disposed_by,
      :supplier_name, :customer_name, :created_at, :updated_at
    ]).merge!(
      product_name:  product&.name,
      barcode:       product&.barcode,
      category_name: product&.category&.name,
      branch_name:   branch&.name
    )
  end
end
