# Batch `on_finish` callback: runs once every RenameFileJob in the batch has
# finished (succeeded, errored or been discarded). Marks the RenameBatch as
# finished so the UI can stop polling and reveal the "download all" action.
class RenameReportJob < ApplicationJob
  def perform(batch, _options = {})
    rename_batch = RenameBatch.find_by(id: batch.properties[:rename_batch_id])
    rename_batch&.update(finished_at: Time.current)
  end
end
