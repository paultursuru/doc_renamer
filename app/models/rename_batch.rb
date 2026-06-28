# A set of files uploaded together and renamed by background jobs. Progress and
# results are read back from its items (see RenameItem) for the UI's progress bar.
class RenameBatch < ApplicationRecord
  has_many :items, class_name: "RenameItem", dependent: :destroy

  # { done:, total:, finished: } — drives the global progress bar.
  def progress
    counts = items.group(:state).count
    total = counts.values.sum
    done = total - counts.fetch("pending", 0) - counts.fetch("processing", 0)
    { done: done, total: total, finished: finished_at.present? }
  end
end
