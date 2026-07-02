class App::Services::Purchases < App::Services::Base
  def model; PurchaseInvoice; end

  def list
    # Eager-load line items + their product/category so as_pos (product_name,
    # category_name, line_count) doesn't N+1 per invoice.
    ds = model.eager(items: { product: :category }).order(Sequel.desc(:occurred_at))
    ds = scope_branch(ds)
    ds = ds.where(supplier_id: qs[:supplier_id]) if qs[:supplier_id].present?
    ds = ds.where(Sequel.lit('occurred_at >= ?', "#{qs[:from]} 00:00:00")) if qs[:from].present?
    ds = ds.where(Sequel.lit('occurred_at <= ?', "#{qs[:to]} 23:59:59")) if qs[:to].present?
    if qs[:search].present?
      term = "%#{qs[:search]}%"
      ds = ds.where(
        Sequel.ilike(:invoice_no, term) |
        Sequel.ilike(:supplier_invoice_no, term) |
        Sequel.ilike(:supplier_name, term)
      )
    end
    count = ds.count
    items = ds.offset(offset).limit(limit).all.map(&:as_pos)
    return_success(items, total_pages: (count / page_size.to_f).ceil, total: count)
  end

  def get
    return_success(item.as_detail)
  end

  # Post a purchase invoice = Check-In. Creates one product_unit (with a unique
  # serial) per purchased quantity, increments the product's available stock,
  # and writes an inventory_ledger row per unit. Fully atomic.
  def create
    items = Array(params[:items])
    return_errors!('At least one line item is required') if items.empty?

    # Supplier is optional — check-in no longer captures it. When a supplier_id
    # is supplied (legacy callers) we still validate & snapshot it, so existing
    # invoices keep showing their supplier name in the details view.
    supplier  = params[:supplier_id].present? ? (Supplier[params[:supplier_id]] or return_errors!('Supplier not found', 404)) : nil
    branch_id = resolve_branch!(params[:branch_id])
    branch    = Branch[branch_id]
    actor     = App.cu.user_obj&.full_name
    occurred  = params[:occurred_at].present? ? Time.parse(params[:occurred_at].to_s) : Time.now

    # Invoice number: use the one typed in (must be unique) or auto-generate.
    invoice_no = params[:invoice_no].presence || next_invoice_no
    return_errors!("Invoice number #{invoice_no} already exists", 400) if PurchaseInvoice.where(invoice_no: invoice_no).first

    inv = nil
    App.db.transaction do
      inv = PurchaseInvoice.create(
        invoice_no:          invoice_no,
        supplier_invoice_no: params[:supplier_invoice_no],
        supplier_id:         supplier&.id,
        supplier_name:       supplier&.name,
        branch_id:           branch_id,
        branch_name:         branch&.name,
        status:              'posted',
        actor:               actor,
        notes:               params[:notes],
        product_details:     Sequel.pg_jsonb(Array(params[:product_details])),
        occurred_at:         occurred
      )

      total_qty = 0
      total_amt = 0
      items.each do |li|
        product = Product[li[:product_id]] or raise Sequel::Rollback
        qty  = [li[:quantity].to_i, 1].max
        cost = li[:cost_price].to_i

        item = PurchaseItem.create(
          purchase_invoice_id: inv.id, product_id: product.id,
          product_name: product.name, barcode: product.barcode,
          quantity: qty, cost_price: cost, line_total: qty * cost
        )

        running = product.stock.to_i
        qty.times do
          unit = ProductUnit.create(
            serial_no:           ProductUnit.generate_serial(product),
            product_id:          product.id,
            branch_id:           branch_id,
            purchase_invoice_id: inv.id,
            purchase_item_id:    item.id,
            supplier_id:         supplier&.id,
            supplier_name:       supplier&.name,
            cost_price:          cost,
            purchased_at:        occurred,
            status:              'available'
          )
          running += 1
          InventoryLedger.create(
            movement_type: 'purchase', product_id: product.id, product_unit_id: unit.id,
            serial_no: unit.serial_no, qty: 1, to_status: 'available',
            invoice_no: inv.invoice_no, party_name: supplier&.name,
            branch_id: branch_id, branch_name: branch&.name,
            balance_after: running, unit_price: cost, actor: actor,
            ref_invoice_id: inv.id, occurred_at: occurred
          )
        end

        # One atomic counter bump per line (keeps cached balance correct).
        Product.where(id: product.id).update(
          stock:         Sequel.+(:stock, qty),
          qty_purchased: Sequel.+(:qty_purchased, qty)
        )
        total_qty += qty
        total_amt += qty * cost
      end

      inv.update(total_qty: total_qty, total_amount: total_amt)

      # Compatibility row so the existing History feed reflects the activity.
      Transaction.create(
        invoice_no: inv.invoice_no, txn_type: 'in', branch_id: branch_id,
        quantity: total_qty, actor: actor, status: 'Checked In',
        product_name: "Purchase #{inv.invoice_no}", branch_name: branch&.name,
        occurred_at: occurred
      )
    end

    return_errors!('Unable to post purchase', 400) unless inv&.id
    return_success(inv.reload.as_detail)
  rescue => e
    App.logger.error("Purchase post error: #{e.message}")
    App.logger.error(e.backtrace.join("\n"))
    return_errors!("Could not post purchase: #{e.message}", 400)
  end

  # Edit a check-in. Descriptive fields (bill/ref, notes, product-details) are
  # always safe; a changed `quantity` adds/removes serialised units and adjusts
  # stock atomically. Reducing below units already sold is refused.
  def update
    inv  = item
    data = {}
    data[:supplier_invoice_no] = params[:supplier_invoice_no] if params.key?(:supplier_invoice_no)
    data[:notes]               = params[:notes]               if params.key?(:notes)
    data[:product_details]     = Sequel.pg_jsonb(Array(params[:product_details])) if params.key?(:product_details)

    App.db.transaction do
      inv.update(data) unless data.empty?
      adjust_quantity!(inv, params[:quantity].to_i) if params.key?(:quantity)
    end
    return_success(inv.reload.as_detail)
  rescue => e
    App.logger.error("Purchase update error: #{e.message}")
    App.logger.error(e.backtrace.join("\n"))
    return_errors!("Could not update check-in: #{e.message}", 400)
  end

  # Grow/shrink the (single) line's unit count. New units mint fresh serials;
  # removed units must still be 'available' (unsold) to keep stock consistent.
  def adjust_quantity!(inv, new_qty)
    items = PurchaseItem.where(purchase_invoice_id: inv.id).all
    return_errors!('Quantity edit is only supported for single-product check-ins.') if items.size != 1
    li      = items.first
    new_qty = [new_qty, 1].max
    diff    = new_qty - li.quantity.to_i
    return if diff.zero?

    product = Product[li.product_id] or return_errors!('Product missing', 404)
    branch  = inv.branch
    actor   = App.cu.user_obj&.full_name
    cost    = li.cost_price.to_i

    if diff.positive?
      running = product.stock.to_i
      diff.times do
        unit = ProductUnit.create(
          serial_no: ProductUnit.generate_serial(product), product_id: product.id,
          branch_id: inv.branch_id, purchase_invoice_id: inv.id, purchase_item_id: li.id,
          cost_price: cost, purchased_at: inv.occurred_at, status: 'available'
        )
        running += 1
        InventoryLedger.create(
          movement_type: 'purchase', product_id: product.id, product_unit_id: unit.id,
          serial_no: unit.serial_no, qty: 1, to_status: 'available', invoice_no: inv.invoice_no,
          branch_id: inv.branch_id, branch_name: branch&.name, balance_after: running,
          unit_price: cost, actor: actor, ref_invoice_id: inv.id, occurred_at: inv.occurred_at
        )
      end
      Product.where(id: product.id).update(stock: Sequel.+(:stock, diff), qty_purchased: Sequel.+(:qty_purchased, diff))
    else
      remove_n = -diff
      avail = ProductUnit.where(purchase_invoice_id: inv.id, product_id: product.id, status: 'available').limit(remove_n).all
      return_errors!("Cannot reduce to #{new_qty}: only #{avail.size} of these units are still in stock (the rest have been sold or moved).", 400) if avail.size < remove_n
      ids = avail.map(&:id)
      InventoryLedger.where(product_unit_id: ids).delete
      ProductUnit.where(id: ids).delete
      Product.where(id: product.id).update(stock: Sequel.-(:stock, remove_n), qty_purchased: Sequel.-(:qty_purchased, remove_n))
    end

    li.update(quantity: new_qty, line_total: new_qty * cost)
    inv.update(total_qty: new_qty, total_amount: new_qty * cost)
  end

  # Void a check-in: remove its serialised units, reverse stock/counters, and
  # delete the invoice + line items + ledger rows. Refuses if any unit has left
  # the 'available' state (e.g. already sold), since that can't be safely undone.
  def delete
    inv   = item
    units = ProductUnit.where(purchase_invoice_id: inv.id).all
    moved = units.reject { |u| u.status == 'available' }
    if moved.any?
      return_errors!("Cannot delete: #{moved.size} unit(s) from this check-in have already been sold or moved out of stock.", 400)
    end

    unit_ids = units.map(&:id)
    counts   = units.each_with_object(Hash.new(0)) { |u, h| h[u.product_id] += 1 }

    App.db.transaction do
      InventoryLedger.where(product_unit_id: unit_ids).delete if unit_ids.any?
      ProductUnit.where(purchase_invoice_id: inv.id).delete
      PurchaseItem.where(purchase_invoice_id: inv.id).delete
      counts.each do |pid, n|
        Product.where(id: pid).update(
          stock:         Sequel.-(:stock, n),
          qty_purchased: Sequel.-(:qty_purchased, n)
        )
      end
      Transaction.where(invoice_no: inv.invoice_no).delete
      inv.delete
    end
    return_success({ id: inv.id, deleted: true })
  rescue => e
    App.logger.error("Purchase delete error: #{e.message}")
    App.logger.error(e.backtrace.join("\n"))
    return_errors!("Could not delete check-in: #{e.message}", 400)
  end

  def next_invoice_no
    "PINV-2026-#{4900 + model.count + 1}"
  end

  def self.fields
    { save: [:supplier_id, :supplier_invoice_no, :branch_id, :occurred_at, :notes] }
  end
end
