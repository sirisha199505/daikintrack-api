# Demo data so EVERY inventory screen is populated for a walkthrough:
#   • Suppliers & Customers (master data)
#   • A sample Purchase invoice  -> Purchase Register, serials, Stock Ledger, History
#   • A sample Sales invoice      -> Sales Register, sold serials, Ledger, History
#   • A customer Return           -> Quarantine board, Ledger, History
#
# Idempotent (skips rows that already exist). Everything is tagged so it can be
# wiped after the demo with:  DB_URL=... ruby scripts/clear_demo.rb
#
# Usage: DB_URL="postgres://..." ruby scripts/seed_demo.rb
require 'sequel'
require 'securerandom'

db_url = ENV.fetch('DB_URL') { abort 'DB_URL is required' }
DB = Sequel.connect(db_url)
DB.extension :pg_array, :pg_json
now = Time.now

# ---------- 1. Master data ----------
SUPPLIERS = [
  { name: 'Daikin Airconditioning India Pvt Ltd', gstin: '06AAACD1234M1Z2', contact: 'Rohit Mehra', phone: '+91 124 4567800', email: 'sales@daikinindia.com', address: 'Plot 12, Sector 18, Gurugram, Haryana' },
  { name: 'Blue Star Distributors', gstin: '27AAACB5678N1Z9', contact: 'Anita Shah', phone: '+91 22 6789 0011', email: 'orders@bluestardist.in', address: 'Andheri MIDC, Mumbai, Maharashtra' },
  { name: 'Voltas Supply Co.', gstin: '29AAACV4321P1Z3', contact: 'Karthik Rao', phone: '+91 80 4112 9000', email: 'supply@voltasco.in', address: 'Whitefield, Bengaluru, Karnataka' },
  { name: 'CoolTech Wholesale', gstin: '07AAACC8765Q1Z7', contact: 'Sunil Gupta', phone: '+91 11 4055 2200', email: 'hello@cooltechws.in', address: 'Okhla Phase II, New Delhi' },
]
CUSTOMERS = [
  { name: 'Sharma Electronics', gstin: '06AABCS1111A1Z5', contact: 'Vikas Sharma', phone: '+91 98110 11223', email: 'vikas@sharmaelec.in', address: 'Lajpat Nagar, New Delhi' },
  { name: 'Green Valley Hotels', gstin: '27AABCG2222B1Z4', contact: 'Meera Iyer', phone: '+91 99200 33445', email: 'purchase@greenvalley.in', address: 'Bandra West, Mumbai' },
  { name: 'TechPark Facilities Pvt Ltd', gstin: '29AABCT3333C1Z3', contact: 'Arvind Kumar', phone: '+91 98860 55667', email: 'facilities@techpark.in', address: 'Electronic City, Bengaluru' },
  { name: 'Sunrise Apartments RWA', contact: 'Latha Nair', phone: '+91 90030 77889', email: 'rwa.sunrise@gmail.com', address: 'Salt Lake, Kolkata' },
  { name: 'Mahesh Kumar (Retail)', phone: '+91 99450 99001', address: 'JP Nagar, Bengaluru' },
  { name: 'City General Hospital', gstin: '07AABCC4444D1Z2', contact: 'Dr. Reddy', phone: '+91 11 2345 6789', email: 'admin@citygenhosp.in', address: 'Karol Bagh, New Delhi' },
]

def upsert(table, rows, prefix)
  rows.each_with_index do |r, i|
    next if DB[table].where(name: r[:name]).first
    DB[table].insert(r.merge(code: r[:code] || format('%s-%03d', prefix, i + 1),
      active: true, created_at: Time.now, updated_at: Time.now))
  end
end
upsert(:suppliers, SUPPLIERS, 'DEMO-SUP')
upsert(:customers, CUSTOMERS, 'DEMO-CUS')
puts "Master data ready — suppliers: #{DB[:suppliers].count}, customers: #{DB[:customers].count}."

# ---------- 2. Sample transactions ----------
def gen_serial(pid)
  100.times { c = "SN-#{pid}-#{SecureRandom.alphanumeric(8).upcase}"; return c unless DB[:product_units].where(serial_no: c).first }
  raise "serial gen failed"
end

if DB[:purchase_invoices].where(invoice_no: 'PINV-DEMO-1').first
  puts "Sample transactions already present — skipping."
