class App::Models::PurchaseItem < Sequel::Model
  many_to_one :purchase_invoice, class: 'App::Models::PurchaseInvoice', key: :purchase_invoice_id
  many_to_one :product,          class: 'App::Models::Product',         key: :product_id
  one_to_many :product_units,    class: 'App::Models::ProductUnit',     key: :purchase_item_id

  def validate
    super
    validates_presence [:quantity]
  end

  def as_pos
    as_json(only: [
      :id, :purchase_invoice_id, :product_id, :product_name, :barcode,
      :quantity, :cost_price, :line_total
    ]).merge!(serials: product_units.map { |u| { id: u.id, serial_no: u.serial_no, status: u.status } })
  end
end
