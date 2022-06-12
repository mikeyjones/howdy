//// Helper methods for handling the request header
//// from the Context

import gleam/http/request
import howdy/context.{Context}

/// Finds the value from the request header using 
/// the Context
pub fn get_value(context: Context(a), key: String) {
  request.get_header(context.request, key)
}
