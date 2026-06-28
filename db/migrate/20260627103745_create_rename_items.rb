class CreateRenameItems < ActiveRecord::Migration[8.1]
  def change
    create_table :rename_items, id: :uuid do |t|
      t.references :rename_batch, null: false, foreign_key: true, type: :uuid
      # Name of the file as stored on disk in work_dir (a UUID).
      t.string :stored_id, null: false
      t.string :original, null: false
      t.string :ext, default: "", null: false

      # Filled in by the rename job.
      t.string :proposed
      # DocumentRenamer::Result status: ok / uncertain / unreadable.
      t.string :status
      t.text :message

      # Pipeline state, drives the per-row badge and the progress bar.
      t.string :state, default: "pending", null: false

      t.timestamps
    end

    add_index :rename_items, %i[rename_batch_id state]
  end
end
