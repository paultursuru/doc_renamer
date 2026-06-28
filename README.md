# 📄 Doc Renamer — rename documents with a local LLM

A small **Rails 8** app that bulk-renames documents using an **LLM running
locally** (via [LM Studio](https://lmstudio.ai)) — **no file ever leaves your
machine**.

- Drag & drop your files (PDF, DOCX, XLSX, DOC, RTF, TXT, images…)
- The model reads a snippet of the content (or **looks at** images and scanned
  PDFs) and proposes a clear `snake_case` name, with an `YYYY-MM-DD` date when
  one can be identified
- Files are processed **in the background** with a **live progress bar** and a
  per-file status — a hiccup on one file never sinks the whole batch
- **Edit** each proposed name before confirming
- Download file by file, or **everything as a single `.zip`**

> Born from a real headache: files recovered with **PhotoRec** after a wiped USB
> stick, hence saddled with unreadable names (`f0012345.jpg`…). This tool gives
> them meaningful names again.

LLM communication goes through the [`ruby_llm`](https://rubyllm.com) gem, pointed
at LM Studio's **OpenAI-compatible** API.

## Requirements

- **Ruby 3.2.4** (see `.ruby-version`)
- **PostgreSQL**, running — used by [GoodJob](https://github.com/bensheldon/good_job)
  for the background jobs
- **LM Studio** installed, with a model loaded (tested with **Gemma 4 E4B**) and
  its local server started: **Developer** tab → **Start Server**
  (defaults to `http://localhost:1234`)
- **Ghostscript** (`gs`) — rasterizes scanned PDFs so the vision model can read
  them (`brew install ghostscript`)
- **`textutil`** (built into macOS) — extracts text from legacy `.doc` and `.rtf`.
  On a non-macOS host these two formats simply fall back to *unreadable*.

> 💡 Images and **scanned PDFs** are renamed through the model's **vision**: it
> looks at the page instead of reading bytes. The loaded model must therefore be
> **multimodal** — **Gemma 4 E4B** is, and works ok on my M1 MacBook from 2020.

## Setup & run

**First time** (with PostgreSQL running):

```bash
bundle install
bin/rails db:prepare   # creates + migrates the Postgres database
```

**Every time** (with **PostgreSQL** and **LM Studio** running):

```bash
bin/rails server
```

Then open http://localhost:3000. The status banner shows in real time whether LM
Studio is reachable and which model is in use.

> **No separate worker to start.** GoodJob runs in `:async` mode, i.e. the jobs
> execute *inside* the Puma process — `bin/rails server` is all you need. A jobs
> dashboard is available at http://localhost:3000/good_job.
>
> `bin/setup` is just a first-run convenience (it runs `bundle` and boots the
> server); it does **not** prepare the database, so run `bin/rails db:prepare`
> once yourself.

## How it works

1. **Chunked upload** — the browser sends files in small batches (25 at a time)
   to `POST /rename`. The first call creates a *batch*; the rest append to it.
   Uploading hundreds of files in one request would otherwise exhaust the
   server's file descriptors. Each file is stored under
   `tmp/doc_renamer/<session>/`.
2. **One job per file** — `POST /rename/:batch_id/start` enqueues a
   `RenameFileJob` per file on a **serialized** GoodJob queue (`llm`, one thread:
   LM Studio answers requests in series, so parallelism wouldn't help and would
   only saturate it).
3. **Naming** — each job turns the file into something the model can read, then
   asks the local LLM for a **structured** answer `{ name, status, message }`:
   - text formats → extract a text excerpt (see *Supported formats*)
   - images & **scanned PDFs with no text layer** → rasterize / pass the image to
     the model's **vision**
4. **Live progress** — each result is saved **as it completes** (no all-or-nothing).
   The UI polls `GET /rename/:batch_id/status` and updates a global progress bar
   plus a per-file badge (*pending / processing / done / error*, and the model's
   `ok / uncertain / unreadable` status). A transient LM Studio failure retries
   that file without touching the others.
5. **Download** — file by file (`GET /download/:id`) with your edited name, or
   everything zipped (`POST /download_all/:batch_id`).

## Configuration (optional)

Everything works with no configuration: if `LMSTUDIO_MODEL` is unset, the app
auto-detects the first (non-embedding) model loaded in LM Studio. Variables can
also be placed in a `.env` file.

| Variable           | Default                    | Purpose                          |
|--------------------|----------------------------|----------------------------------|
| `LMSTUDIO_URL`     | `http://localhost:1234/v1` | LM Studio API URL                |
| `LMSTUDIO_API_KEY` | `lm-studio`                | Key (ignored by LM Studio)       |
| `LMSTUDIO_MODEL`   | *(auto-detected)*          | Model id to use                  |
| `LMSTUDIO_TIMEOUT` | `180`                      | LLM request timeout (s)          |

Database connection follows the usual Rails conventions (`config/database.yml`),
overridable via `DATABASE_HOST` / `DATABASE_USERNAME` / `DATABASE_PASSWORD`.

Example:

```bash
LMSTUDIO_MODEL="google/gemma-4-e4b" bin/rails server
```

## Supported formats

The excerpt fed to the model is capped at ~1,500 characters — plenty to name a
document, and small enough to keep a local model fast.

- **Text extracted from content**: `.pdf` (text layer), `.docx`, `.xlsx`,
  `.xls`, `.doc`, `.rtf`, `.txt`, `.md`, `.csv`, `.tsv`, `.json`, `.xml`,
  `.html`, `.log`, `.yml`…
- **Vision (the model looks at the image)**: `.png`, `.jpg`, `.jpeg`, `.webp`,
  `.gif`, `.bmp`, `.heic`, `.tiff`, **and scanned PDFs** (no text layer → first
  page rasterized with Ghostscript)
- **Unknown / no usable content**: never sent as raw binary; reported as
  *unreadable* and kept under its original name

> `.doc` / `.rtf` use macOS `textutil`; `.xls` uses the `spreadsheet` gem;
> `.xlsx` / `.docx` are read straight from their zip — no external tool.

## Privacy

Uploaded files are stored **temporarily** in `tmp/doc_renamer/<session>/` and are
**never sent over the network** — only a **text excerpt** (or the image, for the
vision path) is passed to the **local** LLM.

## Limitations

- **Speed** — LM Studio serves requests in series, so a large batch is processed
  one file at a time. That's by design; the win here is resilience and a visible
  progress bar, not raw throughput.
- **`.doc` / `.rtf` are macOS-only** (they rely on `textutil`); other binary
  legacy formats keep their original name.
- **No vision, no image naming** — if the loaded model isn't multimodal, images
  and scanned PDFs keep their original name.

## Architecture

| File | Role |
|------|------|
| `config/initializers/ruby_llm.rb`         | Wires RubyLLM to LM Studio |
| `config/initializers/good_job.rb`         | Background jobs: async mode, serialized `llm` queue |
| `app/services/lm_studio.rb`               | Server / model detection |
| `app/services/document_text_extractor.rb` | Extracts text (pdf, docx, xlsx, xls, doc, rtf, plain) |
| `app/services/pdf_rasterizer.rb`          | First page of a scanned PDF → PNG (Ghostscript) |
| `app/services/document_renamer.rb`        | Prompt + structured result; text & vision paths |
| `app/services/schema/filename_schema.rb`  | Structured output schema (`name` / `status` / `message`) |
| `app/models/rename_batch.rb` · `rename_item.rb` | A batch and its per-file state/result |
| `app/jobs/rename_file_job.rb`             | Renames one file (extract/vision + LLM) |
| `app/jobs/rename_report_job.rb`           | Batch `on_finish` callback (marks it finished) |
| `app/controllers/documents_controller.rb` | Chunked upload, start, status, download, zip |
| `app/javascript/controllers/renamer_controller.js` | UI: drop zone, chunked upload, polling, progress |
| `app/javascript/controllers/lm_status_controller.js` | Polls LM Studio status |

Main routes: `GET /` (UI), `POST /rename`, `POST /rename/:batch_id/start`,
`GET /rename/:batch_id/status`, `GET /status`, `GET /download/:id`,
`POST /download_all/:batch_id`, `GET /good_job` (jobs dashboard).

## The prompt

Deliberately simple (see `DocumentRenamer::SYSTEM_PROMPT`): it asks for a short,
descriptive `snake_case` name, no extension, max 8 words, with an `YYYY-MM-DD`
date if one is identifiable. Tweak it freely.
