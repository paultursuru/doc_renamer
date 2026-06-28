class CreateRenameBatches < ActiveRecord::Migration[8.1]
  def change
    create_table :rename_batches, id: :uuid do |t|
      # Scopes a batch to a browser session (same token as the on-disk work_dir).
      t.string :session_token, null: false
      # GoodJob::Batch id, so the report callback can find this batch back.
      t.uuid :good_job_batch_id
      # Set by the report job once every file has been processed.
      t.datetime :finished_at

      t.timestamps
    end

    add_index :rename_batches, :session_token
    add_index :rename_batches, :good_job_batch_id, unique: true
  end
end
