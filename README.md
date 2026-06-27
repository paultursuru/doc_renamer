# 📄 Doc Renamer — rename documents with a local LLM

A small **Rails 8** app that bulk-renames documents using an **LLM running
locally** (via [LM Studio](https://lmstudio.ai)) — **no file ever leaves your
machine**.

- Drag & drop your files (PDF, DOCX, TXT, MD, CSV, images…)
- The model reads a snippet of the content (or "looks at" images) and proposes a
  clear `snake_case` name, with an `YYYY-MM-DD` date when one can be identified
- **Edit** each proposed name before confirming
- Download file by file, or **everything as a single `.zip`**

> Born from a real headache: files recovered with **PhotoRec** after a wiped USB
> stick, hence saddled with unreadable names (`f0012345.jpg`…). This tool gives
> them meaningful names again.

LLM communication goes through the [`ruby_llm`](https://rubyllm.com) gem, pointed
at LM Studio's **OpenAI-compatible** API.

## Requirements

- **Ruby 3.2.4** (see `.ruby-version`)
- **LM Studio** installed, with a model loaded (tested with **Gemma 4 E4B**)
- LM Studio's local server started: **Developer** tab → **Start Server**
  (defaults to `http://localhost:1234`)

> 💡 To rename **images**, the loaded model must be **multimodal (vision)**.
> Otherwise images keep their original name (see *Known limitations*).

## Install & run

```bash
cd doc_renamer
bin/setup          # bundle install + setup
bin/rails server
```

Then open http://localhost:3000.

The status banner at the top shows in real time whether LM Studio is reachable
and which model is in use.

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

Example:

```bash
LMSTUDIO_MODEL="google/gemma-4-e4b" bin/rails server
```

## Supported formats

- **Text extracted from content**: `.pdf`, `.docx`, `.txt`, `.md`, `.csv`,
  `.tsv`, `.json`, `.xml`, `.html`, `.log`, `.yml`… (excerpt capped at ~4,000
  characters)
- **Images (vision)**: `.png`, `.jpg`, `.jpeg`, `.webp`, `.gif`, `.bmp`, `.heic`,
  `.tiff` — the model observes the image instead of reading its bytes
- **Unknown**: best-effort read, but raw binary is never sent to the LLM

## Privacy

Uploaded files are stored **temporarily** in `tmp/doc_renamer/<session>/` and are
**never sent over the network** — only a **text excerpt** (or the image, for the
vision path) is passed to the **local** LLM.

## Known limitations

- **Synchronous processing**: all files are sent in a single request and
  processed serially (one LLM call per file). On a large batch this is slow and
  there is no progress bar in the UI yet; if LM Studio drops mid-run, the whole
  batch fails with no partial results.
- **Files with no usable content** (unreadable binaries, or images when the model
  has no vision): **keep their original name** instead of being renamed.

*(Improvements are planned: async jobs + progress, structured LLM responses, etc.)*

## Architecture

| File | Role |
|------|------|
| `config/initializers/ruby_llm.rb`         | Wires RubyLLM to LM Studio |
| `app/services/lm_studio.rb`               | Server / model detection |
| `app/services/document_text_extractor.rb` | Extracts text (PDF, DOCX, plain text) |
| `app/services/document_renamer.rb`        | Prompt + cleanup of the proposed name |
| `app/controllers/documents_controller.rb` | Upload, rename, download, zip |
| `app/views/documents/index.html.erb`      | UI (drop zone + JS) |

Main routes: `GET /` (UI), `POST /rename`, `GET /status`, `GET /download/:id`,
`POST /download_all`.

## The prompt

Deliberately simple (see `DocumentRenamer::SYSTEM_PROMPT`): it asks for a short,
descriptive `snake_case` name, no extension, max 8 words, with an `YYYY-MM-DD`
date if one is identifiable. Tweak it freely.
