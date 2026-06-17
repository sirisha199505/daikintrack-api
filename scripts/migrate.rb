# Standalone migration runner (no app bundle required).
# Usage: DB_URL="postgres://..." ruby scripts/migrate.rb [target_version]
require 'sequel'
Sequel.extension :migration

db_url = ENV.fetch('DB_URL') { abort 'DB_URL is required' }
target = ARGV[0] ? ARGV[0].to_i : nil

migrations_dir = File.expand_path('../src/migrations', __dir__)

Sequel.connect(db_url) do |db|
  db.extension :pg_array, :pg_json
  if target
    Sequel::Migrator.run(db, migrations_dir, target: target)
  else
    Sequel::Migrator.run(db, migrations_dir)
  end
  version = db[:schema_info].first[:version] rescue 'n/a'
  puts "Migrations complete. schema_info.version = #{version}"
  puts "Tables: #{db.tables.sort.join(', ')}"
end
