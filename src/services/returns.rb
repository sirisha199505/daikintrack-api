class App::Services::Returns < App::Services::Base
  def model; ProductUnit; end

  # ---- Customer return: sold -> returned (quarantine). Does NOT restock. ----
  def create_return
    serials = Array(params[:serials])
    serials << params[:serial_no] if params[:serial_no].present?
    return_errors!('At least one serial number is required') if serials.empty?
    reason = params[:reason].presence || params[:return_reason]
    actor  = App.cu.user_obj&.full_name

    done = []
    App.db.transaction do
      units = ProductUnit.where(serial_no: serials, status: 'sold').for_update.all
      return_errors!('No sold units matched those serials', 404) if units.empty?
      units.each do |unit|
        product = unit.product
        unit.update(status: 'returned', return_reason: reason)
        Product.where(id: product.id).update(qty_returned: Sequel.+(:qty_returned, 1))
        write_ledger(unit, 'return', qty: 1, from: 'sold', to: 'returned',
                     party: unit.customer_name, price: unit.sold_price, actor: actor,
                     balance: Product[product.id].stock)
        compat_txn(unit, 'in', 'Returned', actor)
        done << unit.reload.as_pos
      end
    end
    return_success(done)
  rescue => e
    log_and_fail('return', e)
  end

  # ---- returned -> under_inspection (technician picks it up) ----
  def send_to_inspection
    unit = locked_unit!
    return_errors!('Unit is not in a returnable state') unless %w[returned].include?(unit.status)
    actor = App.cu.user_obj&.full_name
    App.db.transaction do
      unit.update(status: 'under_inspection', inspection_notes: params[:notes])
      write_ledger(unit, 'inspection', qty: 0, from: 'returned', to: 'under_inspection',
                   party: unit.customer_name, actor: actor, balance: unit.product.stock)
    end
    return_success(unit.reload.as_pos)
  rescue => e
    log_and_fail('inspection', e)
  end

  # ---- Technician disposition of a quarantined unit ----
  # params[:decision] in: approve | repair | replace | scrap
  def dispose
    unit = locked_unit!
    return_errors!('Unit is not in quarantine') unless ProductUnit::QUARANTINE.include?(unit.status)
    decision = params[:decision].to_s
    actor    = App.cu.user_obj&.full_name
    notes    = params[:notes]

    App.db.transaction do
      case decision
      when 'approve'
        restock!(unit, 'restock', actor, notes)
      when 'repair'
        from = unit.status
        unit.update(status: 'repair', inspection_notes: notes, disposed_by: actor)
        write_ledger(unit, 'repair', qty: 0, from: from,
                     to: 'repair', party: unit.customer_name, actor: actor, balance: unit.product.stock)
      when 'scrap'
        from = unit.status
        unit.update(status: 'damaged', inspection_notes: notes, disposed_by: actor)
        write_ledger(unit, 'scrap', qty: 0, from: from, to: 'damaged',
                     party: unit.customer_name, actor: actor, balance: unit.product.stock)
      when 'replace'
        issue_replacement!(unit, actor, notes)
      else
        return_errors!("Unknown decision '#{decision}'")
      end
    end
    return_success(unit.reload.as_pos)
  rescue => e
    log_and_fail('disposition', e)
  end

  # ---- repair -> available (repair finished) ----
  def repair_complete
    unit = locked_unit!
    return_errors!('Unit is not under repair') unless unit.status == 'repair'
    actor = App.cu.user_obj&.full_name
    App.db.transaction { restock!(unit, 'restock', actor, params[:notes]) }
    return_success(unit.reload.as_pos)
  rescue => e
    log_and_fail('repair-complete', e)
  end

  # ---- Direct replacement of a sold unit (no prior return step) ----
  def create_replacement
    serial = params[:serial_no].presence || Array(params[:serials]).first
    return_errors!('serial_no is required') if serial.blank?
    actor = App.cu.user_obj&.full_name
    App.db.transaction do
      unit = ProductUnit.where(serial_no: serial).for_update.first or return_errors!('Unit not found', 404)
      return_errors!('Only a sold unit can be replaced') unless unit.status == 'sold'
      issue_replacement!(unit, actor, params[:notes])
      @replaced = unit.reload.as_pos
    end
    return_success(@replaced)
  rescue => e
    log_and_fail('replacement', e)
  end

  private

  # Old unit -> replaced; a fresh available unit of the same product is issued to
  # the same customer (leaves available stock). Old unit does NOT return to stock.
  def issue_replacement!(unit, actor, notes)
    product = unit.product
    from = unit.status
    unit.update(status: 'replaced', inspection_notes: notes, disposed_by: actor)
    write_ledger(unit, 'replacement', qty: 0, from: from, to: 'replaced',
                 party: unit.customer_name, actor: actor, balance: product.stock)

    repl = ProductUnit.where(product_id: product.id, status: 'available')
                      .order(:purchased_at, :id).for_update.first
    return_errors!("No available stock to issue a replacement for #{product.name}", 400) unless repl
    repl.update(status: 'sold', customer_id: unit.customer_id, customer_name: unit.customer_name,
                sales_invoice_id: unit.sales_invoice_id, sold_price: unit.sold_price, sold_at: Time.now)
    Product.where(id: product.id).update(stock: Sequel.-(:stock, 1), qty_sold: Sequel.+(:qty_sold, 1))
    write_ledger(repl, 'replacement', qty: -1, from: 'available', to: 'sold',
                 party: unit.customer_name, price: unit.sold_price, actor: actor,
                 balance: Product[product.id].stock)
  end

  # Quarantined unit -> available, available stock += 1.
  def restock!(unit, mtype, actor, notes)
    from = unit.status
    unit.update(status: 'available', inspection_notes: notes, disposed_by: actor,
                customer_id: nil, customer_name: nil, sales_invoice_id: nil, sales_item_id: nil,
                sold_price: nil, sold_at: nil)
    Product.where(id: unit.product_id).update(stock: Sequel.+(:stock, 1))
    write_ledger(unit, mtype, qty: 1, from: from, to: 'available',
                 party: nil, actor: actor, balance: Product[unit.product_id].stock)
  end

  def write_ledger(unit, mtype, qty:, from:, to:, party:, actor:, balance:, price: nil)
    InventoryLedger.create(
      movement_type: mtype, product_id: unit.product_id, product_unit_id: unit.id,
      serial_no: unit.serial_no, qty: qty, from_status: from, to_status: to,
      party_name: party, branch_id: unit.branch_id, branch_name: unit.branch&.name,
      balance_after: balance, unit_price: price, actor: actor, occurred_at: Time.now
    )
  end

  def compat_txn(unit, type, status, actor)
    Transaction.create(
      txn_type: type, branch_id: unit.branch_id, quantity: 1, actor: actor, status: status,
      product_name: unit.product&.name, barcode: unit.serial_no,
      branch_name: unit.branch&.name, occurred_at: Time.now
    )
  end

  def locked_unit!
    id = rp[:id] || params[:id]
    ProductUnit.where(id: id).for_update.first || return_errors!("No unit found with id: #{id}", 404)
  end

  def log_and_fail(label, e)
    raise e if e.is_a?(Sequel::Rollback)
    App.logger.error("#{label} error: #{e.message}")
    App.logger.error(e.backtrace.join("\n"))
    return_errors!("Could not complete #{label}: #{e.message}", 400)
  end
end
