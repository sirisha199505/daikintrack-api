class App::Models::Branch < Sequel::Model
  one_to_many :products, class: 'App::Models::Product', key: :branch_id
  one_to_many :users,    class: 'App::Models::User',    key: :branch_id

  def validate
    super
    validates_presence [:name, :slug]
    validates_unique :slug
  end

  def as_pos
    as_json(only: [
      :id, :slug, :name, :code, :location, :address,
      :contact, :manager, :status, :color, :gradient, :active,
      :created_at, :updated_at
    ])
  end
end