else
  product = DB[:products].where(active: true).exclude(branch_id: nil).order(:id).first
  if product.nil?
    puts "No product available to attach demo transactions to — master data only."
  else
    supplier = DB[:suppliers].where(Sequel.like(:code, 'DEMO-SUP%')).first || DB[:suppliers].first
    customer = DB[:customers].where(Sequel.like(:code, 'DEMO-CUS%')).first || DB[:customers].first
    branch   = DB[:branches].where(id: product[:branch_id]).first
    pid      = product[:id]
    cost     = (product[:price].to_i.positive? ? product[:price].to_i : 30000)
    price    = (cost * 1.25).round

    DB.transaction do
      # --- PURCHASE (5 units) ---
      run = product[:stock].to_i
      pinv = DB[:purchase_invoices].insert(invoice_no: 'PINV-DEMO-1', supplier_invoice_no: 'BILL-7781',
        supplier_id: supplier[:id], supplier_name: supplier[:name], branch_id: branch[:id], branch_name: branch[:name],
        status: 'posted', actor: 'Demo', notes: 'Demo purchase', occurred_at: now - 86400 * 3,
        total_qty: 5, total_amount: 5 * cost, created_at: now, updated_at: now)
      pitem = DB[:purchase_items].insert(purchase_invoice_id: pinv, product_id: pid, product_name: product[:name],
        barcode: product[:barcode], quantity: 5, cost_price: cost, line_total: 5 * cost, created_at: now, updated_at: now)
      5.times do
        run += 1
        uid = DB[:product_units].insert(serial_no: gen_serial(pid), product_id: pid, branch_id: branch[:id],
          purchase_invoice_id: pinv, purchase_item_id: pitem, supplier_id: supplier[:id], supplier_name: supplier[:name],
          cost_price: cost, purchased_at: now - 86400 * 3, status: 'available', created_at: now, updated_at: now)
        DB[:inventory_ledgers].insert(movement_type: 'purchase', product_id: pid, product_unit_id: uid,
          serial_no: DB[:product_units].where(id: uid).get(:serial_no), qty: 1, to_status: 'available',
          invoice_no: 'PINV-DEMO-1', party_name: supplier[:name], branch_id: branch[:id], branch_name: branch[:name],
          balance_after: run, unit_price: cost, actor: 'Demo', ref_invoice_id: pinv, occurred_at: now - 86400 * 3, created_at: now)
      end
      DB[:products].where(id: pid).update(stock: run, qty_purchased: product[:stock].to_i + 5)
      DB[:transactions].insert(invoice_no: 'PINV-DEMO-1', txn_type: 'in', branch_id: branch[:id], quantity: 5,
        actor: 'Demo', status: 'Checked In', product_name: "Purchase PINV-DEMO-1", branch_name: branch[:name],
        occurred_at: now - 86400 * 3, created_at: now, updated_at: now)

      # --- SALE (2 units, FIFO) ---
      units = DB[:product_units].where(product_id: pid, status: 'available').order(:purchased_at, :id).limit(2).all
      sinv = DB[:sales_invoices].insert(invoice_no: 'SINV-DEMO-1', customer_id: customer[:id], customer_name: customer[:name],
        branch_id: branch[:id], branch_name: branch[:name], status: 'posted', actor: 'Demo', notes: 'Demo sale',
        occurred_at: now - 86400, total_qty: 2, total_amount: 2 * price, created_at: now, updated_at: now)
      sitem = DB[:sales_items].insert(sales_invoice_id: sinv, product_id: pid, product_name: product[:name],
        barcode: product[:barcode], quantity: 2, sold_price: price, line_total: 2 * price, created_at: now, updated_at: now)
      units.each do |u|
        run -= 1
        DB[:product_units].where(id: u[:id]).update(status: 'sold', sales_invoice_id: sinv, sales_item_id: sitem,
          customer_id: customer[:id], customer_name: customer[:name], sold_price: price, sold_at: now - 86400, updated_at: now)
        DB[:inventory_ledgers].insert(movement_type: 'sale', product_id: pid, product_unit_id: u[:id], serial_no: u[:serial_no],
          qty: -1, from_status: 'available', to_status: 'sold', invoice_no: 'SINV-DEMO-1', party_name: customer[:name],
          branch_id: branch[:id], branch_name: branch[:name], balance_after: run, unit_price: price, actor: 'Demo',
          ref_invoice_id: sinv, occurred_at: now - 86400, created_at: now)
      end
      DB[:products].where(id: pid).update(stock: run, qty_sold: 2)
      DB[:transactions].insert(invoice_no: 'SINV-DEMO-1', txn_type: 'out', branch_id: branch[:id], quantity: 2,
        actor: 'Demo', status: 'Checked Out', product_name: "Sale SINV-DEMO-1", branch_name: branch[:name],
        occurred_at: now - 86400, created_at: now, updated_at: now)

      # --- RETURN (1 sold unit -> quarantine) ---
      ret = units.first
      DB[:product_units].where(id: ret[:id]).update(status: 'returned', return_reason: 'Compressor noise reported', updated_at: now)
      DB[:products].where(id: pid).update(qty_returned: 1)
      DB[:inventory_ledgers].insert(movement_type: 'return', product_id: pid, product_unit_id: ret[:id], serial_no: ret[:serial_no],
        qty: 1, from_status: 'sold', to_status: 'returned', invoice_no: 'SINV-DEMO-1', party_name: customer[:name],
        branch_id: branch[:id], branch_name: branch[:name], balance_after: run, unit_price: price, actor: 'Demo',
        occurred_at: now, created_at: now)
      DB[:transactions].insert(txn_type: 'in', branch_id: branch[:id], quantity: 1, actor: 'Demo', status: 'Returned',
        product_name: product[:name], barcode: ret[:serial_no], branch_name: branch[:name], occurred_at: now, created_at: now, updated_at: now)
    end
    puts "Sample flow created on '#{product[:name]}' — PINV-DEMO-1 (purchase), SINV-DEMO-1 (sale), 1 return in quarantine."
  end
end

puts "Done. Remove later with: ruby scripts/clear_demo.rb"
