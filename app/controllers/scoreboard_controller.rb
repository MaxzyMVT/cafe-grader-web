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

    # Fetch users, but depending on group toggle, we might need groups
    disabled_group_user_ids = User.joins(:groups).where(groups: { enabled: false }).pluck(:id)
    @users = User.where(enabled: true).where.not(id: disabled_group_user_ids)
    
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
            gc = s.grader_comment.to_s
            if tc_count == 0
              true
            elsif gc.length == tc_count && gc.match?(/\A[PsS]+\z/)
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

    if @mode == 'individual'
      @leaderboard = @users.map do |u|
        raw_sum = 0
        @problems.each do |p|
          raw_sum += @scores[u.id][p.id] || 0
        end
        deducted = GraderConfiguration.disable_penalty? ? 0 : (@user_deductions[u.id] || 0)
        
        # Calculate bonus for this user
        bonus = 0
        unless GraderConfiguration.disable_bonus?
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
      # Sort by total_score desc, then by name
      @leaderboard.sort_by! { |entry| [-entry[:total_score], entry[:user].full_name.to_s.downcase] }
      
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
      disabled_group_user_ids = User.joins(:groups).where(groups: { enabled: false }).pluck(:id)
      setter_admin_ids = User.joins(:roles).where(roles: { name: ['admin', 'problem_setter'] }).pluck(:id)
      @groups = Group.where(enabled: true)
      @group_score_type = GraderConfiguration['system.group_score_type'] || 'group_sum'
      @leaderboard = @groups.map do |g|
        group_users = g.users.where(enabled: true).where.not(id: disabled_group_user_ids + setter_admin_ids)
        group_total = 0
        group_deducted = 0
        group_bonus = 0
        group_members = group_users.map do |u|
          user_raw_total = 0
          @problems.each do |p|
            user_raw_total += @scores[u.id][p.id] || 0
          end
          user_deducted = GraderConfiguration.disable_penalty? ? 0 : (@user_deductions[u.id] || 0)
          
          # Calculate bonus for this user
          user_bonus = 0
          unless GraderConfiguration.disable_bonus?
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

        group_members.sort_by! { |m| [-m[:total_score], m[:user].full_name.to_s.downcase] }
        
        { group: g, total_score: group_total, deducted_score: group_deducted, bonus_score: group_bonus, members: group_members }
      end
      @leaderboard.sort_by! { |entry| [-entry[:total_score], entry[:group].name.to_s.downcase] }
      
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

    render layout: 'application'
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
end
