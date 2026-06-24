class App::Services::Customers < App::Services::Base
  def model; Customer; end

  def list
    ds = model.where(active: true).order(Sequel.asc(:name))

    if qs[:search].present?
      term = "%#{qs[:search]}%"
      ds = ds.where(
        Sequel.ilike(:name, term) |
        Sequel.ilike(:code, term) |
        Sequel.ilike(:gstin, term) |
        Sequel.ilike(:phone, term) |
        Sequel.ilike(:email, term)
      )
    end

    count = ds.count
    items = ds.offset(offset).limit(limit).all.map(&:as_pos)
    return_success(items, total_pages: (count / page_size.to_f).ceil, total: count)
  end

  def get
    return_success(item.as_pos)
  end

  def create
    data = data_for(:save)
    data[:branch_id] ||= App.cu.user_obj&.branch_id
    obj = model.new(data)
    save(obj) { |o| return_success(o.as_pos) }
  end

  def update(data = nil)
    data ||= data_for(:save)
    item.set_fields(data, data.keys)
    save(item) { |o| return_success(o.as_pos) }
  end

  def delete
    item.active = false
    save(item) { |o| return_success(o.as_pos) }
  end

  def self.fields
    { save: [:name, :code, :gstin, :contact, :email, :phone, :address, :branch_id, :active] }
  end
end
