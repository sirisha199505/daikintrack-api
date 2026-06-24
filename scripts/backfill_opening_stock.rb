# Back-fills the per-unit serial inventory for stock that existed before the
# Tally-style upgrade. For every product with stock > 0 it creates (idempotently)
# a synthetic "Opening Balance" purchase invoice per branch, one serialised
# product_unit per unit of stock (status 'available'), and an 'opening' ledger
# row per unit. Safe to run multiple times — keyed off a deterministic per-branch
# invoice number ("OPEN-<branch_slug>").
#
# Usage: DB_URL="postgres://..." ruby scripts/backfill_opening_stock.rb
require 'sequel'
require 'securerandom'

db_url = ENV.fetch('DB_URL') { abort 'DB_URL is required' }
DB = Sequel.connect(db_url)
DB.extension :pg_array, :pg_json

now = Time.now

# One shared synthetic supplier so opening stock groups cleanly in reports.
supplier_id = DB[:suppliers].where(name: 'Opening Balance').get(:id) ||
              DB[:suppliers].insert(name: 'Opening Balance', code: 'OPENING',
                                     active: true, created_at: now, updated_at: now)

def gen_serial(db, product_id)
  prefix = "SN-#{product_id}-"
  100.times do
    cand = "#{prefix}#{SecureRandom.alphanumeric(8).upcase}"
    return cand unless db[:product_units].where(serial_no: cand).first
  end
  raise "Unable to generate a unique serial number for product #{product_id}"
end

created_units = 0
created_invoices = 0

DB[:branches].each do |branch|
  products = DB[:products].where(branch_id: branch[:id]).where { stock > 0 }.all
  next if products.empty?

  invoice_no = "OPEN-#{branch[:slug]}"
  next if DB[:purchase_invoices].where(invoice_no: invoice_no).first # idempotent

  DB.transaction do
    total_qty = 0
    total_amt = 0
    invoice_id = DB[:purchase_invoices].insert(
      invoice_no: invoice_no, supplier_id: supplier_id, supplier_name: 'Opening Balance',
      branch_id: branch[:id], branch_name: branch[:name], status: 'posted',
      actor: 'system', notes: 'Opening balance back-fill', occurred_at: now,
      total_qty: 0, total_amount: 0, created_at: now, updated_at: now
    )

    products.each do |p|
      qty  = p[:stock].to_i
      cost = p[:price].to_i
      item_id = DB[:purchase_items].insert(
        purchase_invoice_id: invoice_id, product_id: p[:id],
        product_name: p[:name], barcode: p[:barcode],
        quantity: qty, cost_price: cost, line_total: qty * cost,
        created_at: now, updated_at: now
      )

      running = 0
      qty.times do
        running += 1
        unit_id = DB[:product_units].insert(
          serial_no: gen_serial(DB, p[:id]), product_id: p[:id], branch_id: branch[:id],
          purchase_invoice_id: invoice_id, purchase_item_id: item_id, supplier_id: supplier_id,
          supplier_name: 'Opening Balance', cost_price: cost, purchased_at: now,
          status: 'available', created_at: now, updated_at: now
        )
        DB[:inventory_ledgers].insert(
          movement_type: 'opening', product_id: p[:id], product_unit_id: unit_id,
          serial_no: DB[:product_units].where(id: unit_id).get(:serial_no), qty: 1,
          to_status: 'available', invoice_no: invoice_no, party_name: 'Opening Balance',
          branch_id: branch[:id], branch_name: branch[:name], balance_after: running,
          unit_price: cost, actor: 'system', ref_invoice_id: invoice_id, occurred_at: now,
          created_at: now
        )
        created_units += 1
      end

      # stock already reflects opening qty; align the purchased counter.
      DB[:products].where(id: p[:id]).update(qty_purchased: qty, updated_at: now)
      total_qty += qty
      total_amt += qty * cost
    end

    DB[:purchase_invoices].where(id: invoice_id).update(total_qty: total_qty, total_amount: total_amt)
    created_invoices += 1
    puts "  #{branch[:name]}: #{invoice_no} (#{products.size} products, #{total_qty} units)"
  end
end

puts "Opening-balance back-fill complete. Invoices: #{created_invoices}, units: #{created_units}."
