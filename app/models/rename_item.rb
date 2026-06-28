# One uploaded file within a RenameBatch. The rename job fills in `proposed`,
# `status` and `message`; `state` tracks where it is in the pipeline.
class RenameItem < ApplicationRecord
  belongs_to :rename_batch

  STATES = %w[pending processing done error].freeze

  # Path of the stored upload on disk (under the batch's work_dir).
  def stored_path
    work_dir.join(stored_id)
  end

  # Shape sent to the frontend (status endpoint, download wiring).
  def as_payload
    {
      id: id,
      original: original,
      proposed: proposed,
      status: status,
      message: message,
      state: state
    }
  end

  private

  def work_dir
    Rails.root.join("tmp", "doc_renamer", rename_batch.session_token)
  end
end
