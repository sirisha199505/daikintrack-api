Sequel.migration do
  change do
    create_table(:branches) do
      primary_key :id

      # Stable url-friendly identifier (e.g. "north"). Mirrors the frontend ids.
      String :slug, null: false
      String :name, null: false
      String :code           # e.g. WH-NORTH
      String :location       # e.g. "Delhi NCR"
      String :address
      String :contact
      String :manager
      String :status, default: 'Active'

      # Presentation colours used by the dashboard cards.
      String :color
      String :gradient

      Boolean :active, default: true

      Integer :created_by
      Integer :updated_by
      DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
      DateTime :updated_at, default: Sequel::CURRENT_TIMESTAMP

      index :slug, unique: true
      index :code
      index :active
    end
  end
end
