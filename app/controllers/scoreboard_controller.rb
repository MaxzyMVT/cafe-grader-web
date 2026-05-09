class ScoreboardController < ApplicationController
  before_action :check_public_scoreboard_access

  def index
    # Fetch all enabled users, problems that are available/reportable
    # For now we fetch all problems for simplicity
    @problems = Problem.available.order(:date_added)

    # Fetch users, but depending on group toggle, we might need groups
    @users = User.where(enabled: true)
    
    unless GraderConfiguration['system.scoreboard_include_admins']
      admin_ids = User.joins(:roles).where(roles: { name: 'admin' }).pluck(:id)
      @users = @users.where.not(id: admin_ids)
    end
    
    # Mode toggle: individual vs groups
    @mode = params[:mode] == 'group' ? 'group' : 'individual'
    
    # Calculate scores
    # Re-using the logic from max_score_query but for ALL users/problems efficiently
    # For a real scoreboard, we just need the max score of each user for each problem.
    max_records = Submission.where(user: @users, problem: @problems).group('user_id,problem_id').select('MAX(submissions.points) as max_score, user_id, problem_id')
    
    @scores = Hash.new { |h,k| h[k] = {} }
    max_records.each do |record|
      @scores[record.user_id][record.problem_id] = record.max_score
    end

    if @mode == 'individual'
      @leaderboard = @users.map do |u|
        total = 0
        @problems.each do |p|
          total += @scores[u.id][p.id] || 0
        end
        { user: u, total_score: total }
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
        @leaderboard.sort_by! { |entry| entry[:user].full_name.to_s.downcase }
      end
    else
      # Group mode
      @groups = Group.all
      @leaderboard = @groups.map do |g|
        group_users = g.users.where(enabled: true)
        group_total = 0
        group_members = group_users.map do |u|
          user_total = 0
          @problems.each do |p|
            user_total += @scores[u.id][p.id] || 0
          end
          group_total += user_total
          { user: u, total_score: user_total }
        end
        group_members.sort_by! { |m| [-m[:total_score], m[:user].full_name.to_s.downcase] }
        
        { group: g, total_score: group_total, members: group_members }
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
      end
    end

    render layout: 'application'
  end

  private

  def check_public_scoreboard_access
    unless GraderConfiguration['system.scoreboard_public_accessible']
      check_valid_login
    end
  end
end
