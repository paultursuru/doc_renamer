# Renames a single uploaded file: extract its text, ask the LLM for a name, and
# write the result back to its RenameItem. One job per file means results are
# persisted incrementally (no more all-or-nothing) and a single failure (e.g.
# LM Studio dropping mid-batch) doesn't take the others down.
#
# Runs on the serialized `llm` queue: LM Studio answers in series, so parallel
# jobs wouldn't speed up the model — the win is resilience + visible progress.
class RenameFileJob < ApplicationJob
  queue_as :llm

  # LM Studio temporarily unreachable / too slow: back off and retry rather than
  # failing the file. When retries are exhausted, mark the item as errored so the
  # UI can show it instead of the job vanishing silently.
  retry_on DocumentRenamer::LlmUnavailable, wait: 5.seconds, attempts: 4 do |job, error|
    item = RenameItem.find_by(id: job.arguments.first)
    item&.update(state: "error", status: "unreadable",
                 message: "LM Studio indisponible après plusieurs tentatives : #{error.message}")
  end

  def perform(item_id)
    item = RenameItem.find(item_id)
    item.update!(state: "processing")

    text = DocumentTextExtractor.extract(path: item.stored_path.to_s, original_name: item.original)
    result = DocumentRenamer.new.propose_name(
      original_name: item.original,
      text: text,
      file_path: item.stored_path.to_s
    )

    item.update!(
      proposed: "#{result.name}#{item.ext}",
      status: result.status,
      message: result.message,
      state: "done"
    )
  end
end
