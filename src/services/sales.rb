class App::Services::Sales < App::Services::Base
  def model; SalesInvoice; end

  def list
    ds = model.order(Sequel.desc(:occurred_at))
    ds = scope_branch(ds)
    ds = ds.where(customer_id: qs[:customer_id]) if qs[:customer_id].present?
    ds = ds.where(Sequel.lit('occurred_at >= ?', "#{qs[:from]} 00:00:00")) if qs[:from].present?
    ds = ds.where(Sequel.lit('occurred_at <= ?', "#{qs[:to]} 23:59:59")) if qs[:to].present?
    if qs[:search].present?
      term = "%#{qs[:search]}%"
      ds = ds.where(Sequel.ilike(:invoice_no, term) | Sequel.ilike(:customer_name, term))
    end
    count = ds.count
    items = ds.offset(offset).limit(limit).all.map(&:as_pos)
    return_success(items, total_pages: (count / page_size.to_f).ceil, total: count)
  end

  def get
    return_success(item.as_detail)
  end

  # Post a sales invoice = Check-Out. Allocates in-stock units (explicit serials
  # or FIFO by purchase date), marks them sold, decrements available stock, and
  # writes an inventory_ledger row per unit. Row-locks candidate units to
  # prevent two concurrent sales overselling the same unit. Fully atomic.
  def create
    check_presence!(:customer_id)
    items = Array(params[:items])
    return_errors!('At least one line item is required') if items.empty?

    customer  = Customer[params[:customer_id]] or return_errors!('Customer not found', 404)
    branch_id = resolve_branch!(params[:branch_id])
    branch    = Branch[branch_id]
    actor     = App.cu.user_obj&.full_name
    occurred  = params[:occurred_at].present? ? Time.parse(params[:occurred_at].to_s) : Time.now

    # Invoice number: use the one typed in (must be unique) or auto-generate.
    invoice_no = params[:invoice_no].presence || next_invoice_no
    return_errors!("Invoice number #{invoice_no} already exists", 400) if SalesInvoice.where(invoice_no: invoice_no).first

    inv = nil
    App.db.transaction do
      inv = SalesInvoice.create(
        invoice_no:    invoice_no,
        customer_id:   customer.id,
        customer_name: customer.name,
        branch_id:     branch_id,
        branch_name:   branch&.name,
        status:        'posted',
        actor:         actor,
        notes:         params[:notes],
        product_details: Sequel.pg_jsonb(Array(params[:product_details])),
        occurred_at:   occurred
      )

      total_qty = 0
      total_amt = 0
      items.each do |li|
        product = Product[li[:product_id]] or raise Sequel::Rollback
        qty   = [li[:quantity].to_i, 1].max
        price = li[:sold_price].to_i

        units = pick_units(product, qty, li[:serial_nos], branch_id)
        return_errors!("Insufficient stock for #{product.name} (need #{qty}, have #{units.size})", 400) if units.size < qty

        item = SalesItem.create(
          sales_invoice_id: inv.id, product_id: product.id,
          product_name: product.name, barcode: product.barcode,
          quantity: qty, sold_price: price, line_total: qty * price
        )

        running = product.stock.to_i
        units.each do |unit|
          unit.update(
            status: 'sold', sales_invoice_id: inv.id, sales_item_id: item.id,
            customer_id: customer.id, customer_name: customer.name,
            sold_price: price, sold_at: occurred
          )
          running -= 1
          InventoryLedger.create(
            movement_type: 'sale', product_id: product.id, product_unit_id: unit.id,
            serial_no: unit.serial_no, qty: -1, from_status: 'available', to_status: 'sold',
            invoice_no: inv.invoice_no, party_name: customer.name,
            branch_id: branch_id, branch_name: branch&.name,
            balance_after: running, unit_price: price, actor: actor,
            ref_invoice_id: inv.id, occurred_at: occurred
          )
        end

        Product.where(id: product.id).update(
          stock:    Sequel.-(:stock, qty),
          qty_sold: Sequel.+(:qty_sold, qty)
        )
        total_qty += qty
        total_amt += qty * price
      end

      inv.update(total_qty: total_qty, total_amount: total_amt)

      Transaction.create(
        invoice_no: inv.invoice_no, txn_type: 'out', branch_id: branch_id,
        quantity: total_qty, actor: actor, status: 'Checked Out',
        product_name: "Sale #{inv.invoice_no}", branch_name: branch&.name,
        occurred_at: occurred
      )
    end

    return_errors!('Unable to post sale', 400) unless inv&.id
    return_success(inv.reload.as_detail)
  rescue Sequel::HookFailed, Sequel::Rollback
    return_errors!('Could not post sale: invalid line item', 400)
  rescue => e
    App.logger.error("Sale post error: #{e.message}")
    App.logger.error(e.backtrace.join("\n"))
    return_errors!("Could not post sale: #{e.message}", 400)
  end

  # Allocate units for a line: explicit serials if supplied, else FIFO by
  # purchase date. Locks the rows FOR UPDATE so concurrent sales can't double-sell.
  def pick_units(product, qty, serial_nos, branch_id)
    if serial_nos.present?
      ProductUnit
        .where(serial_no: Array(serial_nos), product_id: product.id, status: 'available')
        .for_update.all
    else
      ProductUnit
        .where(product_id: product.id, status: 'available', branch_id: branch_id)
        .order(:purchased_at, :id)
        .limit(qty)
        .for_update.all
    end
  end

  def next_invoice_no
    "SINV-2026-#{4900 + model.count + 1}"
  end

  def self.fields
    { save: [:customer_id, :branch_id, :occurred_at, :notes] }
  end
end
