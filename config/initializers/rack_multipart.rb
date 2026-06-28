# Rack caps the number of file parts in a single multipart upload at 128 by
# default (a DoS guard). This tool is 100% local and single-user, and a typical
# PhotoRec recovery batch is hundreds of files in one go, so we raise the limit.
# Without this, uploading >128 files is rejected during multipart parsing — the
# request never reaches the controller and the JS gets an HTML error page
# instead of JSON ("unexpected character at line 1 column 1").
Rack::Utils.multipart_part_limit = 2000
