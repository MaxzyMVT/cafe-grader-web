class AddExtraSubLimitToContestsUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :contests_users, :extra_sub_limit, :integer, default: 0
  end
end
