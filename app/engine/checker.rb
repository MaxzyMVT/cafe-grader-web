require 'open3'

class Checker
  include IsolateRunner
  include JudgeBase
  include Rails.application.routes.url_helpers

  # The checker/comparator (diff, relative.rb, postgres_checker.rb, or a problem-author-supplied
  # custom binary) runs on the worker host itself, not inside the submission's isolate box, so it
  # needs its own resource ceiling. Otherwise a large answer/output file or a pathological custom
  # checker can grow unbounded and exhaust host RAM outright.
  CHECKER_MEM_LIMIT_BYTES = 1.gigabyte
  CHECKER_CPU_LIMIT_SEC = 30

  # Each branch produces the shell command that compares submission output
  # to the expected answer. Semantics documented in
  # doc/dataset-scoring-and-evaluation.md — keep that file in sync with
  # this dispatch table when adding/changing evaluators.
  #
  # A language specific sub-class may override this method
  # it should return shell command that do the comparison
  def check_command(evaluation_type, input_file, output_file, ans_file)
    case evaluation_type
    when 'default'
      # -b: ignore amount-of-whitespace diffs; -B: ignore blank lines;
      # -Z: ignore trailing whitespace. Right default for most problems.
      return "diff -q -b -B -Z --strip-trailing-cr #{output_file} #{ans_file}"
    when 'exact'
      return "diff -q --strip-trailing-cr #{output_file} #{ans_file}"
    when 'relative'
      # Tokenizes on whitespace; numbers compared with EPSILON = 1e-6.
      prog = Rails.root.join 'lib', 'checker', (evaluation_type + ".rb")
      return "#{prog} #{input_file} #{output_file} #{ans_file}"
    when 'postgres'
      # Strips CREATE VIEW / DROP VIEW lines, then CMS-style scoring.
      prog = Rails.root.join 'lib', 'checker', 'postgres_checker.rb'
      return "#{prog} #{input_file} #{output_file} #{ans_file}"
    when 'custom_cms', 'custom_cms_raw'
      # User's checker. CMS/Codeforces convention: exit 0, score on
      # stdout, comment on stderr. _raw variant outputs a raw decimal
      # score meant to pair with score_type :raw_sum.
      return "#{@prob_checker_file} #{input_file} #{output_file} #{ans_file}"
    when 'custom_cafe'
      # User's checker. Receives <lang> <tc_num> <in> <out> <ans> 10.
      # Output is two lines: line1 CORRECT/INCORRECT/COMMENT:, line2 score
      # (note: score is divided by 10 in process_result_cafe).
      return "#{@prob_checker_file} #{@sub.language.name} #{@testcase.num} #{input_file} #{output_file} #{ans_file} 10"
    when 'no_check'
      # Reachable here but NOT in the Dataset#evaluation_type enum — see doc.
      return ""
    end
  end

  def process_result_cms(out, err)
    score = out.chomp.strip
    err = err.chomp.strip
    err = nil if ['translate:success', 'translate:wrong'].include? err   # remove CMS default "translate:success" and "translate:wrong" from the comment
    err = nil if err.blank?
    return EngineResponse::CheckerResult.by_score(score: score, comment: err)
  end

  def process_result_cms_raw(out, err)
    score = out.chomp.strip.to_d
    err = err.chomp.strip
    err = nil if err.blank?
    return EngineResponse::CheckerResult.partial(score: score, comment: err)
  end

  def process_result_cafe(out, err)
    arr = out.split("\n")
    if arr.count < 2
      return EngineResponse::CheckerResult.grader_error(comment: '(cafe-checker) output from checker is malformed')
    end
    score = arr[1].to_d/10
    if arr[0].upcase == "CORRECT"
      return EngineResponse::CheckerResult.correct(score: score)
    elsif arr[0].upcase == "INCORRECT"
      return EngineResponse::CheckerResult.wrong(score: score)
    elsif arr[0].split(':')[0].upcase == 'COMMENT'
      comment = arr[0][8...]
      return EngineResponse::CheckerResult.partial(score: score, comment: comment)
    else
      return EngineResponse::CheckerResult.grader_error(comment: '(cafe-checker) output from checker is malformed')
    end
  end

  def process_result(evaluation_type, out, err, status)
    case evaluation_type
    when 'default', 'exact', 'relative'
      # these standard check return 0 when correct
      if status.exitstatus == 0
        return EngineResponse::CheckerResult.correct
      else
        return EngineResponse::CheckerResult.wrong
      end
    when 'postgres'
      return process_result_cms(out, err)
    when 'custom_cms', 'custom_cms_raw', 'custom_cafe'
      if status.exitstatus == 0
        if evaluation_type == 'custom_cms'
          return process_result_cms(out, err)
        elsif evaluation_type == 'custom_cms_raw'
          return process_result_cms_raw(out, err)
        else
          return process_result_cafe(out, err)
        end
      else
        comment = "ERROR IN CHECKER!!!\n-- stderr --\n#{err}-- status -- #{status}"
        return EngineResponse::CheckerResult.grader_error(comment: comment)
      end
    when 'no_check'
      return EngineResponse::CheckerResult.partial(score: 0)
    else
      return EngineResponse::CheckerResult.grader_error(comment: 'Unknown evaluation type')
    end
  end

  # check if required files, that are, output from submttion, answer from problem
  # and any other file is there
  def check_for_required_file
    unless @output_file.exist?
      judge_log "Output file [#{@output_file.cleanpath}] does not exist", Logger::ERROR
      raise "Output file [#{@output_file.cleanpath}] does not exist"
    end
    unless @ans_file.exist?
      judge_log "Answer file [#{@ans_file.cleanpath}] does not exist", Logger::ERROR
      raise "Answer file [#{@ans_file.cleanpath}] does not exist"
    end
    if ['custom_cms', 'custom_cms_raw', 'custom_cafe'].include?(@ds.evaluation_type) &&
        (@prob_checker_file.nil? || @prob_checker_file.exist? == false)
      judge_log "Checker file does not exist", Logger::ERROR
      raise GraderError.new("Checker file does not exist", submission_id: @sub.id)
    end
  end

  def result_status_with_color(result)
    if result[:result] == :correct
      color = COLOR_GRADING_CORRECT
    elsif result[:result] == :wrong
      color = COLOR_GRADING_WRONG
    elsif result[:result] == :partial
      color = COLOR_GRADING_PARTIAL
    else
      color = :red
    end

    res = Rainbow(result[:result].to_s).color(color)
    res += " comment: #{result[:comment]}" unless result[:comment].blank?
    return res
  end

  # main run function
  # run the submission against the testcase
  def process(sub, testcase)
    @sub = sub
    @testcase = testcase
    @ds = @testcase.dataset

    # prepare files location variable
    prepare_submission_directory(@sub)
    prepare_dataset_directory(@ds)
    prepare_testcase_directory(@sub, @testcase)
    check_for_required_file

    cmd = check_command(@ds.evaluation_type, @input_file, @output_file, @ans_file)

    # call the compare command, bounded by rlimit so it can't exhaust worker host RAM/CPU (see constants above)
    judge_log "#{rb_sub(@sub)} Testcase: #{rb_testcase(@testcase)} check cmd: " + Rainbow(cmd).color(JudgeBase::COLOR_CHECK_CMD)
    out, err, status = Open3.capture3(cmd, rlimit_as: CHECKER_MEM_LIMIT_BYTES, rlimit_cpu: CHECKER_CPU_LIMIT_SEC)

    result = process_result(@ds.evaluation_type, out, err, status)
    judge_log "#{rb_sub(@sub)} Testcase: #{rb_testcase(@testcase)} check result: "+result_status_with_color(result)
    return result
  end

  # return appropriate evaluator class for the submission
  def self.get_checker(submission)
    # TODO: should return appropriate scorer class
    return self
  end
end
