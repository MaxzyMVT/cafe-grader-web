class AddScoreboardIncludeAdminsConfig < ActiveRecord::Migration[8.0]
  def up
    GraderConfiguration.where(key: 'system.scoreboard_include_admins').first_or_create(value_type: 'boolean', value: 'false', description: 'Include admins in the public scoreboard')
  end

  def down
    GraderConfiguration.where(key: 'system.scoreboard_include_admins').destroy_all
  end
end
