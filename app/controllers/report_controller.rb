class ReportController < ApplicationController
  include ProblemAuthorization

  before_action :check_valid_login
  before_action :selected_problems, only: [ :show_max_score, :max_score_table, :submission_query, :max_score_query, :ai_query, :extended_stat, :activity_query ]
  before_action :selected_users, only: [ :show_max_score, :max_score_table, :submission_query, :max_score_query, :ai_query, :activity_query ]
  before_action :set_report_empty_hint, only: [ :max_score, :submission, :activity, :ai ]
  before_action :set_report_scope_help, only: [ :max_score, :submission, :activity, :ai ]

  # for all action except hall of fame (which is viewable by any user if the feature is enabled)
  before_action(except: [:problem_hof, :problem_hof_view, :problem_hof_query]) {
    group_action_authorization(:report)
  }

  before_action :restrict_setter_reports, except: [:problem_hof, :problem_hof_view, :problem_hof_query, :extended_stat]

  # for hall of fame
  before_action :set_problem, only: [:problem_hof_view]
  before_action :hall_of_fame_authorization, only: [:problem_hof, :problem_hof_query, :problem_hof_view]
  before_action :admin_authorization, only: [:problem_hof_recompute]
  before_action :can_view_problem, only: [:problem_hof_view]

  # render the UI for filtering and the initial blank table
  def max_score
    # this is for rendering the filter selection
    @problems = @current_user.problems_for_action(:report)
    @groups = @current_user.groups_for_action(:report)
  end

  # turbo update the table (also with blank table but with columns)
  def max_score_table
    render turbo_stream: turbo_stream.update(:max_score_result, partial: 'score_table', locals: {problems: @problems, link_for_data: max_score_query_report_path, refresh_submit_form_id: 'max-score-filter-form' })
  end

  def max_score_query
    # when @problems is blank, it is very likely that the user hasn't select anything in the form at all
    # which default to showing all user with no problem selected. We then force the user to be blank as well to speed up

    @users = User.none if @problems.blank?
    submissions = submission_in_range(params[:sub_range]).where(user: @users, problem: @problems)

    # the max score report need range of time to check for hint acquiring,
    # we use the time from the first submission to the last submission of the filtered submission
    start = submissions.minimum(:submitted_at)
    stop = submissions.maximum(:submitted_at)
    records = submissions.max_score_report(@problems, start, stop)

    # calculate the maximum score
    @result = Submission.calculate_max_score(records, @users, @problems)

    render json: {
      # for data, we need some alias as we use the same render for both the report and contest stat,
      # these fields are required in the contest view but not in the report view
      # we also have to alias the user.id to user_id as well
      data: @users.select(:id, :login, :full_name, :remark)
        .select(' NULL as seat').select('NULL as last_heartbeat').select(' id as user_id'),
      result: @result,
      problem: @problems
    }
  end

  # post max_score
  def show_max_score
    # calculate submission with max score
    max_records = submission_in_range(params[:sub_range])
      .where(user_id: @users.ids, problem_id: @problems).group('user_id,problem_id')
      .select('MAX(submissions.points) as max_score, user_id, problem_id')

    records = submission_in_range(params[:sub_range])
      .joins("JOIN (#{max_records.to_sql}) MAX_RECORD ON " +
             'submissions.points = MAX_RECORD.max_score AND ' +
             'submissions.user_id = MAX_RECORD.user_id AND ' +
             'submissions.problem_id = MAX_RECORD.problem_id ')
      .joins(:user).joins(:problem)
      .select('users.id,users.login,users.full_name,users.remark')
      .select('problems.name')
      .select('max_score')
      .select('submissions.submitted_at')
      .select('submissions.problem_id')
      .select('submissions.id as sub_id')

    @show_time = params['show-time'] == 'on'

    # calculate the score
    @result = Submission.calculate_max_score(records, @users, @problems, with_comments: false)

    # this only render as turbo stream
    # see show_max_score.turbo_stream
  end

  def login
    @groups = @current_user.groups_for_action(:report)
  end

  def login_summary_query
    @users = Array.new
    @since_time = (params[:since_datetime].present? ? Time.zone.parse(params[:since_datetime]) : nil) rescue nil
    @since_time ||= Time.zone.now.beginning_of_day
    @until_time = (params[:until_datetime].present? ? Time.zone.parse(params[:until_datetime]) : nil) rescue nil
    @until_time ||= Time.zone.now.end_of_day
    record = User
      .left_outer_joins(:logins).group('users.id')
      .where("logins.created_at >= ? AND logins.created_at <= ?", @since_time, @until_time)
    case params[:users]
    when 'enabled'
      record = record.where(enabled: true)
    when 'group'
      record = record.joins(:groups).where(groups: {id: params[:groups]}) if params[:groups]
    end

    record = record.pluck("users.id,users.login,users.full_name,count(logins.created_at),min(logins.created_at),max(logins.created_at)")
    record.each do |user|
      query = Login.where("user_id = ? AND created_at >= ? AND created_at <= ?", user[0], @since_time, @until_time)
      ips =  query.pluck(:ip_address).uniq
      cookie = query.pluck(:cookie).uniq

      @users << { id: user[0],
                   login: user[1],
                   full_name: user[2],
                   count: user[3],
                   min: user[4].in_time_zone,
                   max: user[5].in_time_zone,
                   ip: ips,
                   cookie: cookie
                 }
    end
  end

  def login_detail_query
    @logins = Array.new
    @since_time = (params[:since_datetime].present? ? Time.zone.parse(params[:since_datetime]) : nil) rescue nil
    @since_time ||= Time.zone.now.beginning_of_day
    @until_time = (params[:until_datetime].present? ? Time.zone.parse(params[:until_datetime]) : nil) rescue nil
    @until_time ||= Time.zone.now.end_of_day

    @logins = Login.includes(:user).where("logins.created_at >= ? AND logins.created_at <= ?", @since_time, @until_time)
    case params[:users]
    when 'enabled'
      @logins = @logins.where(users: {enabled: true})
    when 'group'
      @logins = @logins.joins(user: :groups).where(user: {groups: {id: params[:groups]}}) if params[:groups]
    end
    @logins = @logins.limit(100_000)
  end

  def submission
    @problems = @current_user.problems_for_action(:report)
    @groups = @current_user.groups_for_action(:report)
  end

  def submission_query
    @submissions = submission_in_range(params[:sub_range])
      .joins(:problem).joins(:language).joins(:user)

    @submissions = @submissions.where(user: @users)

    # filter submissions
    @submissions = @submissions.where(problem: @problems)


    @submissions = @submissions.limit(100_000)
    @submissions = @submissions.select('submissions.id,points,ip_address,submitted_at,grader_comment,max_runtime,peak_memory,effective_code_length')
      .select('users.login, users.full_name as user_full_name, users.id as user_id')
      .select('problems.full_name, problems.name, problems.id as problem_id')
      .select('languages.pretty_name')

    # build day sum

    # render json:  {data: @submissions,sub_count_by_date: {a:1}}
  end

  def activity
    @problems = @current_user.problems_for_action(:report)
    @groups = @current_user.groups_for_action(:report)
  end

  # Per-user submission summary: who actively worked in a time range x problem set.
  # One aggregate pass over submissions — deliberately avoids the scoring engine,
  # so "all problems" stays fast. "Solved" counts problems with a >= 100-point
  # submission; raw_sum-scored datasets are excluded there because their points
  # are a literal sum with no defined full score.
  def activity_query
    raw_sum = Dataset.score_types[:raw_sum]
    rows = submission_in_range(params[:sub_range])
      .where(problem: @problems, user: @users)
      .joins(:user, :problem)
      .joins('LEFT JOIN datasets live_ds ON live_ds.id = problems.live_dataset_id')
      .group('users.id')
      .pluck(Arel.sql(<<~SQL.squish))
        users.id, users.login, users.full_name,
        COUNT(submissions.id),
        COUNT(DISTINCT submissions.problem_id),
        COUNT(DISTINCT CASE WHEN submissions.points >= 100
                             AND (live_ds.score_type IS NULL OR live_ds.score_type <> #{raw_sum})
                            THEN submissions.problem_id END),
        MIN(submissions.submitted_at), MAX(submissions.submitted_at),
        COUNT(DISTINCT submissions.ip_address)
      SQL

    @rows = rows.map do |id, login, full_name, sub_count, prob_count, solved_count, first_sub, last_sub, ip_count|
      { user_id: id, login: login, full_name: full_name,
        sub_count: sub_count, prob_count: prob_count, solved_count: solved_count,
        first_sub: first_sub.in_time_zone, last_sub: last_sub.in_time_zone,
        ip_count: ip_count }
    end

    # optionally append selected users with zero submissions in the range
    if params[:show_inactive] == 'true'
      active_ids = @rows.map { |r| r[:user_id] }
      @users.where.not(id: active_ids).pluck(:id, :login, :full_name).each do |id, login, full_name|
        @rows << { user_id: id, login: login, full_name: full_name,
                   sub_count: 0, prob_count: 0, solved_count: 0,
                   first_sub: nil, last_sub: nil, ip_count: 0 }
      end
    end
  end

  def ai
    # this is "selectable" problems, groups and for rendering the filter selection
    @problems = @current_user.problems_for_action(:report)
    @groups = @current_user.groups_for_action(:report)
  end

  def ai_query
    submissions = submission_in_range(params[:sub_range]).order(:submitted_at)
    first_sub = submissions.first
    last_sub = submissions.last

    first_submission_datetime = first_sub&.submitted_at
    first_sub_id = first_sub&.id
    last_sub_id = last_sub&.id


    # We can't efficiently filter only for the job inside the selected submissions id range
    # because we then need to unserialize the argument first.
    # Therefore, we just use the first submission date to filter the "start" submission
    # and then use select at the end to actually filtering out the submissions
    jobs_scope = SolidQueue::Job
      .where('created_at > ?', first_submission_datetime)
      .where('class_name LIKE "Llm::%"')
      .order(created_at: :desc)
      .limit(20_000)

    # We need to eager load the submission, else this will be N+1 queries
    # First, we need all gid of the submission

    job_submission_map = {} # { job_id => gid_string }
    all_gids = []

    jobs_scope.each do |job|
      arguments = job.arguments['arguments']
      if job.class_name.safe_constantize&.<(Llm::RequestJob) && arguments.present?
        gid_string = arguments.first.values.last
        if gid_string.is_a?(String)
          job_submission_map[job.id] = gid_string
          all_gids << gid_string
        end
      end
    end

    # load these submissions, also eager load the user and problem
    submissions_hash = GlobalID::Locator.locate_many(all_gids, includes: [:user, :problem]).index_by { |submission| submission.to_gid.to_s }


    @jobs = jobs_scope.map do |job|
      gid_string = job_submission_map[job.id]
      # Pass the pre-loaded submission (or nil) to the presenter
      submission = gid_string ? submissions_hash[gid_string] : nil
      Llm::RequestJobPresenter.new(job, submission)
    end

    # @jobs[i] is now a presenter object of the job
    # We will do filtering here
    selected_problem_ids = @problems.ids
    selected_user_ids = @users.ids
    @jobs = @jobs
      .select { |job| selected_problem_ids.include? job.problem_id }
      .select { |job| selected_user_ids.include? job.user_id }
      .select { |job| job.submission_id >= first_sub_id && job.submission_id <= last_sub_id }
  end


  # -- not used --
  # def progress
  # end

  # def progress_query
  # end

  def extended_stat
    @limit = 1000
    @problems_all = @current_user.problems_for_action(:report).default_order
    @groups = Group.all
    @tags = Tag.all
    
    # if we have problems from selected_problems before_action, use them
    # If the user explicitly selected 'Specific Problems' (ids) mode but selected nothing,
    # calculate with nothing. Otherwise, default to ALL reportable problems.
    if params[:probs].present?
      if params.dig(:probs, :use) == 'all'
        selected_prob_ids = @problems_all.ids
      else
        selected_prob_ids = @problems.ids
      end
    else
      selected_prob_ids = @problems_all.ids
    end

    @languages = Language.all

    begin
      @since_time = Time.zone.parse(params[:since_datetime]) if params[:since_datetime].present?
    rescue
      @since_time = nil
    end
    begin
      @until_time = Time.zone.parse(params[:until_datetime]) if params[:until_datetime].present?
    rescue
      @until_time = nil
    end

    # Base submissions scope based on time
    subs_scope = Submission.joins("INNER JOIN problems ON problems.id = submissions.problem_id")
    subs_scope = subs_scope.where(problem_id: selected_prob_ids)
    subs_scope = subs_scope.where("submitted_at >= ?", @since_time) if @since_time
    subs_scope = subs_scope.where("submitted_at <= ?", @until_time) if @until_time
    if params[:language_id].present? && params[:language_id] != 'all'
      subs_scope = subs_scope.where(language_id: params[:language_id])
    end

    roles_to_exclude = []
    unless GraderConfiguration['system.statistic_include_admins']
      roles_to_exclude += ['admin', 'problem_setter']
    end
    exclude_user_ids = User.joins(:roles).where(roles: { name: roles_to_exclude }).pluck(:id)
    exclude_user_ids += User.where(enabled: false).pluck(:id)
    subs_scope = subs_scope.where.not(user_id: exclude_user_ids.uniq)

    # Helper scope for passed submissions (score >= full_score)
    # Using COALESCE for full_score to handle cases where it's not set
    passed_scope = subs_scope.where(status: :done).where("submissions.grader_comment REGEXP '^[\\\\[\\\\sPS\\\\]]*$'")

    # 1. Most Effort (Most submissions)
    if params[:group_mode] == '1'
      effort_scope = subs_scope.joins(user: :groups).group('groups.id')
      effort_counts = effort_scope.order('count_all DESC').limit(@limit).count
      if effort_counts.any?
        threshold = effort_counts.values.last
        @most_effort = effort_scope.having("count(*) >= ?", threshold).order(Arel.sql('count(*) DESC')).count
      else
        @most_effort = {}
      end
      @most_effort_groups = Group.where(id: @most_effort.keys).index_by(&:id)
    else
      effort_counts = subs_scope.group(:user_id).order('count_all DESC').limit(@limit).count
      if effort_counts.any?
        threshold = effort_counts.values.last
        @most_effort = subs_scope.group(:user_id).having("count(*) >= ?", threshold).order(Arel.sql('count(*) DESC')).count
      else
        @most_effort = {}
      end
      @most_effort_users = User.where(id: @most_effort.keys).index_by(&:id)
    end

    # 2. Latest Passed Submission
    @latest_passed = passed_scope.order(submitted_at: :desc).limit(@limit).includes(:user, :problem, :language)

    # 3. Latest Submission
    @latest_sub = subs_scope.order(submitted_at: :desc).limit(@limit).includes(:user, :problem, :language)

    # 4. First Bloods
    # Submissions that were the first to get >= full_score for each problem
    blood_sub_ids = []
    problems_to_check = Problem.where(id: selected_prob_ids)
    problems_to_check.each do |p|
      first_sub = p.submissions.tag_default
                    .where("submissions.points >= ?", p.full_score || 100)
                    .where.not(user_id: exclude_user_ids.uniq)
                    .order(submitted_at: :asc, id: :asc)
                    .first
      blood_sub_ids << first_sub.id if first_sub
    end
    
    fb_base = passed_scope.where(id: blood_sub_ids)

    if params[:group_mode] == '1'
      fb_base = fb_base.joins(user: :groups).group('groups.id')
      fb_top = fb_base.order(Arel.sql('count(*) DESC')).limit(@limit).count
      if fb_top.any?
        threshold = fb_top.values.last
        @first_bloods = fb_base.having("count(*) >= ?", threshold).order(Arel.sql('count(*) DESC')).count
      else
        @first_bloods = {}
      end
      @first_bloods_groups = Group.where(id: @first_bloods.keys).index_by(&:id)
    else
      fb_base = fb_base.group(:user_id)
      fb_top = fb_base.order(Arel.sql('count(*) DESC')).limit(@limit).count
      if fb_top.any?
        threshold = fb_top.values.last
        @first_bloods = fb_base.having("count(*) >= ?", threshold).order(Arel.sql('count(*) DESC')).count
      else
        @first_bloods = {}
      end
      @first_bloods_users = User.where(id: @first_bloods.keys).index_by(&:id)
    end

    # The following require getting the "best" passed submission per problem per user
    
    # 5. Most Efficient Coder (Shortest Code)
    # Exclude the "999999" placeholder, NULLs, and output-only problems
    min_len = passed_scope.joins(:problem).where(problems: {output_only: false})
      .where("effective_code_length IS NOT NULL AND effective_code_length < 999999")
      .group('submissions.user_id, submissions.problem_id')
      .select('submissions.user_id, MIN(effective_code_length) as min_len')
    
    if params[:group_mode] == '1'
      chars_stats = Group.joins(:users).joins("INNER JOIN (#{min_len.to_sql}) ml ON users.id = ml.user_id")
        .group('groups.id')
        .select('groups.id', 'COUNT(ml.min_len) as solved_count', 'SUM(ml.min_len) as total_chars')
        .index_by(&:id)
    else
      chars_stats = User.joins("INNER JOIN (#{min_len.to_sql}) ml ON users.id = ml.user_id")
        .group('users.id')
        .select('users.id', 'COUNT(ml.min_len) as solved_count', 'SUM(ml.min_len) as total_chars')
        .index_by(&:id)
    end

    sorted_chars_ids = chars_stats.keys.sort_by { |id| s = chars_stats[id]; [-s.solved_count, s.total_chars] }
    if sorted_chars_ids.any?
      last_stat = chars_stats[sorted_chars_ids.first(@limit).last]
      @least_chars = chars_stats.values.select { |s| s.solved_count > last_stat.solved_count || (s.solved_count == last_stat.solved_count && s.total_chars <= last_stat.total_chars) }
        .sort_by { |s| [-s.solved_count, s.total_chars] }
        .map { |s| [s.id, {solved: s.solved_count, value: s.total_chars}] }.to_h
    else
      @least_chars = {}
    end
    
    # 6. Fastest Runtime (Exclude output-only problems)
    min_time = passed_scope.joins(:problem).where(problems: {output_only: false})
      .where("max_runtime IS NOT NULL AND max_runtime < 999999")
      .group('submissions.user_id, submissions.problem_id')
      .select('submissions.user_id, MIN(max_runtime) as min_time')
    
    if params[:group_mode] == '1'
      time_stats = Group.joins(:users).joins("INNER JOIN (#{min_time.to_sql}) mt ON users.id = mt.user_id")
        .group('groups.id')
        .select('groups.id', 'COUNT(mt.min_time) as solved_count', 'SUM(mt.min_time) as total_time')
        .index_by(&:id)
    else
      time_stats = User.joins("INNER JOIN (#{min_time.to_sql}) mt ON users.id = mt.user_id")
        .group('users.id')
        .select('users.id', 'COUNT(mt.min_time) as solved_count', 'SUM(mt.min_time) as total_time')
        .index_by(&:id)
    end

    sorted_time_ids = time_stats.keys.sort_by { |id| s = time_stats[id]; [-s.solved_count, s.total_time] }
    if sorted_time_ids.any?
      last_stat = time_stats[sorted_time_ids.first(@limit).last]
      @fastest_runtime = time_stats.values.select { |s| s.solved_count > last_stat.solved_count || (s.solved_count == last_stat.solved_count && s.total_time <= last_stat.total_time) }
        .sort_by { |s| [-s.solved_count, s.total_time] }
        .map { |s| [s.id, {solved: s.solved_count, value: s.total_time}] }.to_h
    else
      @fastest_runtime = {}
    end

    # 7. Least Memory (Exclude output-only problems)
    min_mem = passed_scope.joins(:problem).where(problems: {output_only: false})
      .where("peak_memory IS NOT NULL AND peak_memory < 999999")
      .group('submissions.user_id, submissions.problem_id')
      .select('submissions.user_id, MIN(peak_memory) as min_mem')
    
    if params[:group_mode] == '1'
      mem_stats = Group.joins(:users).joins("INNER JOIN (#{min_mem.to_sql}) mm ON users.id = mm.user_id")
        .group('groups.id')
        .select('groups.id', 'COUNT(mm.min_mem) as solved_count', 'SUM(mm.min_mem) as total_mem')
        .index_by(&:id)
    else
      mem_stats = User.joins("INNER JOIN (#{min_mem.to_sql}) mm ON users.id = mm.user_id")
        .group('users.id')
        .select('users.id', 'COUNT(mm.min_mem) as solved_count', 'SUM(mm.min_mem) as total_mem')
        .index_by(&:id)
    end

    sorted_mem_ids = mem_stats.keys.sort_by { |id| s = mem_stats[id]; [-s.solved_count, s.total_mem] }
    if sorted_mem_ids.any?
      last_stat = mem_stats[sorted_mem_ids.first(@limit).last]
      @least_memory = mem_stats.values.select { |s| s.solved_count > last_stat.solved_count || (s.solved_count == last_stat.solved_count && s.total_mem <= last_stat.total_mem) }
        .sort_by { |s| [-s.solved_count, s.total_mem] }
        .map { |s| [s.id, {solved: s.solved_count, value: s.total_mem}] }.to_h
    else
      @least_memory = {}
    end

    # 8. Score Growth
    since_scores = @since_time ? get_total_scores_at(@since_time, exclude_user_ids.uniq, selected_prob_ids, params[:group_mode] == '1') : {}
    until_scores = get_total_scores_at(@until_time, exclude_user_ids.uniq, selected_prob_ids, params[:group_mode] == '1')

    @score_growth = {}
    until_scores.each do |id, score_data|
      since_data = since_scores[id] || { raw: 0.0, deducted: 0.0, bonus: 0.0, total: 0.0 }
      growth = score_data[:total] - since_data[:total]
      raw_growth = score_data[:raw] - since_data[:raw]
      bonus_growth = score_data[:bonus] - since_data[:bonus]
      deducted_growth = score_data[:deducted] - since_data[:deducted]

      # "but still not show sum '0' scorers (negative is meant to show)"
      if growth.abs > 0.01
        @score_growth[id] = {
          growth: growth,
          raw_growth: raw_growth,
          bonus_growth: bonus_growth,
          deducted_growth: deducted_growth
        }
      end
    end

    # Fetch completion times and passed counts for sorting ties
    problems_to_check = Problem.where(id: selected_prob_ids)
    zero_score_prob_ids = problems_to_check.select { |p| p.effective_full_score == 0 }.map(&:id)
    
    passing_zero_sub_ids = []
    if zero_score_prob_ids.any?
      zero_subs = Submission.where(problem_id: zero_score_prob_ids, status: 'done', viva_archived_at: nil)
      zero_subs = zero_subs.where("submitted_at <= ?", @until_time) if @until_time
      zero_subs.each do |s|
        prob = problems_to_check.find { |p| p.id == s.problem_id }
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

    max_pts_sub = Submission.where(problem_id: selected_prob_ids)
    max_pts_sub = max_pts_sub.where("submitted_at <= ?", @until_time) if @until_time
    if passing_zero_sub_ids.any?
      max_pts_sub = max_pts_sub.where("submissions.points > 0 OR submissions.id IN (?)", passing_zero_sub_ids)
    else
      max_pts_sub = max_pts_sub.where("submissions.points > 0")
    end
    max_pts_sub = max_pts_sub.group(:user_id, :problem_id).select('user_id, problem_id, MAX(points) as max_pts')

    first_bests = Submission.joins("INNER JOIN (#{max_pts_sub.to_sql}) mp ON submissions.user_id = mp.user_id AND submissions.problem_id = mp.problem_id AND submissions.points = mp.max_pts")
    first_bests = first_bests.where("submissions.submitted_at <= ?", @until_time) if @until_time
    first_bests = first_bests.group(:user_id, :problem_id).select('submissions.user_id, submissions.problem_id, MIN(submissions.submitted_at) as first_best_time')

    user_completion_times = Submission.from("(#{first_bests.to_sql}) fb")
      .group('fb.user_id')
      .select('fb.user_id, MAX(fb.first_best_time) as last_completed_time')
      .each_with_object({}) { |r, h| h[r.user_id] = r.last_completed_time }

    # Passed counts query
    best_subs = Submission.joins("INNER JOIN (#{first_bests.to_sql}) fb ON submissions.user_id = fb.user_id AND submissions.problem_id = fb.problem_id AND submissions.submitted_at = fb.first_best_time")
      .select('submissions.user_id, submissions.grader_comment, submissions.points, submissions.problem_id')
      
    user_passed_counts = Hash.new(0)
    best_subs.each do |sub|
      comment = sub.grader_comment.to_s.gsub(/[\[\]\s]/, '')
      if !comment.blank? && comment.match?(/\A[PS]*\z/)
        user_passed_counts[sub.user_id] += 1
      end
    end

    if params[:group_mode] == '1'
      group_completion_times = {}
      group_passed_counts = Hash.new(0)
      Group.joins(:groups_users).pluck('groups.id, groups_users.user_id').each do |group_id, user_id|
        t = user_completion_times[user_id]
        if t
          group_completion_times[group_id] = group_completion_times[group_id] ? [group_completion_times[group_id], t].max : t
        end
        group_passed_counts[group_id] += user_passed_counts[user_id] || 0
      end
      completion_times = group_completion_times
      passed_counts = group_passed_counts
      
      @score_growth_groups = Group.where(id: @score_growth.keys).index_by(&:id)
      @score_growth_names = @score_growth_groups.transform_values { |g| g.name }
    else
      completion_times = user_completion_times
      passed_counts = user_passed_counts
      
      @score_growth_users = User.where(id: @score_growth.keys).index_by(&:id)
      @score_growth_names = @score_growth_users.transform_values { |u| u.full_name }
    end

    @score_growth = @score_growth.sort_by do |id, data|
      time = completion_times[id] || Time.zone.at(2147483647)
      pass = passed_counts[id] || 0
      name = @score_growth_names[id].to_s.downcase
      [-data[:growth], time.to_i, -pass, name]
    end.to_h

    # Expose helper details for frontend to read on DOM load
    @score_growth_details = {}
    @score_growth.each_key do |id|
      @score_growth_details[id] = {
        time: (completion_times[id] || Time.zone.at(2147483647)).to_i,
        pass: passed_counts[id] || 0,
        name: @score_growth_names[id].to_s
      }
    end
  end

  def problem_hof
  end

  def problem_hof_query
    @user = User.find(session[:user_id])
    problem_ids = @user.problems_for_action(:submit).pluck(:id)

    @problems = Problem.where(id: problem_ids)
      .left_joins(:problem_stat)
      .select(
        "problems.id, problems.name, problems.full_name",
        "COALESCE(problem_stats.sub_count, 0) as sub_count",
        "COALESCE(problem_stats.attempted_count, 0) as attempted_count",
        "COALESCE(problem_stats.solved_count, 0) as solved_count"
      )
  end

  def problem_hof_recompute
    ProblemStat.recompute_all
    @toast = { title: "Hall of Fame", body: "Statistics recomputed for #{ProblemStat.count} problems." }
    render "turbo_toast"
  end

  def problem_hof_view
    @user = User.find(session[:user_id])

    # model submission
    @model_subs = Submission.where(problem: @problem, tag: Submission.tags[:model])


    # calculate best submission
    @by_lang = {} # aggregrate by language

    @summary = {count: 0, solve: 0, attempt: 0}
    user = Hash.new(0)
    roles_to_exclude = []
    unless GraderConfiguration['system.statistic_include_admins']
      roles_to_exclude += ['admin', 'problem_setter']
    end
    exclude_ids = User.joins(:roles).where(roles: { name: roles_to_exclude }).pluck(:id)
    exclude_ids += User.where(enabled: false).pluck(:id)
    exclude_ids = exclude_ids.uniq
    Submission.where(problem_id: @problem.id).where.not(user_id: exclude_ids).includes(:language, :user).find_each do |sub|
      # histogram

      next unless sub.points
      @summary[:count] += 1
      user[sub.user_id] = [user[sub.user_id], (sub.points >= 100) ? 1 : 0].max

      # lang = Language.find_by_id(sub.language_id)
      lang = sub.language
      next unless lang
      next unless sub.points >= 100

      # initialize
      unless @by_lang.has_key?(lang.pretty_name)
        @by_lang[lang.pretty_name] = {
          runtime: { avail: false, value: 2**30-1 },
          memory: { avail: false, value: 2**30-1 },
          length: { avail: false, value: 2**30-1 },
          first: { avail: false, value: DateTime.new(3000, 1, 1) }
        }
      end

      if sub.max_runtime and sub.max_runtime < @by_lang[lang.pretty_name][:runtime][:value]
        @by_lang[lang.pretty_name][:runtime] = { avail: true, user_id: sub.user_id, value: sub.max_runtime, sub_id: sub.id }
      end

      if sub.peak_memory and sub.peak_memory < @by_lang[lang.pretty_name][:memory][:value]
        @by_lang[lang.pretty_name][:memory] = { avail: true, user_id: sub.user_id, value: sub.peak_memory, sub_id: sub.id }
      end

      is_excluded = (sub.user.admin? || sub.user.problem_setter?) && !GraderConfiguration['system.statistic_include_admins']
      if sub.submitted_at and sub.submitted_at < @by_lang[lang.pretty_name][:first][:value] and sub.user and
          !is_excluded
        @by_lang[lang.pretty_name][:first] = { avail: true, user_id: sub.user_id, value: sub.submitted_at, sub_id: sub.id }
      end

      if @by_lang[lang.pretty_name][:length][:value] > (sub.source.length || 2**30-1)
        @by_lang[lang.pretty_name][:length] = { avail: true, user_id: sub.user_id, value: (sub.source.length || 2**30-1), sub_id: sub.id }
      end
    end

    # process user_id
    @by_lang.each do |lang, prop|
      prop.each do |k, v|
        v[:user] = User.exists?(v[:user_id]) ? User.find(v[:user_id]).full_name : "(NULL)"
      end
    end

    # sum into best
    if @by_lang and @by_lang.first
      @best = @by_lang.first[1].clone
      @by_lang.each do |lang, prop|
        if @best[:runtime][:value] >= prop[:runtime][:value]
          @best[:runtime] = prop[:runtime]
          @best[:runtime][:lang] = lang
        end
        if @best[:memory][:value] >= prop[:memory][:value]
          @best[:memory] = prop[:memory]
          @best[:memory][:lang] = lang
        end
        if @best[:length][:value] >= prop[:length][:value]
          @best[:length] = prop[:length]
          @best[:length][:lang] = lang
        end
        if @best[:first][:value] >= prop[:first][:value]
          @best[:first] = prop[:first]
          @best[:first][:lang] = lang
        end
      end
    end

    @summary[:attempt] = user.count
    user.each_value { |v| @summary[:solve] += 1 if v == 1 }

    # for new graph
    @chart_dataset = @problem.get_jschart_history.to_json.html_safe

  end

  def stuck # report struggling user,problem
    # init
    user, problem = nil
    solve = true
    tries = 0
    @struggle = Array.new
    record = {}
    Submission.includes(:problem, :user).order(:problem_id, :user_id).find_each do |sub|
      next unless sub.problem and sub.user
      if user != sub.user_id or problem != sub.problem_id
        @struggle << { user: record[:user], problem: record[:problem], tries: tries } unless solve
        record = {user: sub.user, problem: sub.problem}
        user, problem = sub.user_id, sub.problem_id
        solve = false
        tries = 0
      end
      if sub.points >= 100
        solve = true
      else
        tries += 1
      end
    end
    @struggle.sort! { |a, b| b[:tries] <=> a[:tries] }
    @struggle = @struggle[0..50]
  end


  def multiple_login
    # user with multiple IP
    raw = Submission.joins(:user).joins(:problem).where("problems.available != 0").group("login,ip_address").order(:login)
    last, count = 0, 0
    first = 0
    @users = []
    raw.each do |r|
      if last != r.user.login
        count = 1
        last = r.user.login
        first = r
      else
        @users << first if count == 1
        @users << r
        count += 1
      end
    end

    # IP with multiple user
    raw = Submission.joins(:user).joins(:problem).where("problems.available != 0").group("login,ip_address").order(:ip_address)
    last, count = 0, 0
    first = 0
    @ip = []
    raw.each do |r|
      if last != r.ip_address
        count = 1
        last = r.ip_address
        first = r
      else
        @ip << first if count == 1
        @ip << r
        count += 1
      end
    end
  end

  def cheat_report
    date_and_time = '%Y-%m-%d %H:%M'
    begin
      md = params[:since_datetime].match(/(\d+)-(\d+)-(\d+) (\d+):(\d+)/)
      @since_time = Time.zone.local(md[1].to_i, md[2].to_i, md[3].to_i, md[4].to_i, md[5].to_i)
    rescue
      @since_time = Time.zone.now.ago(90.minutes)
    end
    begin
      md = params[:until_datetime].match(/(\d+)-(\d+)-(\d+) (\d+):(\d+)/)
      @until_time = Time.zone.local(md[1].to_i, md[2].to_i, md[3].to_i, md[4].to_i, md[5].to_i)
    rescue
      @until_time = Time.zone.now
    end

    # multi login
    @ml = Login.joins(:user).where("logins.created_at >= ? and logins.created_at <= ?", @since_time, @until_time).select('users.login,count(distinct ip_address) as count,users.full_name').group("users.id").having("count > 1")

    st = <<-SQL
  SELECT l2.*
    FROM logins l2 INNER JOIN
    (SELECT u.id,COUNT(DISTINCT ip_address) as count,u.login,u.full_name
      FROM logins l
      INNER JOIN users u ON l.user_id =  u.id
      WHERE l.created_at >= '#{@since_time.in_time_zone("UTC")}' and l.created_at <= '#{@until_time.in_time_zone("UTC")}'
      GROUP BY u.id
      HAVING count > 1
    ) ml ON l2.user_id = ml.id
    WHERE l2.created_at >= '#{@since_time.in_time_zone("UTC")}' and l2.created_at <= '#{@until_time.in_time_zone("UTC")}'
UNION
  SELECT l2.*
    FROM logins l2 INNER JOIN
    (SELECT l.ip_address,COUNT(DISTINCT u.id) as count
      FROM logins l
      INNER JOIN users u ON l.user_id =  u.id
      WHERE l.created_at >= '#{@since_time.in_time_zone("UTC")}' and l.created_at <= '#{@until_time.in_time_zone("UTC")}'
      GROUP BY l.ip_address
      HAVING count > 1
    ) ml on ml.ip_address = l2.ip_address
    INNER JOIN users u ON l2.user_id = u.id
    WHERE l2.created_at >= '#{@since_time.in_time_zone("UTC")}' and l2.created_at <= '#{@until_time.in_time_zone("UTC")}'
ORDER BY ip_address,created_at
              SQL
    @mld = Login.find_by_sql(st)

    st = <<-SQL
  SELECT s.id,s.user_id,s.ip_address,s.submitted_at,s.problem_id
    FROM submissions s INNER JOIN
    (SELECT u.id,COUNT(DISTINCT ip_address) as count,u.login,u.full_name
      FROM logins l
      INNER JOIN users u ON l.user_id =  u.id
      WHERE l.created_at >= ? and l.created_at <= ?
      GROUP BY u.id
      HAVING count > 1
    ) ml ON s.user_id = ml.id
    WHERE s.submitted_at >= ? and s.submitted_at <= ?
UNION
  SELECT s.id,s.user_id,s.ip_address,s.submitted_at,s.problem_id
    FROM submissions s INNER JOIN
    (SELECT l.ip_address,COUNT(DISTINCT u.id) as count
      FROM logins l
      INNER JOIN users u ON l.user_id =  u.id
      WHERE l.created_at >= ? and l.created_at <= ?
      GROUP BY l.ip_address
      HAVING count > 1
    ) ml on ml.ip_address = s.ip_address COLLATE utf8mb4_unicode_ci
    WHERE s.submitted_at >= ? and s.submitted_at <= ?
ORDER BY ip_address,submitted_at
            SQL
    @subs = Submission.joins(:problem).find_by_sql([st, @since_time, @until_time,
                                       @since_time, @until_time,
                                       @since_time, @until_time,
                                       @since_time, @until_time])
  end

  def cheat_scrutinize
    # convert date & time
    date_and_time = '%Y-%m-%d %H:%M'
    begin
      md = params[:since_datetime].match(/(\d+)-(\d+)-(\d+) (\d+):(\d+)/)
      @since_time = Time.zone.local(md[1].to_i, md[2].to_i, md[3].to_i, md[4].to_i, md[5].to_i)
    rescue
      @since_time = Time.zone.now.ago(90.minutes)
    end
    begin
      md = params[:until_datetime].match(/(\d+)-(\d+)-(\d+) (\d+):(\d+)/)
      @until_time = Time.zone.local(md[1].to_i, md[2].to_i, md[3].to_i, md[4].to_i, md[5].to_i)
    rescue
      @until_time = Time.zone.now
    end

    # convert sid
    @sid = params[:SID].split(/[,\s]/) if params[:SID]
    unless @sid and @sid.size > 0
      return
      redirect_to actoin: :cheat_scrutinize
      flash[:notice] = 'Please enter at least 1 student id'
    end
    mark = Array.new(@sid.size, '?')
    condition = "(u.login = " + mark.join(' OR u.login = ') + ')'

    @st = <<-SQL
  SELECT l.created_at as submitted_at ,-1 as id,u.login,u.full_name,l.ip_address,"" as problem_id,"" as points,l.user_id
  FROM logins l INNER JOIN users u on l.user_id  = u.id
  WHERE l.created_at >= ? AND l.created_at <= ? AND #{condition}
UNION
  SELECT s.submitted_at,s.id,u.login,u.full_name,s.ip_address,s.problem_id,s.points,s.user_id
  FROM submissions s INNER JOIN users u ON s.user_id = u.id
  WHERE s.submitted_at >= ? AND s.submitted_at <= ? AND #{condition}
ORDER BY submitted_at
  SQL

    p = [@st, @since_time, @until_time] + @sid + [@since_time, @until_time] + @sid
    @logs = Submission.joins(:problem).find_by_sql(p)
  end

  protected

    # Explain an empty report to a non-admin reporter. The report screen is
    # reachable whenever the user is a reporter/editor of *any* group (the gate
    # ignores group.enabled), but the data scope (problems_for_action(:report))
    # additionally requires the problem to be `available` and its group enabled.
    # So a reporter whose problems are all unavailable / whose group is archived
    # passes the gate but sees nothing. When that happens, count the problems
    # that exist in their reporter/editor groups (ignoring those two flags) so
    # the view can tell them WHY the report is blank instead of showing a silent
    # empty table. Admins see Problem.all, so they never need the hint.
    def set_report_empty_hint
      return if @current_user.admin?
      return if @current_user.problems_for_action(:report).exists?

      group_ids = @current_user.groups_users.where(enabled: true, role: [ :reporter, :editor ]).pluck(:group_id)
      @hidden_report_problem_count = Problem.joins(:groups_problems)
        .where(groups_problems: { group_id: group_ids }).distinct.count
    end

    # Role-aware scope help for the report filter pages. Access differs per group
    # (a user may edit some groups and report on others), so the help lists the
    # actual courses. Editors curate archived courses too, so their list includes
    # disabled groups (flagged in the drawer); reporters only see live courses, so
    # theirs is limited to enabled groups. Skipped for admins (scope = everything).
    def set_report_scope_help
      return if @current_user.admin?
      @help_editor_groups = @current_user.groups_users
        .where(role: :editor, enabled: true).joins(:group)
        .order('groups.name').pluck('groups.name', 'groups.enabled')
      @help_reporter_groups = @current_user.groups_users
        .where(role: :reporter, enabled: true).joins(:group)
        .where('groups.enabled': true).order('groups.name').pluck('groups.name')
    end

    # receive an ActiveRecord::AAssociation *query* of submissions
    # and add more where clause limiting the submission to be in the
    # rnage specified only
    def submission_in_range(range_params)
      range_params ||= {}
      if range_params[:use] ==  'sub_id'
        Submission.by_id_range(range_params[:from_id], range_params[:to_id])
      else
        # use sub time
        since_time = Time.zone.parse(range_params[:from_time]) || Time.zone.now.beginning_of_day rescue Time.zone.now.beginning_of_day
        until_time = Time.zone.parse(range_params[:to_time]) || Time.zone.now.end_of_day rescue Time.zone.now.end_of_day
        Submission.by_submitted_at(since_time, until_time)
      end
    end

    # build @problems that matches the given params
    def selected_problems
      # start with reportable problems (this already considers when @current_user is an admin)
      @problems = Problem.where(id: @current_user.problems_for_action(:report).ids)

      if params[:probs].present?
        prob_use = params[:probs][:use] rescue ''
        if prob_use == 'all'
          @problems = Problem.all
        elsif prob_use == 'ids'
          @problems = @problems.where(id: params[:probs][:ids])
        elsif prob_use == 'groups'
          ids = Group.where(id: params[:probs][:group_ids]).joins(:problems).pluck(:problem_id).uniq
          @problems = @problems.where(id: ids)
        elsif prob_use == 'tags'
          ids = Tag.where(id: params[:probs][:tag_ids]).joins(:problems).pluck(:problem_id).uniq
          @problems = @problems.where(id: ids)
        end
      end

      # sort it
      @problems = @current_user.problems_for_action(:report).where(id: @problems.ids).default_order
    end

    def selected_users
      if params[:users].present?
        @users = if params[:users][:use] == "group" then
                   User.where(id: Group.where(id: params[:users][:group_ids]).joins(:groups_users).pluck(:user_id))
        elsif params[:users][:use] == 'enabled'
                   User.where(enabled: true)
        elsif params[:users][:use] == 'all'
                   User.all
        else
                   User.all
        end
      else
        @users = User.all
      end

      # if user is not admin, filter users to be only those that are reportable
      @users = @users.where(id: @current_user.reportable_users) unless @current_user.admin?
    end

    def hall_of_fame_authorization
      return true if @current_user.admin?
      unauthorized_redirect(msg: 'Hall of fame is disabled') unless GraderConfiguration["right.user_hall_of_fame"]
    end

    def set_problem
      @problem = Problem.find(params[:id])
    end

    def get_total_scores_at(time, admin_ids, prob_ids, group_mode = false)
      # 1. Max points per user/problem
      max_pts = Submission.where(problem_id: prob_ids)
      max_pts = max_pts.where("submitted_at <= ?", time) if time
      max_pts = max_pts.group(:user_id, :problem_id)
        .select('user_id, problem_id, MAX(points) as max_pts')

      # 2. LLM costs per user/problem
      llm_costs = Comment.joins("INNER JOIN submissions ON comments.commentable_id = submissions.id AND comments.commentable_type = 'Submission'")
      llm_costs = llm_costs.where("submissions.submitted_at <= ?", time) if time
      llm_costs = llm_costs.where("submissions.problem_id": prob_ids)
        .where(kind: 'llm_assist')
        .group('submissions.user_id, submissions.problem_id')
        .select('submissions.user_id, submissions.problem_id, SUM(comments.cost) as llm_cost')

      # 3. Hint costs per user/problem
      hint_costs = Comment.joins(:comment_reveals)
      hint_costs = hint_costs.where("comment_reveals.created_at <= ?", time) if time
      hint_costs = hint_costs.where(commentable_type: 'Problem')
        .where(commentable_id: prob_ids)
        .group('comment_reveals.user_id, comments.commentable_id')
        .select('comment_reveals.user_id, comments.commentable_id as problem_id, SUM(comments.cost) as hint_cost')

      # First Blood bonus calculation at `time`
      bonus_scores = Hash.new(0.0)
      bonus_problems = Problem.where(id: prob_ids).where.not(bonus_first_blood: [nil, 0])
      bonus_problems.each do |p|
        n = p.respond_to?(:first_n_bloods) ? p.first_n_bloods : 0
        next if n <= 0
        subs = p.submissions.tag_default
          .where("submissions.points >= ?", p.full_score || 100)
          .where.not(user_id: admin_ids)
        subs = subs.where("submissions.submitted_at <= ?", time) if time
        blood_user_ids = subs.order(submitted_at: :asc, id: :asc).limit(n).pluck(:user_id).uniq
        blood_user_ids.each do |uid|
          bonus_scores[uid] += p.bonus_first_blood.to_f
        end
      end

      if group_mode
        group_bonus_scores = Hash.new(0.0)
        Group.joins(:groups_users).pluck('groups.id, groups_users.user_id').each do |group_id, user_id|
          group_bonus_scores[group_id] += bonus_scores[user_id]
        end
        bonus_scores = group_bonus_scores

        raw_and_deductions = Group.joins(:users).joins("INNER JOIN (#{max_pts.to_sql}) mp ON users.id = mp.user_id")
          .joins("INNER JOIN problems ON problems.id = mp.problem_id")
          .joins("LEFT JOIN (#{llm_costs.to_sql}) lc ON users.id = lc.user_id AND problems.id = lc.problem_id")
          .joins("LEFT JOIN (#{hint_costs.to_sql}) hc ON users.id = hc.user_id AND problems.id = hc.problem_id")
          .where.not(users: {id: admin_ids})
          .group('groups.id')
          .select('groups.id', 'SUM(COALESCE(mp.max_pts, 0)) as raw_score', 'SUM(COALESCE(lc.llm_cost, 0) + COALESCE(hc.hint_cost, 0)) as deducted_score')
          .each_with_object({}) { |g, h| h[g.id] = { raw: g.raw_score.to_f, deducted: g.deducted_score.to_f } }
      else
        raw_and_deductions = User.where.not(id: admin_ids)
          .joins("INNER JOIN (#{max_pts.to_sql}) mp ON users.id = mp.user_id")
          .joins("INNER JOIN problems ON problems.id = mp.problem_id")
          .joins("LEFT JOIN (#{llm_costs.to_sql}) lc ON users.id = lc.user_id AND problems.id = lc.problem_id")
          .joins("LEFT JOIN (#{hint_costs.to_sql}) hc ON users.id = hc.user_id AND problems.id = hc.problem_id")
          .group('users.id')
          .select('users.id', 'SUM(COALESCE(mp.max_pts, 0)) as raw_score', 'SUM(COALESCE(lc.llm_cost, 0) + COALESCE(hc.hint_cost, 0)) as deducted_score')
          .each_with_object({}) { |u, h| h[u.id] = { raw: u.raw_score.to_f, deducted: u.deducted_score.to_f } }
      end

      result = {}
      all_ids = (raw_and_deductions.keys + bonus_scores.keys).uniq
      all_ids.each do |id|
        rd = raw_and_deductions[id] || { raw: 0.0, deducted: 0.0 }
        bonus = bonus_scores[id] || 0.0
        total = [0.0, rd[:raw] - rd[:deducted] + bonus].max
        result[id] = { raw: rd[:raw], deducted: rd[:deducted], bonus: bonus, total: total }
      end
      result
    end

    def restrict_setter_reports
      if @current_user.problem_setter? && !@current_user.admin?
        unauthorized_redirect(msg: 'You are only authorized to view the statistics report.')
      end
    end
end
