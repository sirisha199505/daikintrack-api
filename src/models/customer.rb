class App::Models::Customer < Sequel::Model
  many_to_one :branch, class: 'App::Models::Branch'
  one_to_many :sales_invoices, class: 'App::Models::SalesInvoice', key: :customer_id
  one_to_many :product_units,  class: 'App::Models::ProductUnit',  key: :customer_id

  def validate
    super
    validates_presence [:name]
  end

  def as_pos
    as_json(only: [
      :id, :name, :code, :gstin, :contact, :email, :phone, :address,
      :branch_id, :active, :created_at, :updated_at
    ]).merge!(branch_name: branch&.name)
  end
end
