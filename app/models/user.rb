require 'digest/sha1'
require 'net/pop'
require 'net/https'
require 'net/http'
require 'json'
require 'argon2'

class User < ApplicationRecord
  THEMES = %w[default dark premium ocean solarized space_legacy].freeze

  has_and_belongs_to_many :roles

  # has_and_belongs_to_many :groups
  has_many :groups_users, class_name: 'GroupUser', dependent: :destroy
  has_many :groups, through: :groups_users

  has_many :test_requests, -> { order(submitted_at: :desc) }, dependent: :destroy

  has_many :messages, -> { order(created_at: :desc) },
           class_name: "Message",
           foreign_key: "sender_id",
           dependent: :destroy

  has_many :replied_messages, -> { order(created_at: :desc) },
           class_name: "Message",
           foreign_key: "receiver_id",
           dependent: :destroy

  has_many :logins, dependent: :destroy

  has_many :submissions, dependent: :destroy

  has_one :contest_stat, class_name: "UserContestStat", dependent: :destroy

  belongs_to :site, optional: true
  belongs_to :country, optional: true

  belongs_to :default_language, class_name: 'Language', foreign_key: 'default_language_id', optional: true

  # contest
  has_many :contests_users, class_name: 'ContestUser', dependent: :destroy
  has_many :contests, through: :contests_users

  # comments
  has_many :comment_reveals, dependent: :destroy
  has_many :revealed_comments, through: :comment_reveals, source: :comment
  has_many :comments, dependent: :destroy
  has_many :heart_beats, dependent: :destroy

  scope :activated_users, -> { where activated: true }

  validates_presence_of :login
  validates_uniqueness_of :login
  validates_format_of :login, with: /\A[\_A-Za-z0-9]+\z/
  validates_length_of :login, within: 3..30

  validates_presence_of :full_name
  validates_length_of :full_name, minimum: 1

  validates_presence_of :password, if: :password_required?
  validates_length_of :password, within: 4..50, if: :password_required?
  validates_confirmation_of :password, if: :password_required?

  validates_inclusion_of :theme, in: THEMES, allow_nil: true

  validates_format_of :email,
                      with: /\A([^@\s]+)@((?:[-a-z0-9]+\.)+[a-z]{2,})\Z/i,
                      if: :email_validation?
  validate :uniqueness_of_email_from_activated_users,
           if: :email_validation?
  validate :enough_time_interval_between_same_email_registrations,
           if: :email_validation?

  # these are for ytopc
  # disable for now
  # validates_presence_of :province

  attr_accessor :password

  before_save :encrypt_new_password
  before_save :assign_default_site
  before_save :assign_default_contest

  def bonus_score
    # Includes "N-th Blood" bonus
    # We find all problems where this user is one of the N-th blooders
    return 0 unless GraderConfiguration.show_first_bloods?
    total_bonus = 0
    Problem.where.not(bonus_first_blood: [nil, 0]).find_each do |problem|
      n = problem.respond_to?(:first_n_bloods) ? problem.first_n_bloods : 0
      if problem.first_n_blood_users(n).include?(self)
        total_bonus += problem.bonus_first_blood
      end
    end
    total_bonus
  end

  def current_score
    problems = problems_for_action(:submit, respect_admin: false)
    
    # Calculate range of time (in contest mode)
    time_range = active_contests_range if GraderConfiguration.contest_mode?
    start_time = time_range ? time_range.begin : nil
    stop_time = time_range ? time_range.end : nil

    records = Submission.where(user: self, problem: problems)
    records = records.where(submitted_at: time_range) if time_range

    records = records.max_score_report(problems, start_time, stop_time)
    
    # Sum of raw max points per problem
    raw_problem_scores = records.to_a.sum { |r| r.max_score.to_d }
    
    # Total deductions from all comment reveals (hints, LLM assists, etc.)
    # Only count deductions for problems that are currently available to the user
    # 1. Deductions from Problem hints
    problem_hint_deductions = comment_reveals.joins("INNER JOIN comments ON comments.id = comment_reveals.comment_id AND comments.commentable_type = 'Problem'")
                                             .joins("INNER JOIN problems ON problems.id = comments.commentable_id")
                                             .where(problems: { available: true })
                                             .sum('comments.cost') || 0

    # 2. Deductions from Submission LLM assistance
    submission_deductions = comment_reveals.joins("INNER JOIN comments ON comments.id = comment_reveals.comment_id AND comments.commentable_type = 'Submission'")
                                           .joins("INNER JOIN submissions ON submissions.id = comments.commentable_id")
                                           .joins("INNER JOIN problems ON problems.id = submissions.problem_id")
                                           .where(problems: { available: true })
                                           .sum('comments.cost') || 0

    total_deductions = problem_hint_deductions + submission_deductions
    
    deductions = GraderConfiguration.enable_penalty? ? total_deductions : 0.0
    bonus = GraderConfiguration.enable_bonus? ? bonus_score : 0.0

    [0.0, (raw_problem_scores - deductions + bonus).to_f].max
  end
  def enabled?
    !!self[:enabled]
  end

  # ---- problem for the users for specific action ------
  # Determines which problems a user is authorized to perform the specified action on.
  #
  # This should be the MAIN authorization filter for problem-related action and
  # should be used to scope problem lookups from the user's perspective.
  #
  # It considers following logics
  # * User's special global role of admin (admins always have right)
  # * The mode of the grader
  #   * the Group Mode and user's role and the enable property in the group
  #   * the Contest Mode and the user's role and the enable property in the contest
  # * The global enable property of the user
  #
  # In short, PLEASE USE this function when we need authorization of a user
  #
  # The respect_admin, when true, will cause this function to return all problems for an admin
  # The only place that respect_admin: false should be used is in the main page where the admin
  # is treated as a normal user
  #
  # valid action are :submit, :report, or :edit
  def problems_for_action(action, respect_admin: true, contest: nil)
    return Problem.all if (admin? || problem_setter?) && respect_admin
    return Problem.none unless enabled? || (admin? || problem_setter?)

    action = action.to_sym
    return Problem.none if [:edit, :report].include?(action)

    res = if GraderConfiguration.multicontests?
      # legacy mode, have not been implemented yet
      Problem.contests_problems_for_user(self.id, contest: contest).none
    elsif GraderConfiguration.contest_mode?
      if (admin? || problem_setter?)
        if contest
          Problem.joins(:contests_problems)
                 .where(available: true)
                 .where(contests_problems: { contest_id: contest.id, enabled: true })
        else
          Problem.joins(contests_problems: :contest)
                 .where(available: true)
                 .where(contests_problems: { enabled: true })
                 .where(contests: { enabled: true })
        end
      else
        Problem.contests_problems_for_user(self.id, contest: contest)
      end
    else
      # normal mode
      if GraderConfiguration.use_problem_group?
        Problem.group_submittable_by_user(self.id)
      else
        Problem.available
      end
    end

    res.visible_to_user(self)
  end

  # ---- groups for the users for specific action ------
  # * This includes logic of User.role where admin always has right to any group
  # * This also includes logics of mode of the grader (normal, contest, analysis)
  # * This also consider whether the user is enabled ---
  # * This DOES NOT respect group_mode, it always performed as the group mode is enabled
  #
  # valid action is either :submit, :report, :edit
  def groups_for_action(action)
    return Group.all if admin? || problem_setter?
    return Group.none unless enabled?

    action = action.to_sym
    return Group.none if [:edit, :report].include?(action)

    # normal mode
    Group.submittable_by_user(self.id)
  end

  # ---- groups for the users for specific action ------
  # * This includes logic of User.role where admin always has right to any group
  # * This also includes logics of mode of the grader (normal, contest, analysis)
  # * This also consider whether the user is enabled ---
  # * This DOES NOT respect group_mode, it always performed as the group mode is enabled
  #
  # valid action is either :submit, :edit
  def contests_for_action(action)
    return Contest.all if admin? || problem_setter?
    return Contest.none unless enabled?
    action = action.to_sym

    # normal mode
    if action == :edit
      return Contest.none
    elsif action == :submit
      return Contest.submittable_by_user(self.id)
    else
      raise ArgumentError.new('action must be one of :edit, :submit')
    end
  end

  def reportable_users
    return User.all if admin? || problem_setter?
    User.joins(:groups).where(groups: {id: groups_for_action(:report)}).distinct
  end

  # ---- announcement for users for specific action -----
  # valid action is either :view, :edit
  def announcement_for_action(action)
    return Announcement.all if admin?
    return Announcement.none unless enabled?
    action = action.to_sym

    if action == :view
      return Announcement.viewable_by_user(self)
    elsif action == :edit
      return Announcement.editable_by_user(self)
    else
      raise ArgumentError.new('action must be one of :edit, :submit')
    end
  end

  # return contests of this user that is both enabled and the current time
  # is during the contest (including pre-contest and post-contest buffer times)
  def active_contests
    if GraderConfiguration.contest_mode?
      contests.where(enabled: true).select do |contest|
        pre_start = contest.start - (contest.pre_contest_seconds || 0).seconds
        post_stop = contest.stop + (contest.post_contest_seconds || 0).seconds
        Time.zone.now >= pre_start && Time.zone.now <= post_stop
      end
    else
      return []
    end
  end

  # return datetime range of active contests (including pre-contest and post-contest buffer times)
  def active_contests_range
    start = Date.new(9999, 1, 1).to_time
    stop = Date.new(1, 1, 1).to_time
    active_contests.each do |contest|
      start = [start, contest.start - (contest.pre_contest_seconds || 0).seconds].min
      stop = [stop, contest.stop + (contest.post_contest_seconds || 0).seconds].max
    end
    return start..stop
  end

  def self.authenticate(login, password)
    user = find_by_login(login)
    if user
      return user if user.authenticated?(password)
    end
  end

  def authenticated?(password)
    return false unless self.activated
    return false if hashed_password.blank?

    if hashed_password.start_with?('$argon2')
      Argon2::Password.verify_password(password, hashed_password)
    else
      # legacy SHA1
      if hashed_password == User.encrypt(password, self.salt)
        # lazy migration to Argon2
        self.password = password
        encrypt_new_password
        self.save(validate: false)
        return true
      end
      return false
    end
  end

  def login_with_name
    "[#{login}] #{full_name}"
  end

  def admin?
    @is_admin = has_role?('admin') if @is_admin.nil?
    return @is_admin
  end

  def problem_setter?
    @is_problem_setter = has_role?('problem_setter') if @is_problem_setter.nil?
    return @is_problem_setter
  end

  def has_role?(role)
    self.roles.where(name: [role, 'admin']).any?
  end

  def email_for_editing
    if self.email==nil
      "(unknown)"
    elsif self.email==''
      "(blank)"
    else
      self.email
    end
  end

  def email_for_editing=(e)
    self.email=e
  end

  def alias_for_editing
    if self.alias==nil
      "(unknown)"
    elsif self.alias==''
      "(blank)"
    else
      self.alias
    end
  end

  def alias_for_editing=(e)
    self.alias=e
  end

  def activation_key
    if self.hashed_password==nil
      encrypt_new_password
    end
    Digest::SHA1.hexdigest(self.hashed_password)[0..7]
  end

  def verify_activation_key(key)
    key == activation_key
  end

  def self.random_password(length = 5)
    chars = 'abcdefghjkmnopqrstuvwxyz'
    password = ''
    length.times { password << chars[rand(chars.length - 1)] }
    password
  end


  # Contest information

  def self.find_users_with_no_contest
    users = User.all
    return users.find_all { |u| u.contests.length == 0 }
  end

  # ---------------------
  # ---- contest --------
  # ---------------------

  # original contest
  def contest_time_left
    if GraderConfiguration.contest_mode?
      return nil if site==nil
      return site.time_left
    elsif GraderConfiguration.indv_contest_mode?
      time_limit = GraderConfiguration.contest_time_limit
      if time_limit == nil
        return nil
      end
      if contest_stat==nil or contest_stat.started_at==nil
        return (Time.now.gmtime + time_limit) - Time.now.gmtime
      else
        finish_time = contest_stat.started_at + time_limit
        current_time = Time.now.gmtime
        if current_time > finish_time
          return 0
        else
          return finish_time - current_time
        end
      end
    else
      return nil
    end
  end


  def contest_finished?
    if GraderConfiguration.contest_mode?
      return false if site==nil
      return site.finished?
    elsif GraderConfiguration.indv_contest_mode?
      return false if self.contest_stat==nil
      return contest_time_left == 0
    else
      return false
    end
  end

  def contest_started?
    if GraderConfiguration.indv_contest_mode?
      stat = self.contest_stat
      return ((stat != nil) and (stat.started_at != nil))
    elsif GraderConfiguration.contest_mode?
      return true if site==nil
      return site.started
    else
      return true
    end
  end

  def update_start_time
    stat = self.contest_stat
    if stat.nil? or stat.started_at.nil?
      stat ||= UserContestStat.new(user: self)
      stat.started_at = Time.now.gmtime
      stat.save
    end
  end

  def problem_in_user_contests?(problem)
    problem_contests = problem.contests.all

    if problem_contests.length == 0   # this is public contest
      return true
    end

    contests.each do |contest|
      if problem_contests.find { |c| c.id == contest.id }
        return true
      end
    end
    return false
  end


  def solve_all_available_problems?
    problems_for_action(:submit).each do |p|
      u = self
      sub = Submission.find_last_by_user_and_problem(u.id, p.id)
      return false if !p || !sub || sub.points < 100
    end
    return true
  end

  def last_submission_by_problem(problem)
    submissions.where(problem: problem).order(:submitted_at).last
  end

  #
  # -- permission methods ---
  #

  # check if the user has the right to view that problem
  # this also consider group based problem policy
  def can_view_problem?(problem)
    # admin always has right
    return true if admin? || problem_setter?

    # if a user is a reporter or an editor, they can access disabled problem, which is not allowed in problems_for_action(:submit)
    # we need both :report and :submit action because :report is not the super set of :submit
    # For example, a user can be a reporter (or an editor) for some group while being a normal user on some group
    return true if problems_for_action(:report).where(id: problem.id).any?

    # the final step is for submit
    return problems_for_action(:submit).where(id: problem.id).any?
  end

  def can_report_problem?(problem)
    # admin always has right
    return true if admin? || problem_setter?

    return problems_for_action(:report).where(id: problem.id).any?
  end

  def can_edit_problem?(problem)
    # admin always has right
    return true if admin? || problem_setter?
    return problems_for_action(:edit).where(id: problem).any?
  end

  # Whether the user can download the problem's statement PDF / external
  # URL. Mirrors can_view_problem? except that students don't see the
  # PDF for problem modes where it shouldn't be revealed (viva, today —
  # see Problem#pdf_visible_to_student?). Instructors and reporters
  # always see the brief; they need it to manage and grade.
  #
  # This is the SECURITY-BOUNDARY predicate — call it in controllers
  # that serve the PDF (ProblemsController#download_by_type, the API
  # file endpoint). Views that already iterate over problems the user
  # can submit to should NOT call this — it would N+1 — and should
  # just read problem.pdf_visible_to_student? directly.
  def can_view_problem_pdf?(problem)
    return true if admin?
    return true if can_edit_problem?(problem) || can_report_problem?(problem)
    return false unless can_view_problem?(problem)
    problem.pdf_visible_to_student?
  end

  def can_view_submission?(submission)
    # admin always has right
    return true if admin? || problem_setter?

    if submission.user_id == self.id
      return true
    elsif GraderConfiguration['system.group_score_type'] == 'group_max'
      self_group_ids = self.groups.joins(:groups_users).where(groups: { enabled: true }, groups_users: { enabled: true }).pluck(:id)
      owner_group_ids = submission.user.groups.joins(:groups_users).where(groups: { enabled: true }, groups_users: { enabled: true }).pluck(:id)
      if (self_group_ids & owner_group_ids).any?
        return true
      end
    end

    return false
  end

  def can_view_testcase?(problem)
    # admin always has right
    return true if admin? || problem_setter?

    return can_view_problem?(problem) && GraderConfiguration["right.view_testcase"]
  end

  def can_edit_announcement(announcement)
    # admin always has right
    return true if admin? || problem_setter?

    # if the announcement is not group specific or is in a group t
    return true if Announcement.editable_by_user(self).where(id: announcement).any?

    return false
  end


  #
  # -- end permission methods --
  #


  def self.clear_last_login
    User.update_all(last_ip: nil)
  end

  def get_jschart_user_sub_history
    start = 4.month.ago.beginning_of_day
    start_date = start.to_date
    count = Submission.where(user: self).where('submitted_at >= ?', start).group('DATE(submitted_at)').count
    i = 0
    label = []
    value = []
    while start_date + i < Time.zone.now.to_date
      label << (start_date+i).strftime("%d-%b")
      value << (count[start_date+i] || 0)
      i+=1
    end
    return {labels: label, datasets: [label: 'sub', data: value, backgroundColor: 'rgba(54, 162, 235, 0.2)', borderColor: 'rgb(75, 192, 192)']}
  end

  def get_jschart_user_contest_history(contest)
    cu = contest.contests_users.where(user: self).take
    start = contest.start - cu.start_offset_second.second
    stop = [Time.zone.now, contest.stop + cu.extra_time_second.second].min

    # divide into 120 step
    step = (stop - start) / 120

    # adjust
    step = [60, step].max
    step = (step / 60).to_i * 60

    submitted_at = contest.user_submissions(self).order(:submitted_at).pluck :submitted_at


    now = start
    i = 0
    label = []
    value = []
    while now < stop
      count = 0
      while i < submitted_at.count && submitted_at[i] < now + step.second
        count += 1
        i += 1
        puts "got #{submitted_at[i]} for #{now.strftime("%H:%M")}"
      end
      label << now.strftime("%H:%M")  # hours / minute
      value << count

      now += step.second
    end
    return {labels: label, datasets: [ {label: 'sub', data: value, backgroundColor: 'rgba(255, 99, 132,0.8)', borderColor: 'rgb(255, 99, 132)'}]}
  end

  # create multiple user, one per lines of input
  # This one is used in the import of Users in the bulk manage user page
  def self.create_from_list(lines)
    error_logins = []
    first_error = nil
    created_user_ids = []
    updated_user_ids = []

    lines.split("\n").each do |line|
      # split with large limit, this will cause consecutive ',' to be result in a blank
      items = line.chomp.split(',', 1000)
      if items.length>=2
        login = items[0]
        full_name = items[1]
        remark =''
        user_alias = ''

        added_random_password = false
        added_password = false

        # given password?
        if items.length >= 3
          if items[2].chomp(" ").length > 0
            password = items[2].chomp(" ")
            added_password = true
          end
        else
          password = random_password
          added_random_password=true
        end

        # given alias?
        if items.length>= 4 and items[3].chomp(" ").length > 0
          user_alias = items[3].chomp(" ")
        else
          user_alias = login
        end

        # given remark?
        has_remark = false
        if items.length>=5
          remark = items[4].strip
          has_remark = true
        end

        user = User.find_by_login(login)
        created = false
        if user
          user.full_name = full_name
          user.remark = remark if has_remark
          user.password = password if added_password || added_random_password
        else
          # create a random password if none are given
          password = random_password unless password
          user = User.new({login: login,
                           full_name: full_name,
                           password: password,
                           password_confirmation: password,
                           alias: user_alias,
                           remark: remark})
          created = true
        end
        user.activated = true

        if user.save
          if created
            created_user_ids << user.id
          else
            updated_user_ids << user.id
          end
        else
          error_logins << "'#{login}'"
          first_error = user.errors.full_messages.to_sentence unless first_error
        end
      end
    end

    return {error_logins: error_logins, first_error: first_error,
            created_users: User.where(id: created_user_ids), updated_users: User.where(id: updated_user_ids)}
  end

  protected
    def encrypt_new_password
      return if password.blank?
      self.hashed_password = Argon2::Password.create(self.password)
    end

    def assign_default_site
      # have to catch error when migrating (because self.site is not available).
      begin
        if self.site==nil
          self.site = Site.find_by_name('default')
          if self.site==nil
            self.site = Site.find(1)  # when 'default has be renamed'
          end
        end
      rescue
      end
    end

    def assign_default_contest
      # have to catch error when migrating (because self.site is not available).
      begin
        if self.contests.length == 0
          default_contest = Contest.find_by_name(GraderConfiguration['contest.default_contest_name'])
          if default_contest
            self.contests = [default_contest]
          end
        end
      rescue
      end
    end

    def password_required?
      self.hashed_password.blank? || !self.password.blank?
    end

    def self.encrypt(string, salt)
      Digest::SHA1.hexdigest(salt + string)
    end

    def uniqueness_of_email_from_activated_users
      user = User.activated_users.find_by_email(self.email)
      if user and (user.login != self.login)
        self.errors.add(:base, "Email has already been taken")
      end
    end

    def enough_time_interval_between_same_email_registrations
      return if !self.new_record?
      return if self.activated
      open_user = User.find_by_email(self.email,
                                     order: 'created_at DESC')
      if open_user and open_user.created_at and
          (open_user.created_at > Time.now.gmtime - 5.minutes)
        self.errors.add(:base, "There are already unactivated registrations with this e-mail address (please wait for 5 minutes)")
      end
    end

    def email_validation?
      begin
        return VALIDATE_USER_EMAILS
      rescue
        return false
      end
    end
end
