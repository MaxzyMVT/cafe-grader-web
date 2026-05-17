class ProblemStat < ApplicationRecord
  belongs_to :problem

  # Recompute stats for all problems in a single aggregate query,
  # then upsert into problem_stats.
  def self.recompute_all
    exclude_ids = User.joins(:roles).where(roles: { name: ['admin', 'problem_setter'] }).pluck(:id)
    exclude_ids += User.where(enabled: false).pluck(:id)
    exclude_ids += User.joins(:groups).where(groups: { enabled: false }).pluck(:id)
    exclude_ids = exclude_ids.uniq

    sql_cond = if exclude_ids.any?
                 "AND submissions.user_id NOT IN (#{exclude_ids.join(',')})"
               else
                 ""
               end

    rows = Problem.joins("LEFT JOIN submissions ON submissions.problem_id = problems.id #{sql_cond}")
      .group("problems.id")
      .pluck(
        Arel.sql("problems.id"),
        Arel.sql("COUNT(submissions.id)"),
        Arel.sql("COUNT(DISTINCT submissions.user_id)"),
        Arel.sql("COUNT(DISTINCT CASE WHEN submissions.points >= problems.full_score AND problems.full_score > 0 THEN submissions.user_id END)")
      )

    return if rows.empty?

    now = connection.quote(Time.current)
    values = rows.map do |problem_id, sub_count, attempted_count, solved_count|
      "(#{problem_id}, #{sub_count}, #{solved_count}, #{attempted_count}, #{now}, #{now})"
    end

    connection.execute(<<~SQL)
      INSERT INTO problem_stats (problem_id, sub_count, solved_count, attempted_count, created_at, updated_at)
      VALUES #{values.join(",\n")}
      ON DUPLICATE KEY UPDATE
        sub_count = VALUES(sub_count),
        solved_count = VALUES(solved_count),
        attempted_count = VALUES(attempted_count),
        updated_at = VALUES(updated_at)
    SQL
  end
end
