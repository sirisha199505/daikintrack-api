class App::Services::Sales < App::Services::Base
  def model; SalesInvoice; end

  def list
    # Eager-load line items + their product/category so as_pos doesn't N+1.
    ds = model.eager(items: { product: :category }).order(Sequel.desc(:occurred_at))
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
    items = Array(params[:items])
    return_errors!('At least one line item is required') if items.empty?

    # Customer is optional — check-out is now a scan-and-save flow. When supplied
    # (legacy callers) we still validate & snapshot it onto the units/invoice.
    customer  = params[:customer_id].present? ? (Customer[params[:customer_id]] or return_errors!('Customer not found', 404)) : nil
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
        customer_id:   customer&.id,
        customer_name: customer&.name,
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
            customer_id: customer&.id, customer_name: customer&.name,
            sold_price: price, sold_at: occurred
          )
          running -= 1
          InventoryLedger.create(
            movement_type: 'sale', product_id: product.id, product_unit_id: unit.id,
            serial_no: unit.serial_no, qty: -1, from_status: 'available', to_status: 'sold',
            invoice_no: inv.invoice_no, party_name: customer&.name,
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

  # Edit a check-out. Descriptive fields (notes, product-details) are always
  # safe; a changed `quantity` allocates more units (FIFO) or returns sold units
  # to available stock, atomically.
  def update
    inv  = item
    data = {}
    data[:notes]           = params[:notes]           if params.key?(:notes)
    data[:product_details] = Sequel.pg_jsonb(Array(params[:product_details])) if params.key?(:product_details)

    App.db.transaction do
      inv.update(data) unless data.empty?
      adjust_quantity!(inv, params[:quantity].to_i) if params.key?(:quantity)
    end
    return_success(inv.reload.as_detail)
  rescue => e
    App.logger.error("Sale update error: #{e.message}")
    App.logger.error(e.backtrace.join("\n"))
    return_errors!("Could not update check-out: #{e.message}", 400)
  end

  # Grow/shrink the (single) line's sold-unit count. Growing allocates more
  # available units FIFO (errors if stock is short); shrinking returns the
  # surplus sold units to available.
  def adjust_quantity!(inv, new_qty)
    items = SalesItem.where(sales_invoice_id: inv.id).all
    return_errors!('Quantity edit is only supported for single-product check-outs.') if items.size != 1
    li      = items.first
    new_qty = [new_qty, 1].max
    diff    = new_qty - li.quantity.to_i
    return if diff.zero?

    product = Product[li.product_id] or return_errors!('Product missing', 404)
    branch  = inv.branch
    actor   = App.cu.user_obj&.full_name
    price   = li.sold_price.to_i

    if diff.positive?
      units = ProductUnit.where(product_id: product.id, status: 'available', branch_id: inv.branch_id)
                         .order(:purchased_at, :id).limit(diff).for_update.all
      return_errors!("Insufficient stock: need #{diff} more unit(s), only #{units.size} available.", 400) if units.size < diff
      running = product.stock.to_i
      units.each do |u|
        u.update(status: 'sold', sales_invoice_id: inv.id, sales_item_id: li.id,
                 customer_id: inv.customer_id, customer_name: inv.customer_name,
                 sold_price: price, sold_at: inv.occurred_at)
        running -= 1
        InventoryLedger.create(
          movement_type: 'sale', product_id: product.id, product_unit_id: u.id,
          serial_no: u.serial_no, qty: -1, from_status: 'available', to_status: 'sold',
          invoice_no: inv.invoice_no, party_name: inv.customer_name, branch_id: inv.branch_id,
          branch_name: branch&.name, balance_after: running, unit_price: price, actor: actor,
          ref_invoice_id: inv.id, occurred_at: inv.occurred_at
        )
      end
      Product.where(id: product.id).update(stock: Sequel.-(:stock, diff), qty_sold: Sequel.+(:qty_sold, diff))
    else
      return_n = -diff
      sold = ProductUnit.where(sales_invoice_id: inv.id, product_id: product.id, status: 'sold').limit(return_n).all
      return_errors!("Cannot reduce to #{new_qty}: only #{sold.size} sold unit(s) available to return.", 400) if sold.size < return_n
      ids = sold.map(&:id)
      InventoryLedger.where(product_unit_id: ids, movement_type: 'sale', ref_invoice_id: inv.id).delete
      ProductUnit.where(id: ids).update(
        status: 'available', sales_invoice_id: nil, sales_item_id: nil,
        customer_id: nil, customer_name: nil, sold_price: nil, sold_at: nil
      )
      Product.where(id: product.id).update(stock: Sequel.+(:stock, return_n), qty_sold: Sequel.-(:qty_sold, return_n))
    end

    li.update(quantity: new_qty, line_total: new_qty * price)
    inv.update(total_qty: new_qty, total_amount: new_qty * price)
  end

  # Void a check-out: return its sold units to 'available', restore stock/
  # counters, and delete the invoice + line items + sale ledger rows. The
  # units' original purchase history (ledger + purchase invoice) is preserved.
  def delete
    inv   = item
    units = ProductUnit.where(sales_invoice_id: inv.id).all
    unit_ids = units.map(&:id)
    counts   = units.each_with_object(Hash.new(0)) { |u, h| h[u.product_id] += 1 }

    App.db.transaction do
      # Remove only the SALE ledger rows for this invoice; keep purchase history.
      InventoryLedger.where(product_unit_id: unit_ids, movement_type: 'sale', ref_invoice_id: inv.id).delete if unit_ids.any?
      ProductUnit.where(sales_invoice_id: inv.id).update(
        status: 'available', sales_invoice_id: nil, sales_item_id: nil,
        customer_id: nil, customer_name: nil, sold_price: nil, sold_at: nil
      )
      SalesItem.where(sales_invoice_id: inv.id).delete
      counts.each do |pid, n|
        Product.where(id: pid).update(
          stock:    Sequel.+(:stock, n),
          qty_sold: Sequel.-(:qty_sold, n)
        )
      end
      Transaction.where(invoice_no: inv.invoice_no).delete
      inv.delete
    end
    return_success({ id: inv.id, deleted: true })
  rescue => e
    App.logger.error("Sale delete error: #{e.message}")
    App.logger.error(e.backtrace.join("\n"))
    return_errors!("Could not delete check-out: #{e.message}", 400)
  end

  def next_invoice_no
    "SINV-2026-#{4900 + model.count + 1}"
  end

  def self.fields
    { save: [:customer_id, :branch_id, :occurred_at, :notes] }
  end
end
