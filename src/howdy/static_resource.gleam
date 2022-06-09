//// Helper functions to handle static content on the disk

import gleam/erlang/file.{is_file, read_bits}
import gleam/http/response.{Response}
import gleam/bit_builder.{BitBuilder}
import gleam/list
import gleam/string
import howdy/context.{Context}
import howdy/response
import howdy/url_parser.{UrlSegment, WildcardSegment}
import howdy/mime

///Searchs the file path for matching files from a wildcard segment
pub fn get_file_contents(file_path: String) {
  fn(context: Context) -> Response(BitBuilder) {
    let full_path_result = get_wildcard_segment_url(context.url, file_path)
    case full_path_result {
      Ok(full_path) ->
        case is_file(full_path) {
          True ->
            case read_bits(full_path) {
              Ok(file_contents) ->
                response.of_bit_string(file_contents)
                |> response.with_content_type(mime.from_path(full_path))
              Error(_error) -> response.of_interal_error("Fatal error")
            }
          False -> response.of_not_found("File not found")
        }
      Error(_) -> response.of_not_found("File not found")
    }
  }
}

/// Matches a single file to a route, allowing the server
/// to serve Single Page Applications 
pub fn get_spa_file_contents(file_path: String) {
  fn(_context: Context) -> Response(BitBuilder) {
    case is_file(file_path) {
      True ->
        case read_bits(file_path) {
          Ok(file_contents) ->
            response.of_bit_string(file_contents)
            |> response.with_content_type(mime.from_path(file_path))
          Error(_error) -> response.of_interal_error("Fatal error")
        }
      False -> response.of_not_found("File not found")
    }
  }
}

fn get_wildcard_segment_url(segments: List(UrlSegment), root: String) {
  try segment = list.last(segments)

  case segment {
    WildcardSegment(_, _, url) -> Ok(join_paths(root, url))
    _ -> Error(Nil)
  }
}

fn join_paths(root: String, path: String) {
  let modified_path = string.replace(path, "\\", "/")
  case string.ends_with(root, "/"), string.starts_with(modified_path, "/") {
    True, True -> string.concat([root, string.drop_left(modified_path, 1)])
    False, False -> string.concat([root, "/", modified_path])
    _, _ -> string.concat([root, modified_path])
  }
}
// fn get_string_reason(reason: file.Reason) -> String {
//   case reason {
//     file.Eacces -> "Permission denied"
//     file.Eagain -> "Resource temorarily unavailiable"
//     file.Ebadf -> "Bad file number"
//     file.Ebadmsg -> "Bad message"
//     file.Ebusy -> "File busy"
//     file.Edeadlk -> "Resource deadlock avoided."
//     file.Edeadlock -> "File locking deadlock error."
//     file.Edquot -> "Disk quota exceeded."
//     file.Eexist -> "File already exists."
//     file.Efault -> "Bad address in system call argument."
//     file.Efbig -> "File too large."
//     file.Eftype -> "Inappropriate file type or format."
//     file.Eintr -> "Interruted system call."
//     file.Einval -> "Invalid argument."
//     file.Eio -> "I/O error."
//     file.Eisdir -> "Illegal operation on a directory."
//     file.Eloop -> "Too many levels of symbolic links."
//     file.Emfile -> "Too many open files."
//     //   /// Too many links.
//     //   Emlink
//     //   /// Multihop attempted.
//     //   Emultihop
//     //   /// Filename too long
//     //   Enametoolong
//     //   /// File table overflow
//     //   Enfile
//     //   /// No buffer space available.
//     //   Enobufs
//     //   /// No such device.
//     //   Enodev
//     //   /// No locks available.
//     //   Enolck
//     //   /// Link has been severed.
//     //   Enolink
//     //   /// No such file or directory.
//     //   Enoent
//     //   /// Not enough memory.
//     //   Enomem
//     //   /// No space left on device.
//     //   Enospc
//     //   /// No STREAM resources.
//     //   Enosr
//     //   /// Not a STREAM.
//     //   Enostr
//     //   /// Function not implemented.
//     //   Enosys
//     //   /// Block device required.
//     //   Enotblk
//     //   /// Not a directory.
//     //   Enotdir
//     //   /// Operation not supported.
//     //   Enotsup
//     //   /// No such device or address.
//     //   Enxio
//     //   /// Operation not supported on socket.
//     //   Eopnotsupp
//     //   /// Value too large to be stored in data type.
//     //   Eoverflow
//     //   /// Not owner.
//     //   Eperm
//     //   /// Broken pipe.
//     //   Epipe
//     //   /// Result too large.
//     //   Erange
//     //   /// Read-only file system.
//     //   Erofs
//     //   /// Invalid seek.
//     //   Espipe
//     //   /// No such process.
//     //   Esrch
//     //   /// Stale remote file handle.
//     //   Estale
//     //   /// Text file busy.
//     //   Etxtbsy
//     //   /// Cross-domain link.
//     //   Exdev
//     file.Eperm -> "Not owner"
//     file.NotUtf8 -> "Not a UTF-8 file"
//     _ -> "Unknown"
//   }
// }
