# Seeds reference data (branches, categories) and the admin login user.
# Idempotent: safe to run multiple times. Mirrors Daikintrack/src/data/seed.js.
# Usage: DB_URL="postgres://..." ruby scripts/seed.rb
require 'sequel'
require 'bcrypt'

db_url = ENV.fetch('DB_URL') { abort 'DB_URL is required' }
DB = Sequel.connect(db_url)
DB.extension :pg_array, :pg_json

now = Time.now

BRANCHES = [
  { slug: 'north', name: 'North Hub', code: 'WH-NORTH', location: 'Delhi NCR',
    address: 'Plot 12, Udyog Vihar Phase IV, Gurugram, Haryana 122015',
    contact: '+91 11 4055 1200', manager: 'Rahul Verma', status: 'Active',
    color: '#0098d8', gradient: 'linear-gradient(135deg, #0c4a6e 0%, #0284c7 50%, #06b6d4 100%)' },
  { slug: 'west', name: 'West Hub', code: 'WH-WEST', location: 'Mumbai',
    address: 'Warehouse 7, MIDC Andheri East, Mumbai, Maharashtra 400093',
    contact: '+91 22 6712 4400', manager: 'Priya Nair', status: 'Active',
    color: '#8b5cf6', gradient: 'linear-gradient(135deg, #312e81 0%, #7c3aed 50%, #d946ef 100%)' },
  { slug: 'south', name: 'South Hub', code: 'WH-SOUTH', location: 'Bengaluru',
    address: 'No. 45, Bommasandra Industrial Area, Bengaluru, Karnataka 560099',
    contact: '+91 80 4123 7700', manager: 'Arjun Reddy', status: 'Active',
    color: '#16a34a', gradient: 'linear-gradient(135deg, #065f46 0%, #0d9488 50%, #0ea5e9 100%)' },
  { slug: 'east', name: 'East Hub', code: 'WH-EAST', location: 'Kolkata',
    address: 'Unit 3, Salt Lake Sector V, Kolkata, West Bengal 700091',
    contact: '+91 33 4011 9900', manager: 'Sneha Das', status: 'Active',
    color: '#f59e0b', gradient: 'linear-gradient(135deg, #9f1239 0%, #ea580c 50%, #f59e0b 100%)' },
]

CATEGORIES = [
  { slug: 'split',         name: 'Split AC',                 color: '#22b8e6' },
  { slug: 'window',        name: 'Window AC',                color: '#16a34a' },
  { slug: 'cassette',      name: 'Cassette AC',              color: '#f59e0b' },
  { slug: 'ducted',        name: 'Ducted AC',                color: '#ef4444' },
  { slug: 'vrv',           name: 'VRV / VRF Systems',        color: '#8b5cf6' },
  { slug: 'chillers',      name: 'Chillers',                 color: '#14b8a6' },
  { slug: 'purifier',      name: 'Air Purifiers',            color: '#6366f1' },
  { slug: 'refrigeration', name: 'Commercial Refrigeration', color: '#f97316' },
]

branch_ids = {}
BRANCHES.each do |b|
  row = DB[:branches].where(slug: b[:slug]).first
  if row
    branch_ids[b[:slug]] = row[:id]
  else
    branch_ids[b[:slug]] = DB[:branches].insert(b.merge(active: true, created_at: now, updated_at: now))
  end
end
puts "Branches: #{branch_ids.size}"

CATEGORIES.each do |c|
  next if DB[:categories].where(slug: c[:slug]).first
  DB[:categories].insert(c.merge(active: true, created_at: now, updated_at: now))
end
puts "Categories: #{DB[:categories].count}"

# Only the admin login is seeded. Create store managers / distributors from the
# in-app User Management screen so the seed never resurrects deleted accounts.
USERS = [
  { full_name: 'System Admin',  username: 'admin',  password: 'admin',   email: 'admin@daikin.in',
    phone_number: '+91 98100 00001', role: 1, branch_id: nil },
]

USERS.each do |u|
  next if DB[:users].where(username: u[:username]).first
  pwd = u.delete(:password)
  DB[:users].insert(u.merge(
    encoded_password: BCrypt::Password.create(pwd),
    status: 'Active', active: true, created_at: now, updated_at: now
  ))
end
puts "Users: #{DB[:users].count} (login with admin/admin)"

DB.disconnect
puts 'Seed complete.'
