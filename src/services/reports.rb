class App::Services::Reports < App::Services::Base
  def model; InventoryLedger; end

  # ---- Universal search (invoice / serial / customer / supplier / product) ----
  def search
    q = qs[:q].to_s.strip
    return return_success(empty_search) if q.length < 2
    term = "%#{q}%"
    type = qs[:type].presence

    res = empty_search
    if type.nil? || type == 'serial'
      res[:units] = ProductUnit.where(Sequel.ilike(:serial_no, term)).limit(15).all.map(&:as_pos)
    end
    if type.nil? || type == 'invoice'
      res[:purchase_invoices] = PurchaseInvoice.where(Sequel.ilike(:invoice_no, term)).limit(10).all.map(&:as_pos)
      res[:sales_invoices]    = SalesInvoice.where(Sequel.ilike(:invoice_no, term)).limit(10).all.map(&:as_pos)
    end
    if type.nil? || type == 'supplier'
      res[:suppliers] = Supplier.where(Sequel.ilike(:name, term) | Sequel.ilike(:gstin, term)).limit(10).all.map(&:as_pos)
    end
    if type.nil? || type == 'customer'
      res[:customers] = Customer.where(Sequel.ilike(:name, term) | Sequel.ilike(:gstin, term)).limit(10).all.map(&:as_pos)
    end
    if type.nil? || type == 'product'
      pds = scope_branch(Product.where(Sequel.ilike(:name, term) | Sequel.ilike(:barcode, term)))
      res[:products] = pds.limit(10).all.map(&:as_pos)
    end
    return_success(res)
  end

  # ---- Stock Ledger: every movement for a product, time-ordered ----
  def stock_ledger
    ds = InventoryLedger.order(Sequel.asc(:occurred_at), Sequel.asc(:id))
    ds = scope_branch(ds)
    ds = ds.where(product_id: qs[:product_id]) if qs[:product_id].present?
    ds = ds.where(movement_type: qs[:type].to_s.split(',')) if qs[:type].present?
    ds = date_range(ds)
    if qs[:search].present?
      term = "%#{qs[:search]}%"
      ds = ds.where(Sequel.ilike(:serial_no, term) | Sequel.ilike(:invoice_no, term) | Sequel.ilike(:party_name, term))
    end
    paginate(ds) { |r| r.as_pos }
  end

  # ---- Purchase Register ----
  def purchase_register
    ds = scope_branch(PurchaseInvoice.order(Sequel.desc(:occurred_at)))
    ds = ds.where(supplier_id: qs[:supplier_id]) if qs[:supplier_id].present?
    ds = date_range(ds)
    totals = { invoices: ds.count, qty: ds.sum(:total_qty).to_i, amount: ds.sum(:total_amount).to_i }
    paginate(ds, totals) { |r| r.as_pos }
  end

  # ---- Sales Register ----
  def sales_register
    ds = scope_branch(SalesInvoice.order(Sequel.desc(:occurred_at)))
    ds = ds.where(customer_id: qs[:customer_id]) if qs[:customer_id].present?
    ds = date_range(ds)
    totals = { invoices: ds.count, qty: ds.sum(:total_qty).to_i, amount: ds.sum(:total_amount).to_i }
    paginate(ds, totals) { |r| r.as_pos }
  end

  # ---- Outstanding Stock: products with available balance + quarantine counts -
  def outstanding_stock
    ds = scope_branch(Product.where { stock > 0 }.order(Sequel.desc(:stock)))
    count = ds.count
    rows = ds.offset(offset).limit(limit).all.map do |p|
      p.as_pos.merge!(
        quarantine: ProductUnit.where(product_id: p.id, status: ProductUnit::QUARANTINE).count,
        damaged:    ProductUnit.where(product_id: p.id, status: 'damaged').count
      )
    end
    totals = { products: count, available: ds.sum(:stock).to_i }
    return_success(rows, total: count, total_pages: (count / page_size.to_f).ceil, totals: totals)
  end

  # ---- Product Traceability: a serial's full lifecycle ----
  def traceability
    serial = (qs[:serial_no] || qs[:serial]).to_s.strip
    if serial.present?
      unit = ProductUnit.where(serial_no: serial).first or return_errors!("No unit found for serial #{serial}", 404)
      trail = InventoryLedger.where(serial_no: serial).order(Sequel.asc(:occurred_at), Sequel.asc(:id)).all.map(&:as_pos)
      return return_success(unit: unit.as_pos, trail: trail)
    end
    # Product-level lifecycle (all serials' movements) when no serial is given.
    return_errors!('serial_no or product_id is required') if qs[:product_id].blank?
    trail = InventoryLedger.where(product_id: qs[:product_id]).order(Sequel.asc(:occurred_at), Sequel.asc(:id)).all.map(&:as_pos)
    units = ProductUnit.where(product_id: qs[:product_id]).order(Sequel.desc(:created_at)).limit(limit).all.map(&:as_pos)
    return_success(unit: nil, units: units, trail: trail)
  end

  private

  def empty_search
    { units: [], purchase_invoices: [], sales_invoices: [], suppliers: [], customers: [], products: [] }
  end

  def date_range(ds, col = :occurred_at)
    ds = ds.where(Sequel.lit("#{col} >= ?", "#{qs[:from]} 00:00:00")) if qs[:from].present?
    ds = ds.where(Sequel.lit("#{col} <= ?", "#{qs[:to]} 23:59:59"))   if qs[:to].present?
    ds
  end

  def paginate(ds, totals = nil)
    count = ds.count
    rows = ds.offset(offset).limit(limit).all.map { |r| yield(r) }
    extras = { total: count, total_pages: (count / page_size.to_f).ceil }
    extras[:totals] = totals if totals
    return_success(rows, extras)
  end
end
