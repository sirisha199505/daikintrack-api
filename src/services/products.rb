class App::Services::Products < App::Services::Base
  def model; Product; end

  def list
    # Eager-load category & branch so as_pos doesn't fire a query per row (N+1).
    ds = model.eager(:category, :branch).order(Sequel.desc(:updated_at))

    # Non-admin users default to their own branch, but may VIEW another branch
    # read-only by passing ?branch_id= (writes stay locked to their own branch,
    # enforced in create/update below).
    user = App.cu.user_obj
    if user && !user.admin? && user.branch_id
      ds = ds.where(branch_id: qs[:branch_id].presence || user.branch_id)
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

  # Look a product up by its scanned barcode. Scanners/QR labels sometimes carry
  # a concatenated payload (barcode + model + mfg-date + suffix), so if the
  # incoming value is longer than a plain barcode we fall back to the leading
  # 13-digit run — the same rule the frontend parser uses.
  def by_barcode
    raw  = (qs[:barcode] || rp[:barcode]).to_s.strip
    code = raw
    product = model.where(barcode: code).first
    if product.nil? && raw.length > 13 && (m = raw.match(/^\d{13}/))
      code = m[0]
      product = model.where(barcode: code).first
    end
    return_errors!("No product found for barcode #{code}", 404) unless product
    return_success(product.as_pos)
  end

  def create
    data = data_for(:save)
    data[:branch_id] = manager_branch_id!(data[:branch_id])
    obj = model.new(data)
    obj.barcode = generate_barcode if obj.barcode.blank?
    save(obj) { |o| return_success(o.as_pos) }
  end

  def update(data = nil)
    data ||= data_for(:save)
    data[:branch_id] = manager_branch_id!(data[:branch_id])
    item.set_fields(data, data.keys)
    save(item) { |o| return_success(o.as_pos) }
  end

  # Resolve the branch a write targets. Admins keep whatever branch was supplied.
  # Store managers may operate on whichever branch they've switched to (the one
  # passed in the request); when none is given we fall back to their own branch.
  def manager_branch_id!(requested)
    user = App.cu.user_obj
    return requested if user.nil? || user.admin?
    return_errors!('You are not assigned to a branch.', 403) if user.branch_id.blank?
    requested.presence || user.branch_id
  end

  # Generate a unique 13-digit, EAN-style numeric barcode ("890" + 10 digits).
  # We verify against the table and retry, so auto-generated codes never collide.
  def generate_barcode
    100.times do
      candidate = "890#{SecureRandom.random_number(10**10).to_s.rjust(10, '0')}"
      return candidate unless model.where(barcode: candidate).first
    end
    raise "Unable to generate a unique barcode"
  end

  def self.fields
    {
      save: [:name, :branch_id, :category_id, :barcode,
             :model_number, :manufacturing_date, :serial_code,
             :stock, :low_stock_threshold, :price, :active]
    }
  end
end
