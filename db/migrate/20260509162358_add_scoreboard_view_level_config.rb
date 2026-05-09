class AddScoreboardViewLevelConfig < ActiveRecord::Migration[8.0]
  def up
    ::Current.audit_disabled = true
    GraderConfiguration.where(key: 'system.scoreboard_view_level').first_or_create(
      value_type: 'string', 
      value: 'user', 
      description: 'Scoreboard access level: all (public), user (logged-in users), admin (only admins)'
    )
    GraderConfiguration.where(key: 'system.scoreboard_public_accessible').destroy_all
  end

  def down
    ::Current.audit_disabled = true
    GraderConfiguration.where(key: 'system.scoreboard_view_level').destroy_all
    GraderConfiguration.where(key: 'system.scoreboard_public_accessible').first_or_create(
      value_type: 'boolean', 
      value: 'false', 
      description: 'Enable public scoreboard'
    )
  end
end
