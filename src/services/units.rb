class App::Services::Units < App::Services::Base
  def model; ProductUnit; end

  def list
    ds = model.order(Sequel.desc(:created_at))
    ds = scope_branch(ds)
    ds = ds.where(product_id: qs[:product_id]) if qs[:product_id].present?

    if qs[:status].present?
      statuses = qs[:status].to_s.split(',').map(&:strip)
      ds = ds.where(status: statuses)
    end
    # Convenience flag: ?quarantine=1 → all units awaiting disposition.
    ds = ds.where(status: ProductUnit::QUARANTINE) if qs[:quarantine].present?

    if qs[:search].present?
      term = "%#{qs[:search]}%"
      ds = ds.where(Sequel.ilike(:serial_no, term) | Sequel.ilike(:customer_name, term) | Sequel.ilike(:supplier_name, term))
    end

    count = ds.count
    items = ds.offset(offset).limit(limit).all.map(&:as_pos)
    return_success(items, total_pages: (count / page_size.to_f).ceil, total: count)
  end

  def get
    return_success(item.as_pos)
  end

  def by_serial
    code = (qs[:serial_no] || rp[:serial_no]).to_s.strip
    unit = model.where(serial_no: code).first
    return_errors!("No unit found for serial #{code}", 404) unless unit
    return_success(unit.as_pos)
  end
end
