class Problem < ApplicationRecord
  include Auditable
  audited only: %i[name full_name full_score available live_dataset_id
                   view_testcase view_submission allow_hint
                   permitted_lang submission_filename task_type compilation_type
                   max_submissions bonus_first_blood first_n_bloods]

  # -- fields --
  # how the submission should be compiled
  enum :compilation_type, { self_contained: 0,
                            with_managers:  1,
                            viva_exam:      2 }
  enum :task_type, { batch: 0 }

  # belongs_to :description

  # -- association --
  has_and_belongs_to_many :contests, uniq: true

  # has_and_belongs_to_many :groups
  has_many :groups_problems, class_name: 'GroupProblem', dependent: :destroy
  has_many :groups, through: :groups_problems

  has_many :contests_problems, class_name: 'ContestProblem', dependent: :destroy
  has_many :contests, through: :contests_problems

  has_many :problems_tags, class_name: 'ProblemTag', dependent: :destroy
  has_many :tags, through: :problems_tags
  has_many :public_tags, -> { where(public: true) }, class_name: 'Tag', through: :problems_tags, source: :tag

  has_many :test_pairs, dependent: :delete_all

  # testcase is all the testcases
  has_many :testcases, dependent: :destroy

  has_many :submissions, dependent: :destroy
  has_one :problem_stat, dependent: :destroy

  has_many :comments, as: :commentable, dependent: :destroy

  # This allows you to get all comment reveals for comments belonging to this problem
  has_many :comment_reveals, through: :comments

  has_many :datasets, dependent: :destroy
  belongs_to :live_dataset, class_name: 'Dataset', optional: true

  # -- validations --
  validates_presence_of :name
  validates_uniqueness_of :name
  validates_format_of :name,
    with: /\A[a-zA-Z\d\-\_\[\]()]+\z/,
    message: 'contains invalid characters. Only letters, numbers, <code>( )</code>, <code>[ ]</code>, <code>-</code> and <code>_</code> are allowed.'.html_safe

  validates_presence_of :full_name
  validates_presence_of :full_score

  validates :max_submissions, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  validates :first_n_bloods, numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true

  # -- callback --
  after_initialize :set_default_full_score, if: :new_record?
  after_save :generate_and_attach_pdf_statement_later, if: :should_generate_pdf?

  def set_default_full_score
    self.full_score ||= 100
  end

  def effective_full_score
    if live_dataset&.st_raw_sum?
      count = live_dataset.testcases.count
      count > 0 ? count : (full_score || 0)
    else
      full_score || 0
    end
  end

  def first_n_bloods
    val = self[:first_n_bloods]
    val.present? ? val : 0
  end

  def first_blood_user
    first_n_blood_users(1).first
  end

  def first_n_blood_users(n = 1)
    num = (n.present? && n >= 0) ? n : 1
    return [] if num == 0
    
    exclude_ids = User.joins(:roles).where(roles: { name: ['admin', 'problem_setter'] }).pluck(:id)
    exclude_ids = (exclude_ids + User.where(enabled: false).pluck(:id)).uniq
    
    results = submissions.tag_default.joins(:user)
                .where(points: full_score)
                .where.not(user_id: exclude_ids)
                .group(:user_id)
                .select('user_id, MIN(submissions.id) as first_sub_id, MIN(submitted_at) as first_time')
                .order('first_time ASC')
                .limit(num)
    
    User.where(id: results.map(&:user_id)).index_by(&:id).values_at(*results.map(&:user_id)).compact
  end

  # -- scope --
  scope :available, -> { where(available: true) }

  scope :visible_to_user, ->(user) {
    if GraderConfiguration.contest_mode? || user&.admin? || user&.problem_setter?
      all
    elsif user
      where("NOT EXISTS (SELECT 1 FROM groups_problems WHERE groups_problems.problem_id = problems.id) OR EXISTS (
        SELECT 1 FROM groups_problems gp
        INNER JOIN `groups` g ON g.id = gp.group_id
        INNER JOIN groups_users gu ON gu.group_id = g.id
        WHERE gp.problem_id = problems.id
          AND gp.enabled = true
          AND g.enabled = true
          AND gu.user_id = ?
          AND gu.enabled = true
      )", user.id)
    else
      where("NOT EXISTS (SELECT 1 FROM groups_problems WHERE groups_problems.problem_id = problems.id)")
    end
  }

  # These group_xxx scopes ALWAYS take groups into account
  # REGARDLESS of the group mode configuration
  # It also NEGLECT admin privileges, i.e., you won't get any special treatment if you are an admin
  #
  # Please use User.problems_for_action if you want config and admin to be taken into account

  # return problems that is enabled and is in an enabled group that has the given user
  # this does not check whether the user is enabled
  #
  # please use User#problems_for_action when we want to consider everything
  scope :group_submittable_by_user, ->(user_id) {
    joins(groups_problems: {group: :groups_users})
      .where(available: true)                   # available problems only
      .where('groups.enabled': true)            # groups is enabled
      .where('groups_users.user_id': user_id)   # user is in the group
      .where('groups_users.enabled': true)      # user in the group is enabled
      .where('groups_problems.enabled': true)   # problem is enabled
      .distinct(:id)                            # get distinct
  }

  # Similar to group_submittable_by_user, but does not required GroupProblem.enabled to be enabled
  scope :group_reportable_by_user, ->(user_id) {
    group_actionable_by_user(user_id, ['editor', 'reporter'])
  }

  # Similar to group_submittable_by_user, but does not required GroupProblem.enabled to be enabled
  scope :group_editable_by_user, ->(user_id) {
    group_actionable_by_user(user_id, ['editor'])
  }

  scope :group_actionable_by_user, ->(user_id, roles = ['editor']) {
    joins(groups_problems: {group: :groups_users})
      .where(available: true)                   # available problems only
      .where('groups.enabled': true)            # groups is enabled
      .where('groups_users.user_id': user_id)   # user is in the group
      .where('groups_users.role': roles)        # filter for user with roles
      .distinct(:id)                            # get distinct
  }

  # These contest_xxx scope ALWAYS take contest into account
  # REGARDLESS of the contest mode configuration
  # It also NEGLECT admin privileges, i.e., you won't get any special treatment if you are an admin
  #
  # Please use User.problems_for_action if you want config and admin to be taken into account
  #
  # This returns all Problem that is submittable by the user in a contest
  scope :contests_problems_for_user, ->(user_id, contest: nil) {
    now = Time.zone.now
    q = joins(contests_problems: {contest: :contests_users})
      .where(available: true)                   # available problems only
      .where('contests.enabled': true)          # contests is enabled
      .where('contests_users.user_id': user_id) # user is in the contest
      .where('contests_users.enabled': true)    # user in the contest is enabled
      .where('contests_problems.enabled': true) # problem is enabled
      .where('ADDTIME(contests.start,-contests_users.start_offset_second) <= ?', now)
      .where('ADDTIME(contests.stop,contests_users.extra_time_second) >= ?', now)
    q = q.where('contests.id': contest.id) if contest
    q.group('problems.id')
  }

  # return all problem that the user has "editing" rights in a contest
  #   if the user is an editor of the contest, they can always see the problems
  #   even if the contest is not "enabled"
  scope :contests_editable_problems_for_user, ->(user_id) {
    joins(contests_problems: {contest: :contests_users})
      .where(available: true)                   # available problems only
      .where('contests.enabled': true)          # contests is enabled
      .where('contests_users.user_id': user_id) # user is in the contest
      .where('contests_users.enabled': true)    # user in the contest is enabled
      .where('contests_users.role': 'editor')   # user must have 'editor' role
      .distinct('problems.id')
  }

  scope :default_order, -> {
    if GraderConfiguration.contest_mode?
      left_joins(:contests_problems).group('problems.id').order(Arel.sql('MIN(contests_problems.number)'))
    else
      order(:number).order(:name)
    end
  }

  before_create :assign_default_number

  def assign_default_number
    self.number ||= (Problem.maximum(:number) || 0) + 1
  end

  def self.set_problem_number(problem, number)
    num = 1
    Problem.where.not(id: problem.id).order(:number).each do |p|
      offset = (num >= number) ? 1 : 0
      p.update_columns(number: num + offset)
      num += 1
    end
    problem.update_columns(number: [Problem.count, [1, number.round].max].min)
  end

  DEFAULT_TIME_LIMIT = 1
  DEFAULT_MEMORY_LIMIT = 32

  # attachment here are the public one,
  # if the user has the right to submit, the user can see the attachments (and statement)
  has_one_attached :statement
  has_one_attached :generated_statement # statement generated from the description
  has_one_attached :attachment  # this is public files seen by contestant

  def set_default_value
  end

  # -- submission limit helpers --

  # Returns true if this problem has a submission limit configured
  def submission_limit?
    return false unless GraderConfiguration.show_submission_limits?
    max_submissions.present? && max_submissions > 0
  end

  # Returns the number of submissions the given user has made to this problem
  def submission_count_for(user)
    submissions.where(user: user).count
  end

  def extra_submission_limit_for(user, contest)
    return 0 unless user && contest
    cu = ContestUser.find_by(user_id: user.id, contest_id: contest.id)
    cu ? (cu.extra_sub_limit || 0) : 0
  end

  def max_submissions_for(user, contest = nil)
    limit = max_submissions || 0
    if contest
      limit += extra_submission_limit_for(user, contest)
    end
    limit
  end

  # Returns how many submissions remain for the user, or nil if unlimited
  def submissions_remaining_for(user, contest = nil)
    return nil if user&.admin? || user&.problem_setter?
    return nil unless submission_limit?
    [max_submissions_for(user, contest) - submission_count_for(user), 0].max
  end

  # Returns true if the user has reached the submission limit
  # Admins and problem setters are never subject to submission limits
  def submission_limit_reached?(user, contest = nil)
    return false if user&.admin? || user&.problem_setter?
    return false unless submission_limit?
    submission_count_for(user) >= max_submissions_for(user, contest)
  end

  def viva_grounding_tags
    tags.where(kind: :viva_grounding)
  end

  def viva_prompt_tags
    tags.where(kind: :llm_prompt)
  end

  # Required-section markers a viva problem's llm_prompt content must
  # contain. Keeping this as a constant so it's easy to relax / extend
  # without rewriting the validation method. The scenario itself is
  # delivered to the model via the attached statement PDF, not via
  # problem.description, so we don't validate the description text.
  VIVA_PROMPT_REQUIRED_SECTIONS = {
    /^#+\s*Rubric\b/im => "an llm_prompt section starting with '# Rubric' (or ##/###)"
  }.freeze

  # Returns an array of human-readable error strings if the problem isn't
  # set up correctly to run a viva — empty array means good to go. Called
  # from VivaSessionsController#start before any LLM work happens, so the
  # student gets a clear flash message instead of the viva starting in a
  # half-configured state.
  def viva_setup_errors
    return [] unless viva_exam?
    errors = []

    prompt = viva_prompt_tags.map(&:params).reject(&:blank?).join("\n\n")
    if prompt.blank?
      errors << "Problem has no llm_prompt tag attached"
    else
      VIVA_PROMPT_REQUIRED_SECTIONS.each do |pattern, label|
        errors << "llm_prompt is missing #{label}" unless prompt =~ pattern
      end
    end

    errors
  end

  def viva_setup_valid?
    viva_setup_errors.empty?
  end

  def can_view_testcase
    GraderConfiguration.show_testcase && self.view_testcase
  end

  def get_jschart_history
    start = 4.month.ago.beginning_of_day
    start_date = start.to_date
    count = Submission.where(problem: self).where('submitted_at >= ?', start).group('DATE(submitted_at)').count
    i = 0
    label = []
    value = []
    while start_date + i < Time.zone.now.to_date
      if (start_date+i).day == 1
        # label << (start_date+i).strftime("%d %b %Y")
        # label << (start_date+i).strftime("%d")
      else
        # label << ' '
        # label << (start_date+i).strftime("%d")
      end
      label << (start_date+i).strftime("%d-%b")
      value << (count[start_date+i] || 0)
      i+=1
    end
    return {labels: label,
            datasets: [label: 'sub', data: value, backgroundColor: 'rgba(54, 162, 235, 0.2)', borderColor: 'rgb(75, 192, 192)']}
  end

  def get_next_dataset_name(base = 'Dataset')
    num = 1
    name = base + " #{num}"
    while datasets.where(name: name).count > 0
      num += 1
      name = base + " #{num}"
    end
    return name
  end


  def self.create_from_import_form_params(params, old_problem = nil)
    org_problem = old_problem || Problem.new
    import_params, problem = Problem.extract_params_and_check(params,
                                                              org_problem)
    if !problem.errors.empty?
      return problem, 'Error importing'
    end

    problem.date_added = Time.new
    problem.test_allowed = true
    problem.output_only = false
    problem.available = false

    if not problem.save
      return problem, 'Error importing'
    end

    import_to_db = params.has_key? :import_to_db

    importer = TestdataImporter.new(problem)

    if not importer.import_from_file(import_params[:file],
                                     import_params[:time_limit],
                                     import_params[:memory_limit],
                                     import_params[:checker_name],
                                     import_to_db)
      problem.errors.add(:base, 'Import error.')
    end

    return problem, importer.log_msg
  end

  def self.download_file_basedir
    return "#{Rails.root}/data/tasks"
  end

  def get_submission_stat
    result = Hash.new
    # total number of submission
    result[:total_sub] = Submission.where(problem_id: self.id).count
    result[:attempted_user] = Submission.where(problem_id: self.id).group(:user_id)
    result[:pass] = Submission.where(problem_id: self.id).where("points >= ?", 100).count
    return result
  end

  def long_name
    "[#{name}] #{full_name}"
  end

  # ------------------------
  # -- HINT section begin --
  # ------------------------
  def hints
    comments.where(kind: :hint)
  end

  # indicate weather this problem has a helper (hints, comments)
  def helpers?
    hints.any?
  end

  # return a records of all comment with the reveal status
  # to get all hints, we can use comment_with_reveal_status(user,kind: 'hint')
  def comments_with_reveal_status(user, kind: nil)
    query = comments
    query = query.where(kind: kind) if kind.present?
    if GraderConfiguration.enable_all_hints?
      query.select('comments.*', "1 AS is_acquired")
    else
      query.select('comments.*', "EXISTS(SELECT 1 FROM comment_reveals WHERE user_id = #{user.id} AND comment_id = comments.id AND is_success = 1) AS is_acquired")
    end
  end

  # this method is used both in acquiring and viewing
  def comment_reveal_prerequisite_satisfied?(comment, user)
    case comment.kind
    when 'hint'
      # user want to reveal a hint
      return true if GraderConfiguration.enable_all_hints?


      # check if the problem allow hint
      return false unless self.allow_hint?

      # check if the user has the right to the problem
      return false unless user.problems_for_action(:submit).where(id: self).any?

      # if the current mode is a contest, also check the contest
      if GraderConfiguration.contest_mode?
        # TODO: this is WRONG, need to check actual active time
        return false unless self.contests.enabled.where(allow_hint: true).any?
      end

      # check if the user has enough points globally
      if comment.all_points
        # any score is fine, including 0
        return true
      else
        cost = comment.point_cost || 0
        return false if cost > 0 && user.current_score < cost
      end

      # pass all checks
      return true
    else
      false
    end
  end

  def helpers_cost(user,contest)
    Comment.cost_summary_for(user,contest)
  end

  # return the enabled comments of the specified *kind* that are revealed by *user*
  def revealed_comments_for_user(user, kind)
    commens.joins(:comment_reveals).where(enabled: true, comment_reveals: {user: user, kind: kind})
  end
  # ----------------------
  # -- HINT section end --
  # ----------------------

  # ids_string is something like ['1','3','7']
  # which correspond to the submitted value from  select2 multiple selection
  def set_permitted_lang_from_ids_string(ids_string)
    lang_names = ids_string.reject(&:empty?).map { |x| Language.find(x.to_i).name }.join(' ')
    self.permitted_lang = lang_names
  end

  # return ids array of permitted lang
  # if permitted_lang is blank, show nil
  def get_permitted_lang_as_ids(when_blank: Language.ids)
    return when_blank if self.permitted_lang.blank?
    return Language.where(name: self.permitted_lang.split(' ').uniq).ids
  end

  # this function return a content generated for "all_tests.cfg"
  # from the legacy code (Aj. Pong's)
  # This is definitely not complete but it works in general cases
  def build_legacy_config_file
    default = {
      time_limit: 1.0,
      mem_limit: 512,
      score: 10
    }

    result = ["problem do"]
    result << "  num_tests #{testcases.count}"
    result << "  full_score #{testcases.count}"
    result << "  time_limit_each #{default[:time_limit]}"
    result << "  mem_limit_each #{default[:mem_limit]}"
    result << "  score_each #{default[:score]}"
    result << ""

    testcases.order(:num).each do |tc|
      result << "  run #{tc.num} do"
      result << "    tests #{tc.num}"
      result << "    scores #{tc.score}"
      result << "  end"
      result << ""
    end

    result << "end\n"
    return result.join "\n"
  end

  def self.check_name(replace: false, with: '')
    Problem.find_each do |problem|
      unless problem.valid?
        puts "Problem #{problem.id}: [#{problem.name}] is invalid"
      end
    end
  end


  # TODO: change to language specific
  def exec_filename(language)
    case language.name
    when 'cpp'
      'a.out'
    when 'python'
      'cafe_code.py'
    when 'java', 'digital'
      # for java, the compilation create a shell script that runs the file
      'run.sh'
    else
      'submission'
    end
  end

  # export  the problem into the default dump dir
  def export
    pe = ProblemExporter.new
    pe.export_problem_to_dir(self, zip: true)
  end

  def regenerate_pdf_statement!
    ProblemPdfGenerator.new(self).call
  end

  # -- private section --
  private

  def should_generate_pdf?
    (new_record? || saved_change_to_attribute?(:description)) && description.present?
  end

  def generate_and_attach_pdf_statement_later
    # Pass the entire object to the job, not just the ID.
    # This avoids another database query in the job if the object is simple.
    # For very large objects, passing the ID is better: perform(self.id).
    CreateProblemPdfJob.perform_later(self)
  end
end
