Sequel.migration do
  up do
    alter_table(:users) do
      drop_column :client_id
    end
    drop_table? :clients
  end

  down do
    create_table(:clients) do
      primary_key :id
      String :name, null: false
      String :email, unique: true
      column :assets, :jsonb, default: '[]'
      Boolean :active, default: true
      Integer :created_by
      Integer :updated_by
      DateTime :created_at, default: Sequel::CURRENT_TIMESTAMP
      DateTime :updated_at, default: Sequel::CURRENT_TIMESTAMP

      index :email, unique: true
      index :active
    end

    alter_table(:users) do
      add_column :client_id, Integer
    end
  end
end
