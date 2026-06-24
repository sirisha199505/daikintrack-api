# End-to-end smoke test for the Tally-style inventory API. Drives a running
# server over HTTP (stdlib Net::HTTP, no extra gems). Boot the app first, then:
#   BASE=http://127.0.0.1:9876 ruby scripts/smoke_inventory.rb
require 'net/http'
require 'uri'
require 'json'

BASE = ENV.fetch('BASE', 'http://127.0.0.1:9876')

$tok = nil
def req(method, path, data = nil)
  uri = URI("#{BASE}#{path}")
  klass = method == :post ? Net::HTTP::Post : Net::HTTP::Get
  r = klass.new(uri)
  r['Content-Type'] = 'application/json'
  r['Authorization'] = "Bearer #{$tok}" if $tok
  r.body = { data: data }.to_json if data
  res = Net::HTTP.start(uri.host, uri.port) { |h| h.request(r) }
  JSON.parse(res.body)
rescue => e
  { 'status' => 'error', 'data' => e.message }
end
def jpost(path, data) = req(:post, path, data)
def jget(path)        = req(:get, path)
def ok!(label, cond)  ; puts "#{cond ? '✓' : '✗ FAIL'}  #{label}" ; (@fails ||= 0); @fails += 1 unless cond ; end

# 1. login
res = jpost('/api/login', { username: 'admin', password: 'admin' })
$tok = res.dig('data', 'token')
ok!('login admin', !$tok.nil?)

# 2. master data
sup = jpost('/api/suppliers', { name: 'Daikin Distributors Pvt Ltd', gstin: '29ABCDE1234F1Z5', phone: '9999900000' })
sup_id = sup.dig('data', 'id'); ok!('create supplier', !sup_id.nil?)
cus = jpost('/api/customers', { name: 'Cool Air Services', phone: '8888800000' })
cus_id = cus.dig('data', 'id'); ok!('create customer', !cus_id.nil?)

# pick two products
prods = jget('/api/products?page_size=300')['data']
p1 = prods.find { |p| p['name'] == 'Test Split AC 1.5T' }
p2 = prods.find { |p| p['name'] == 'Test Window AC 1T' }
ok!('found seed products', p1 && p2)
p1_before = p1['stock']

# 3. purchase invoice (check-in): +5 of p1, +3 of p2
pur = jpost('/api/purchases', {
  supplier_id: sup_id, supplier_invoice_no: 'SUP-001',
  items: [ { product_id: p1['id'], quantity: 5, cost_price: 40000 },
           { product_id: p2['id'], quantity: 3, cost_price: 25000 } ]
})
pinv = pur['data']
ok!('purchase posted', pinv && pinv['invoice_no'].to_s.start_with?('PINV-'))
ok!('purchase total_qty=8', pinv && pinv['total_qty'] == 8)
serials = pinv['items'].flat_map { |i| i['serials'] }
ok!('purchase generated 8 serials', serials.size == 8)
ok!('serials are unique', serials.map { |s| s['serial_no'] }.uniq.size == 8)

p1_after = jget("/api/products/#{p1['id']}")['data']['stock']
ok!('p1 stock rose by 5', p1_after == p1_before + 5)

# 4. sales invoice (check-out): sell 2 of p1
sale = jpost('/api/sales', {
  customer_id: cus_id,
  items: [ { product_id: p1['id'], quantity: 2, sold_price: 52000 } ]
})
sinv = sale['data']
ok!('sale posted', sinv && sinv['invoice_no'].to_s.start_with?('SINV-'))
sold_serials = sinv['items'].first['serials'].map { |s| s['serial_no'] }
ok!('sale linked 2 serials', sold_serials.size == 2)
p1_after_sale = jget("/api/products/#{p1['id']}")['data']['stock']
ok!('p1 stock dropped by 2', p1_after_sale == p1_before + 5 - 2)

# 5. customer return -> quarantine (NOT back to stock)
ret_serial = sold_serials.first
ret = jpost('/api/returns', { serial_no: ret_serial, reason: 'Compressor noise' })
ok!('return accepted', ret['status'] == 'success')
unit = jget("/api/units/by-serial?serial_no=#{ret_serial}")['data']
ok!('returned unit status=returned', unit['status'] == 'returned')
stock_after_return = jget("/api/products/#{p1['id']}")['data']['stock']
ok!('return did NOT restock', stock_after_return == p1_after_sale)
unit_id = unit['id']

# 6. inspection -> dispose approve -> restock
jpost("/api/units/#{unit_id}/inspect", { notes: 'Bench test' })
u2 = jget("/api/units/#{unit_id}")['data']
ok!('unit under_inspection', u2['status'] == 'under_inspection')
jpost("/api/units/#{unit_id}/dispose", { decision: 'approve', notes: 'OK after reset' })
u3 = jget("/api/units/#{unit_id}")['data']
ok!('approved unit available again', u3['status'] == 'available')
stock_after_approve = jget("/api/products/#{p1['id']}")['data']['stock']
ok!('approve restocked +1', stock_after_approve == stock_after_return + 1)

# 7. scrap path on another sold unit (return then scrap)
scrap_serial = sold_serials.last
jpost('/api/returns', { serial_no: scrap_serial, reason: 'Cracked panel' })
su = jget("/api/units/by-serial?serial_no=#{scrap_serial}")['data']
jpost("/api/units/#{su['id']}/dispose", { decision: 'scrap', notes: 'Beyond repair' })
su2 = jget("/api/units/#{su['id']}")['data']
ok!('scrapped unit damaged', su2['status'] == 'damaged')

# 8. reports
osr = jget('/api/reports/outstanding-stock')
ok!('outstanding-stock report', osr['status'] == 'success' && osr['data'].is_a?(Array))
preg = jget('/api/reports/purchase-register')
ok!('purchase-register totals', preg.dig('totals', 'amount').to_i > 0)
sreg = jget('/api/reports/sales-register')
ok!('sales-register has rows', sreg['data'].is_a?(Array) && !sreg['data'].empty?)
led = jget("/api/reports/stock-ledger?product_id=#{p1['id']}")
ok!('stock-ledger ordered rows', led['data'].is_a?(Array) && led['data'].size >= 8)
tr = jget("/api/reports/traceability?serial_no=#{ret_serial}")
ok!('traceability trail', tr.dig('data', 'trail').is_a?(Array) && tr['data']['trail'].size >= 3)
srch = jget("/api/inventory/search?q=#{ret_serial}")
ok!('search finds serial', srch.dig('data', 'units').any? { |u| u['serial_no'] == ret_serial })
hist = jget("/api/product-history?serial_no=#{ret_serial}")
ok!('product-history endpoint', hist.dig('data', 'trail').is_a?(Array))

puts(@fails.to_i.zero? ? "\nALL CHECKS PASSED" : "\n#{@fails} CHECK(S) FAILED")
exit(@fails.to_i.zero? ? 0 : 1)
