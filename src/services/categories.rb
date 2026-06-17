class App::Services::Categories < App::Services::Base
  def model; Category; end

  def list
    return_success(model.order(:name).all.map(&:as_pos))
  end

  def get
    return_success(item.as_pos)
  end

  def self.fields
    {
      save: [:slug, :name, :color, :active]
    }
  end
end
