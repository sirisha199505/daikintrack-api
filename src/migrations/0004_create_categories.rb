Sequel.migration do
  change do
    create_table(:categories) do
      primary_key :id

      # Stable url-friendly identifier (e.g. "split"). Mirrors the frontend ids.
      String :slug, null: false
      String :name, null: false
      String :color

      Boolean :active, default: true

      Integer :created_by
      Integer :updated_by
      DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
      DateTime :updated_at, default: Sequel::CURRENT_TIMESTAMP

      index :slug, unique: true
      index :active
    end
  end
end
