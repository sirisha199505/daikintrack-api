class App::Services::Branches < App::Services::Base
  def model; Branch; end

  def list
    return_success(model.order(:name).all.map(&:as_pos))
  end

  def get
    return_success(item.as_pos)
  end

  def self.fields
    {
      save: [:slug, :name, :code, :location, :address, :contact,
             :manager, :status, :color, :gradient, :active]
    }
  end
end
