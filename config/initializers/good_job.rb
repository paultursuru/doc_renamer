# GoodJob runs in-process (inside Puma) — fine for this local, single-user app.
# A separate worker process (:external) would be the switch for a future server
# deployment; see the project notes.
Rails.application.configure do
  config.good_job.execution_mode = :async

  # LM Studio serves LLM requests in series, so the `llm` queue gets a single
  # thread: running renames in parallel wouldn't speed up the model and would
  # only saturate it. The goal here is resilience + progress, not throughput.
  # Everything else shares a small pool.
  config.good_job.queues = "llm:1;*:3"
  config.good_job.max_threads = 4
  config.good_job.poll_interval = 1

  # A failing rename (e.g. LM Studio down mid-batch) is retried rather than
  # killing the whole batch.
  config.good_job.retry_on_unhandled_error = false
  config.good_job.on_thread_error = ->(e) { Rails.logger.error(e) }
end
