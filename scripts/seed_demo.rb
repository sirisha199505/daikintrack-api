# Demo-only master data: a handful of suppliers and customers so the store
# manager can run Check-In / Check-Out live during a demo. Idempotent (skips
# rows that already exist by name). Every row is tagged with a DEMO- code so it
# can be removed in one statement after the demo:
#
#   DELETE FROM product_units WHERE supplier_id IN (SELECT id FROM suppliers WHERE code LIKE 'DEMO-%');
#   -- (only needed if you also created purchases against demo suppliers)
#   DELETE FROM customers WHERE code LIKE 'DEMO-%';
#   DELETE FROM suppliers WHERE code LIKE 'DEMO-%';
#
# Usage: DB_URL="postgres://..." ruby scripts/seed_demo.rb
require 'sequel'

db_url = ENV.fetch('DB_URL') { abort 'DB_URL is required' }
DB = Sequel.connect(db_url)
DB.extension :pg_array, :pg_json
now = Time.now

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
  created = 0
  rows.each_with_index do |r, i|
    next if DB[table].where(name: r[:name]).first
    DB[table].insert(r.merge(
      code: r[:code] || format('%s-%03d', prefix, i + 1),
      active: true, created_at: Time.now, updated_at: Time.now
    ))
    created += 1
  end
  created
end

s = upsert(:suppliers, SUPPLIERS, 'DEMO-SUP')
c = upsert(:customers, CUSTOMERS, 'DEMO-CUS')
puts "Demo data ready. Suppliers added: #{s} (total #{DB[:suppliers].count}), customers added: #{c} (total #{DB[:customers].count})."
puts "To remove after the demo: DELETE FROM customers WHERE code LIKE 'DEMO-%'; DELETE FROM suppliers WHERE code LIKE 'DEMO-%';"
