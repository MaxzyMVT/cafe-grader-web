class AddThemeToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :theme, :string, default: 'default'
  end
end
