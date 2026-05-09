class AddScoreboardEnabledConfig < ActiveRecord::Migration[8.0]
  def up
    GraderConfiguration.where(key: 'system.scoreboard_enabled').first_or_create(value_type: 'boolean', value: 'true', description: 'Enable the Real-time Score Board feature')
  end

  def down
    GraderConfiguration.where(key: 'system.scoreboard_enabled').destroy_all
  end
end
