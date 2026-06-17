class App::Services::Products < App::Services::Base
  def model; Product; end

  def list
    ds = model.order(Sequel.desc(:updated_at))

    # Non-admin users are scoped to their own branch.
    user = App.cu.user_obj
    if user && !user.admin? && user.branch_id
      ds = ds.where(branch_id: user.branch_id)
    elsif qs[:branch_id].present?
      ds = ds.where(branch_id: qs[:branch_id])
    end

    ds = ds.where(category_id: qs[:category_id]) if qs[:category_id].present?

    if qs[:search].present?
      term = "%#{qs[:search]}%"
      ds = ds.where(Sequel.ilike(:name, term) | Sequel.ilike(:barcode, term))
    end

    count = ds.count
    items = ds.offset(offset).limit(limit).all.map(&:as_pos)
    return_success(items, total_pages: (count / page_size.to_f).ceil, total: count)
  end

  def get
    return_success(item.as_pos)
  end

  # Look a product up by its scanned barcode.
  def by_barcode
    code = (qs[:barcode] || rp[:barcode]).to_s.strip
    product = model.where(barcode: code).first
    return_errors!("No product found for barcode #{code}", 404) unless product
    return_success(product.as_pos)
  end

  def create
    obj = model.new(data_for(:save))
    obj.barcode = generate_barcode if obj.barcode.blank?
    save(obj) { |o| return_success(o.as_pos) }
  end

  def update(data = nil)
    data ||= data_for(:save)
    item.set_fields(data, data.keys)
    save(item) { |o| return_success(o.as_pos) }
  end

  def generate_barcode
    tail = App.generate_id.gsub(/\D/, '')
    "890#{tail}".ljust(13, '0')[0, 13]
  end

  def self.fields
    {
      save: [:name, :branch_id, :category_id, :barcode,
             :stock, :low_stock_threshold, :price, :active]
    }
  end
end
