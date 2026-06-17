class App::Models::Category < Sequel::Model
  one_to_many :products, class: 'App::Models::Product', key: :category_id

  def validate
    super
    validates_presence [:name, :slug]
    validates_unique :slug
  end

  def as_pos
    as_json(only: [:id, :slug, :name, :color, :active, :created_at, :updated_at])
  end
end
