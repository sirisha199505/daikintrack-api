# Removes everything seed_demo.rb created and reconciles product counters.
# Safe to run anytime; only touches DEMO-tagged rows (actor 'Demo', DEMO- codes,
# *-DEMO-* invoice numbers).
#
# Usage: DB_URL="postgres://..." ruby scripts/clear_demo.rb
require 'sequel'

db_url = ENV.fetch('DB_URL') { abort 'DB_URL is required' }
DB = Sequel.connect(db_url)
DB.extension :pg_array, :pg_json

DB.transaction do
  demo_purchases = DB[:purchase_invoices].where(Sequel.like(:invoice_no, 'PINV-DEMO%')).select_map(:id)

  led = DB[:inventory_ledgers].where(actor: 'Demo').delete
  txn = DB[:transactions].where(actor: 'Demo').delete
  # Units created by the demo purchase (sold/returned ones included).
  units = demo_purchases.empty? ? 0 : DB[:product_units].where(purchase_invoice_id: demo_purchases).delete
  sinv = DB[:sales_invoices].where(Sequel.like(:invoice_no, 'SINV-DEMO%')).delete   # cascades sales_items
  pinv = DB[:purchase_invoices].where(Sequel.like(:invoice_no, 'PINV-DEMO%')).delete # cascades purchase_items
  cus  = DB[:customers].where(Sequel.like(:code, 'DEMO-%')).delete
  sup  = DB[:suppliers].where(Sequel.like(:code, 'DEMO-%')).delete

  # Reconcile counters from the surviving units.
  DB[:products].select_map(:id).each do |id|
    u = DB[:product_units].where(product_id: id)
    DB[:products].where(id: id).update(
      stock: u.where(status: 'available').count,
      qty_purchased: u.count,
      qty_sold: u.where(status: 'sold').count,
      qty_returned: DB[:inventory_ledgers].where(product_id: id, movement_type: 'return').count,
      updated_at: Time.now
    )
  end

  puts "Removed demo data — ledger:#{led} transactions:#{txn} units:#{units} sales:#{sinv} purchases:#{pinv} customers:#{cus} suppliers:#{sup}. Counters reconciled."
end
