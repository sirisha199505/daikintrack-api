class App::Models::Product < Sequel::Model
  many_to_one :branch,   class: 'App::Models::Branch'
  many_to_one :category, class: 'App::Models::Category'
  one_to_many :transactions,   class: 'App::Models::Transaction',     key: :product_id
  one_to_many :product_units,  class: 'App::Models::ProductUnit',     key: :product_id
  one_to_many :ledger_entries, class: 'App::Models::InventoryLedger', key: :product_id

  def validate
    super
    validates_presence [:name]
    validates_unique(:barcode) if barcode
  end

  def low_stock?
    stock.to_i > 0 && stock.to_i <= low_stock_threshold.to_i
  end

  def out_of_stock?
    stock.to_i.zero?
  end

  def stock_status
    return 'out' if out_of_stock?
    return 'low' if low_stock?
    'ok'
  end

  def as_pos
    as_json(only: [
      :id, :name, :branch_id, :category_id, :barcode,
      :stock, :low_stock_threshold, :price, :active,
      :qty_purchased, :qty_sold, :qty_returned,
      :created_at, :updated_at
    ]).merge!(
      category_name: category&.name,
      branch_name:   branch&.name,
      stock_status:  stock_status,
      available_qty: stock.to_i,            # canonical sellable balance
      purchased_qty: qty_purchased.to_i,
      sold_qty:      qty_sold.to_i,
      returned_qty:  qty_returned.to_i
    )
  end
end
