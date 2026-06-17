class App::Models::Product < Sequel::Model
  many_to_one :branch,   class: 'App::Models::Branch'
  many_to_one :category, class: 'App::Models::Category'
  one_to_many :transactions, class: 'App::Models::Transaction', key: :product_id

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
      :created_at, :updated_at
    ]).merge!(
      category_name: category&.name,
      branch_name:   branch&.name,
      stock_status:  stock_status
    )
  end
end
