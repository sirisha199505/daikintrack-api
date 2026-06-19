class App::Services::Transactions < App::Services::Base
  def model; Transaction; end

  def list
    ds = model.order(Sequel.desc(:occurred_at))

    # Non-admins default to their own branch, but may VIEW another branch
    # read-only by passing ?branch_id=.
    user = App.cu.user_obj
    if user && !user.admin? && user.branch_id
      ds = ds.where(branch_id: qs[:branch_id].presence || user.branch_id)
    elsif qs[:branch_id].present?
      ds = ds.where(branch_id: qs[:branch_id])
    end

    ds = ds.where(txn_type: qs[:type]) if qs[:type].present?

    if qs[:search].present?
      term = "%#{qs[:search]}%"
      ds = ds.where(
        Sequel.ilike(:invoice_no, term) |
        Sequel.ilike(:product_name, term) |
        Sequel.ilike(:barcode, term)
      )
    end

    count = ds.count
    items = ds.offset(offset).limit(limit).all.map(&:as_pos)
    return_success(items, total_pages: (count / page_size.to_f).ceil, total: count)
  end

  def get
    return_success(item.as_pos)
  end

  # Record a check-in / check-out and adjust the product's stock atomically.
  def create
    check_presence!(:product_id, :type, :quantity)

    type = params[:type].to_s
    return_errors!("type must be 'in' or 'out'") unless Transaction::TYPES.include?(type)

    qty = [params[:quantity].to_i, 1].max
    product = Product[params[:product_id]] or return_errors!("Product not found", 404)
    branch  = product.branch

    txn = nil
    App.db.transaction do
      new_stock = type == 'in' ? product.stock.to_i + qty : [product.stock.to_i - qty, 0].max
      product.update(stock: new_stock)

      txn = Transaction.new(
        invoice_no:   params[:invoice_no].presence || next_invoice_no,
        txn_type:     type,
        branch_id:    product.branch_id,
        product_id:   product.id,
        quantity:     qty,
        actor:        params[:actor].presence || App.cu.user_obj&.full_name,
        status:       type == 'in' ? 'Checked In' : 'Checked Out',
        product_name: product.name,
        barcode:      product.barcode,
        category:     product.category&.name,
        branch_name:  params[:branch_name].presence || branch&.name,
        occurred_at:  Time.now
      )
      raise Sequel::Rollback unless txn.save
    end

    return_errors!(txn&.errors || 'Unable to record movement', 400) unless txn&.id
    return_success(txn.as_pos)
  rescue => e
    App.logger.error("Transaction error: #{e.message}")
    App.logger.error(e.backtrace.join("\n"))
    return_errors!("Could not record movement: #{e.message}", 400)
  end

  def next_invoice_no
    seq = 4900 + model.count + 1
    "INV-2026-#{seq}"
  end

  def self.fields
    {
      save: [:invoice_no, :txn_type, :branch_id, :product_id,
             :quantity, :actor, :status]
    }
  end
end
