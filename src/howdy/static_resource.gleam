//// Helper functions to handle static content on the disk

import gleam/erlang/file.{is_file, read_bits}
import gleam/http/response
import gleam/list
import gleam/string
import gleam/result
import gleam/function.{compose}
import howdy/context.{Context}
import howdy/response
import howdy/url_parser.{UrlSegment, WildcardSegment}
import howdy/mime

type Error {
  FileNotFound
  WildcardPathNotFound
  InternalError
}

type FileInfo {
  FileInfo(content_type: String, content: BitString)
}

///Searchs the file path for matching files from a wildcard segment
pub fn get_file_contents(file_path: String) {
  compose(
    fn(context: Context(a)) -> Result(FileInfo, Error) {
      try full_path_result = get_wildcard_segment_url(context.url, file_path)
      read_file(full_path_result)
    },
    result_to_response,
  )
}

/// Matches a single file to a route, allowing the server
/// to serve Single Page Applications 
pub fn get_spa_file_contents(file_path: String, default_file: String) {
  compose(
    fn(context: Context(a)) -> Result(FileInfo, Error) {
      case get_wildcard_segment_url(context.url, file_path) {
        Ok(full_path_result) ->
          case read_file(full_path_result) {
            Ok(file) -> Ok(file)
            Error(_) -> read_file(default_file)
          }
        Error(_) -> read_file(default_file)
      }
    },
    result_to_response,
  )
}

fn read_file(file_path: String) {
  case is_file(file_path) {
    True ->
      read_bits(file_path)
      |> result.map(fn(content) { FileInfo(mime.from_path(file_path), content) })
      |> result.replace_error(InternalError)
    False -> Error(FileNotFound)
  }
}

fn file_response(file_contents: BitString, content_type: String) {
  response.of_bit_string(file_contents)
  |> response.with_content_type(content_type)
}

fn get_wildcard_segment_url(segments: List(UrlSegment), root: String) {
  try segment =
    list.last(segments)
    |> result.replace_error(WildcardPathNotFound)

  case segment {
    WildcardSegment(_, _, url) -> Ok(join_paths(root, url))
    _ -> Error(WildcardPathNotFound)
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

fn result_to_response(result: Result(FileInfo, Error)) {
  case result {
    Ok(file_info) -> file_response(file_info.content, file_info.content_type)
    Error(error) -> error_response(error)
  }
}

fn error_response(error: Error) {
  case error {
    FileNotFound -> response.of_not_found("File not found init")
    WildcardPathNotFound | InternalError ->
      response.of_internal_error("Error finding content")
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
