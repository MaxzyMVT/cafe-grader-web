class AddGroupScoreTypeConfig < ActiveRecord::Migration[8.0]
  def up
    GraderConfiguration.where(key: 'system.group_score_type').first_or_create(
      value_type: 'string',
      value: 'group_sum',
      description: 'Group Scoreboard calculation mode: group_sum (sum of user scores) or group_max (max score per problem)'
    )
  end

  def down
    GraderConfiguration.where(key: 'system.group_score_type').destroy_all
  end
end
