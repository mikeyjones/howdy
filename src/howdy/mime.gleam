/// Uses mimerl to file mime based on the file extention
pub external fn from_path(path: String) -> String =
  "mimerl" "filename"

/// Uses mimerl to find the mime type based on the file extention
pub external fn from_extention(extention: String) -> String =
  "mimerl" "extension"

/// Uses mimerl to find all the file extentions based on the mime type 
pub external fn from_mime(mime: String) -> List(String) =
  "mimerl" "mime_to_exts"
