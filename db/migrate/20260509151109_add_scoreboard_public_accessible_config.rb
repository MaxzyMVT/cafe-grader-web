class AddScoreboardPublicAccessibleConfig < ActiveRecord::Migration[8.0]
  def up
    GraderConfiguration.where(key: 'system.scoreboard_public_accessible').first_or_create(value_type: 'boolean', value: 'false', description: 'Enable public scoreboard')
  end

  def down
    GraderConfiguration.where(key: 'system.scoreboard_public_accessible').destroy_all
  end
end

