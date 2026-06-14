class Testcase < ApplicationRecord
  include Auditable
  audited only:   %i[num group group_name code_name weight
                     dataset_id problem_id input sol],
          redact: %i[input sol]

  belongs_to :problem, optional: true
  belongs_to :dataset

  has_many :evaluations
  # attr_accessible :group, :input, :num, :score, :sol

  has_one_attached :inp_file
  has_one_attached :ans_file

  scope :display_order, ->  { order(:group, :num) }

  def get_name_for_dir
    return code_name unless code_name.blank?
    return num.to_s
  end

  # we should rename score field into weight
  def get_weight
    return score
  end

  def self.set_testcase_num(testcase, number)
    dataset = testcase.dataset
    num = 1
    AuditLog.paused do
      dataset.testcases.where.not(id: testcase.id).order(:group, :num, :id).each do |tc|
        offset = (num >= number) ? 1 : 0
        tc.update(num: num + offset)
        num += 1
      end
      testcase.update(num: [dataset.testcases.count, [1, number.round].max].min)
    end
  end
end
