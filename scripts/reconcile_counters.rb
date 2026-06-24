# Recomputes the denormalised counters on products from the authoritative
# product_units rows, repairing any drift. `stock` = available units;
# qty_purchased / qty_sold / qty_returned are lifetime totals.
#
# Usage: DB_URL="postgres://..." ruby scripts/reconcile_counters.rb
require 'sequel'

db_url = ENV.fetch('DB_URL') { abort 'DB_URL is required' }
DB = Sequel.connect(db_url)
DB.extension :pg_array, :pg_json

fixed = 0
DB[:products].select(:id, :stock, :qty_purchased, :qty_sold, :qty_returned).each do |p|
  units = DB[:product_units].where(product_id: p[:id])
  available = units.where(status: 'available').count
  # Lifetime purchased = every unit ever created for the product.
  purchased = units.count
  sold      = units.where(status: 'sold').count
  returned  = DB[:inventory_ledgers].where(product_id: p[:id], movement_type: 'return').count

  if [p[:stock], p[:qty_purchased], p[:qty_sold], p[:qty_returned]] != [available, purchased, sold, returned]
    DB[:products].where(id: p[:id]).update(
      stock: available, qty_purchased: purchased, qty_sold: sold,
      qty_returned: returned, updated_at: Time.now
    )
    fixed += 1
  end
end

puts "Reconcile complete. Products updated: #{fixed}."
