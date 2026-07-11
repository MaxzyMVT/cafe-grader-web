class ScoreboardController < ApplicationController
  before_action :check_public_scoreboard_access

  def index
    # Fetch all enabled users, problems that are available/reportable
    # For now we fetch all problems for simplicity
    @problems = Problem.available.visible_to_user(@current_user).default_order

    # Precompute associations for problem-group-user visibility check in scoreboard cells
    enabled_group_ids = Group.where(enabled: true).pluck(:id).to_set
    
    @problem_groups = Hash.new { |h, k| h[k] = Set.new }
    @problems_with_groups = GroupProblem.pluck(:problem_id).to_set
    GroupProblem.where(enabled: true).each do |gp|
      if enabled_group_ids.include?(gp.group_id)
        @problem_groups[gp.problem_id] << gp.group_id
      end
    end
    
    @user_groups = Hash.new { |h, k| h[k] = Set.new }
    GroupUser.where(enabled: true).each do |gu|
      if enabled_group_ids.include?(gu.group_id)
        @user_groups[gu.user_id] << gu.group_id
      end
    end

    @admin_setter_ids = User.joins(:roles).where(roles: { name: ['admin', 'problem_setter'] }).pluck(:id).to_set

    # Fetch users
    @users = User.where(enabled: true)
    
    unless GraderConfiguration['system.scoreboard_include_admins']
      exclude_ids = User.joins(:roles).where(roles: { name: ['admin', 'problem_setter'] }).pluck(:id)
      @users = @users.where.not(id: exclude_ids)
    end
    
    # Mode toggle: individual vs groups
    @mode = params[:mode] == 'group' ? 'group' : 'individual'
    
    # Calculate scores using the robust max_score_report scope
    # We now fetch raw max_score for problem cells and total deductions separately
    report_records = Submission.where(user: @users, problem: @problems).max_score_report(@problems, nil, nil)
    
    @scores = Hash.new { |h,k| h[k] = {} }
    report_records.each do |record|
      @scores[record.user_id][record.problem_id] = record.max_score.to_f
    end

    # For 0-score problems, we check if there's any submission that passes all test cases (highest score = 0)
    @zero_score_passes = Hash.new { |h, k| h[k] = {} }
    zero_score_problems = @problems.select { |p| p.effective_full_score == 0 }
    if zero_score_problems.any?
      zero_subs = Submission.where(user: @users, problem: zero_score_problems, viva_archived_at: nil)
      zero_subs.group_by { |s| [s.user_id, s.problem_id] }.each do |(user_id, problem_id), subs|
        prob = zero_score_problems.find { |p| p.id == problem_id }
        next unless prob
        tc_count = prob.live_dataset&.testcases&.count || 0
        has_pass = subs.any? do |s|
          if s.status.to_s == 'done'
            clean_gc = s.grader_comment.to_s.gsub(/[\[\]\s]/, '')
            if tc_count == 0
              true
            elsif clean_gc.match?(/\A[PS]+\z/)
              true
            else
              false
            end
          else
            false
          end
        end
        if has_pass
          @zero_score_passes[user_id][problem_id] = true
        end
      end
    end
    
    # Total deductions per user (all reveals for available problems)
    # 1. Problem hints
    hint_deductions = CommentReveal.where(user: @users)
                                   .joins("INNER JOIN comments ON comments.id = comment_reveals.comment_id AND comments.commentable_type = 'Problem'")
                                   .where(comments: { commentable_id: @problems.map(&:id) })
                                   .group(:user_id).sum('comments.cost')
    
    # 2. Submission assists
    submission_deductions = CommentReveal.where(user: @users)
                                          .joins("INNER JOIN comments ON comments.id = comment_reveals.comment_id AND comments.commentable_type = 'Submission'")
                                          .joins("INNER JOIN submissions ON submissions.id = comments.commentable_id")
                                          .where(submissions: { problem_id: @problems.map(&:id) })
                                          .group(:user_id).sum('comments.cost')

    @user_deductions = Hash.new(0)
    hint_deductions.each { |uid, cost| @user_deductions[uid] += cost }
    submission_deductions.each { |uid, cost| @user_deductions[uid] += cost }

    # Calculate First Blood bonuses for all problems once
    @first_blood_users = {} # problem_id => list of user IDs
    @problems.each do |p|
      if p.bonus_first_blood.to_f != 0
        n = p.respond_to?(:first_n_bloods) ? p.first_n_bloods : 0
        @first_blood_users[p.id] = p.first_n_blood_users(n).map(&:id)
      else
        @first_blood_users[p.id] = []
      end
    end

    prob_ids = @problems.map(&:id)
    zero_score_prob_ids = @problems.select { |p| p.effective_full_score == 0 }.map(&:id)
    
    passing_zero_sub_ids = []
    if zero_score_prob_ids.any?
      zero_subs = Submission.where(problem_id: zero_score_prob_ids, status: 'done', viva_archived_at: nil)
      zero_subs.each do |s|
        prob = @problems.find { |p| p.id == s.problem_id }
        next unless prob
        tc_count = prob.live_dataset&.testcases&.count || 0
        clean_gc = s.grader_comment.to_s.gsub(/[\[\]\s]/, '')
        passed = if tc_count == 0
          true
        elsif clean_gc.match?(/\A[PS]+\z/)
          true
        else
          false
        end
        passing_zero_sub_ids << s.id if passed
      end
    end

    # Fetch completion times and passed counts for sorting ties (earliest to reach final score)
    max_pts_sub = Submission.where(problem_id: prob_ids)
    if passing_zero_sub_ids.any?
      max_pts_sub = max_pts_sub.where("submissions.points > 0 OR submissions.id IN (?)", passing_zero_sub_ids)
    else
      max_pts_sub = max_pts_sub.where("submissions.points > 0")
    end
    max_pts_sub = max_pts_sub.group(:user_id, :problem_id).select('user_id, problem_id, MAX(points) as max_pts')

    first_bests = Submission.joins("INNER JOIN (#{max_pts_sub.to_sql}) mp ON submissions.user_id = mp.user_id AND submissions.problem_id = mp.problem_id AND submissions.points = mp.max_pts")
    first_bests = first_bests.group(:user_id, :problem_id).select('submissions.user_id, submissions.problem_id, MIN(submissions.submitted_at) as first_best_time')

    user_completion_times = Submission.from("(#{first_bests.to_sql}) fb")
      .group('fb.user_id')
      .select('fb.user_id, MAX(fb.first_best_time) as last_completed_time')
      .each_with_object({}) { |r, h| h[r.user_id] = r.last_completed_time }

    # Passed counts query
    best_subs = Submission.joins("INNER JOIN (#{first_bests.to_sql}) fb ON submissions.user_id = fb.user_id AND submissions.problem_id = fb.problem_id AND submissions.submitted_at = fb.first_best_time")
      .select('submissions.user_id, submissions.grader_comment, submissions.points, submissions.problem_id')
      
    passed_counts = Hash.new(0)
    best_subs.each do |sub|
      comment = sub.grader_comment.to_s.gsub(/[\[\]\s]/, '')
      if !comment.blank? && comment.match?(/\A[PS]*\z/)
        passed_counts[sub.user_id] += 1
      end
    end

    if @mode == 'individual'
      @leaderboard = @users.map do |u|
        raw_sum = 0
        @problems.each do |p|
          raw_sum += @scores[u.id][p.id] || 0
        end
        deducted = GraderConfiguration.enable_penalty? ? (@user_deductions[u.id] || 0) : 0
        
        # Calculate bonus for this user
        bonus = 0
        if GraderConfiguration.enable_bonus?
          if GraderConfiguration.show_first_bloods?
            @problems.each do |p|
              u_ids = @first_blood_users[p.id] || []
              if u_ids.include?(u.id)
                bonus += p.bonus_first_blood
              end
            end
          end
        end

        { user: u, total_score: [0.0, raw_sum - deducted + bonus].max, deducted_score: deducted, bonus_score: bonus }
      end
      # Sort by total_score desc, then by completion time asc, then by passed count desc, then by name
      @leaderboard.sort_by! do |entry|
        uid = entry[:user].id
        comp_time = user_completion_times[uid] || Time.zone.at(2147483647)
        pass_count = passed_counts[uid] || 0
        [-entry[:total_score], comp_time.to_i, -pass_count, entry[:user].full_name.to_s.downcase]
      end
      
      # Assign dense ranks
      current_rank = 1
      previous_score = nil
      @leaderboard.each_with_index do |entry, index|
        if previous_score != entry[:total_score]
          current_rank = index + 1
          previous_score = entry[:total_score]
        end
        entry[:rank] = current_rank
      end
      
      # Optional name sorting
      if params[:sort] == 'name'
        @leaderboard.sort_by! { |entry| [entry[:user].full_name.to_s.downcase, -entry[:total_score]] }
      end
    else
      # Group mode
      setter_admin_ids = User.joins(:roles).where(roles: { name: ['admin', 'problem_setter'] }).pluck(:id)
      @groups = Group.where(enabled: true)
      @group_score_type = GraderConfiguration['system.group_score_type'] || 'group_sum'
      @leaderboard = @groups.map do |g|
        group_users = g.users.where(enabled: true, groups_users: { enabled: true }).where.not(id: setter_admin_ids)
        group_total = 0
        group_deducted = 0
        group_bonus = 0
        group_members = group_users.map do |u|
          user_raw_total = 0
          @problems.each do |p|
            user_raw_total += @scores[u.id][p.id] || 0
          end
          user_deducted = GraderConfiguration.enable_penalty? ? (@user_deductions[u.id] || 0) : 0
          
          # Calculate bonus for this user
          user_bonus = 0
          if GraderConfiguration.enable_bonus?
            if GraderConfiguration.show_first_bloods?
              @problems.each do |p|
                u_ids = @first_blood_users[p.id] || []
                if u_ids.include?(u.id)
                  user_bonus += p.bonus_first_blood
                end
              end
            end
          end

          user_final = [0.0, user_raw_total - user_deducted + user_bonus].max
          group_total += user_final if @group_score_type == 'group_sum'
          group_deducted += user_deducted
          group_bonus += user_bonus
          { user: u, total_score: user_final, deducted_score: user_deducted, bonus_score: user_bonus }
        end

        if @group_score_type == 'group_max'
          group_raw_total = @problems.sum do |p|
            group_users.map { |u| @scores[u.id][p.id] || 0 }.max || 0
          end
          group_total = [0.0, group_raw_total - group_deducted + group_bonus].max
        end

        group_members.sort_by! do |m|
          uid = m[:user].id
          comp_time = user_completion_times[uid] || Time.zone.at(2147483647)
          pass_count = passed_counts[uid] || 0
          [-m[:total_score], comp_time.to_i, -pass_count, m[:user].full_name.to_s.downcase]
        end
        
        { group: g, total_score: group_total, deducted_score: group_deducted, bonus_score: group_bonus, members: group_members }
      end
      @leaderboard.sort_by! do |entry|
        group_member_uids = entry[:group].users.where(enabled: true, groups_users: { enabled: true }).pluck(:id)
        group_comp_time = group_member_uids.map { |uid| user_completion_times[uid] }.compact.max || Time.zone.at(2147483647)
        group_pass_count = group_member_uids.sum { |uid| passed_counts[uid] || 0 }
        [-entry[:total_score], group_comp_time.to_i, -group_pass_count, entry[:group].name.to_s.downcase]
      end
      
      current_rank = 1
      previous_score = nil
      @leaderboard.each_with_index do |entry, index|
        if previous_score != entry[:total_score]
          current_rank = index + 1
          previous_score = entry[:total_score]
        end
        entry[:rank] = current_rank
        
        # Rank inside group members
        member_rank = 1
        member_prev_score = nil
        entry[:members].each_with_index do |m, m_index|
          if member_prev_score != m[:total_score]
            member_rank = m_index + 1
            member_prev_score = m[:total_score]
          end
          m[:rank] = member_rank
        end
      end
      
      if params[:sort] == 'name'
        @leaderboard.sort_by! { |entry| entry[:group].name.to_s.downcase }
        @leaderboard.each do |entry|
          entry[:members].sort_by! { |m| [m[:user].full_name.to_s.downcase, -m[:total_score]] }
        end
      end
    end

    respond_to do |format|
      format.html { render layout: 'application' }
      format.csv {
        send_data generate_scoreboard_csv,
                  filename: "scoreboard_#{@mode}_#{Time.current.strftime('%Y%m%d_%H%M%S')}.csv",
                  type: 'text/csv; charset=utf-8'
      }
    end
  end

  private

  def check_public_scoreboard_access
    unless GraderConfiguration['system.scoreboard_enabled']
      redirect_to root_path, alert: 'Scoreboard is currently disabled.'
      return
    end

    level = GraderConfiguration['system.scoreboard_view_level'] || 'user'
    case level
    when 'all', 'public'
      # anyone can see
    when 'user'
      check_valid_login
    when 'admin'
      check_valid_login
      unless @current_user.admin? || @current_user.problem_setter?
        redirect_to root_path, alert: 'Only admins can access the scoreboard.'
      end
    end
  end

  def generate_scoreboard_csv
    require 'csv'
    CSV.generate(headers: true) do |csv|
      # Headers
      headers = ["Rank", "Name", "Sum"]
      headers << "Bonus" if GraderConfiguration.enable_bonus?
      headers << "Deducted" if GraderConfiguration.enable_penalty?
      @problems.each do |p|
        headers << "#{p.name} (#{p.effective_full_score || 100})"
      end
      csv << headers

      if @mode == 'individual'
        @leaderboard.each do |entry|
          row = [
            entry[:rank],
            entry[:user].full_name,
            entry[:total_score]
          ]
          row << (entry[:bonus_score].to_f > 0 ? entry[:bonus_score] : nil) if GraderConfiguration.enable_bonus?
          row << (entry[:deducted_score].to_f > 0 ? entry[:deducted_score] : nil) if GraderConfiguration.enable_penalty?
          
          @problems.each do |p|
            if helpers.user_associated_with_problem?(entry[:user].id, p.id)
              row << (@scores[entry[:user].id][p.id] || 0)
            else
              row << "—"
            end
          end
          csv << row
        end
      else
        # Group mode
        @leaderboard.each do |entry|
          row = [
            entry[:rank],
            "[Group] #{entry[:group].name}",
            entry[:total_score]
          ]
          row << (entry[:bonus_score].to_f > 0 ? entry[:bonus_score] : nil) if GraderConfiguration.enable_bonus?
          row << (entry[:deducted_score].to_f > 0 ? entry[:deducted_score] : nil) if GraderConfiguration.enable_penalty?
          
          @problems.each do |p|
            if helpers.group_associated_with_problem?(entry[:group].id, p.id)
              group_score = @group_score_type == 'group_max' ? entry[:members].map { |m| @scores[m[:user].id][p.id] || 0 }.max : entry[:members].map { |m| @scores[m[:user].id][p.id] || 0 }.sum
              row << group_score
            else
              row << "—"
            end
          end
          csv << row

          entry[:members].each do |m|
            member_row = [
              m[:rank],
              "  - #{m[:user].full_name}",
              m[:total_score]
            ]
            member_row << (m[:bonus_score].to_f > 0 ? m[:bonus_score] : nil) if GraderConfiguration.enable_bonus?
            member_row << (m[:deducted_score].to_f > 0 ? m[:deducted_score] : nil) if GraderConfiguration.enable_penalty?
            @problems.each do |p|
              if helpers.user_associated_with_problem?(m[:user].id, p.id)
                member_row << (@scores[m[:user].id][p.id] || 0)
              else
                member_row << "—"
              end
            end
            csv << member_row
          end
        end
      end
    end
  end
end
