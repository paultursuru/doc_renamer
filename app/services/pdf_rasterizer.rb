require "securerandom"

# Renders the first page of a PDF to a PNG so a scanned / image-only PDF (no text
# layer) can be named by the vision model. Used as a fallback when text
# extraction yields nothing. Shells out to Ghostscript (kept local, no gem).
module PdfRasterizer
  module_function

  # 150 dpi is enough for the model to read a page while staying light/fast.
  DPI = 150

  # Returns the path to a temporary PNG of the first page, or nil if rendering
  # fails (Ghostscript missing, corrupt PDF, ...). The caller owns the temp file
  # and must delete it.
  def first_page_png(pdf_path)
    out = Rails.root.join("tmp", "doc_renamer", "raster_#{SecureRandom.hex(8)}.png").to_s

    ok = system(
      "gs", "-q", "-dNOPAUSE", "-dBATCH", "-dSAFER",
      "-sDEVICE=png16m", "-dFirstPage=1", "-dLastPage=1", "-r#{DPI}",
      "-sOutputFile=#{out}", pdf_path,
      out: File::NULL, err: File::NULL
    )

    ok && File.exist?(out) && File.size(out).positive? ? out : nil
  rescue StandardError
    nil
  end
end
