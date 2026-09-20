//// Built-in external identity providers. Configure with a constructor from
//// `howdy/auth/providers`, then install using `auth.with_provider`.

import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri
import howdy/auth/secret
import howdy/service

pub opaque type Provider {
  Provider(
    id: String,
    name: String,
    valid: service.Result(Nil),
    authorize: fn(Authorization) -> String,
    verify: fn(Exchange) -> service.Result(Identity),
  )
}

@internal
pub type Authorization {
  Authorization(
    redirect_uri: String,
    state: String,
    nonce: String,
    challenge: String,
  )
}

@internal
pub type Exchange {
  Exchange(
    code: secret.Secret,
    redirect_uri: String,
    verifier: secret.Secret,
    nonce_digest: String,
  )
}

/// Verified by the provider, before local account policy is applied.
@internal
pub type Identity {
  Identity(
    issuer: String,
    subject: String,
    email: String,
    email_authoritative: Bool,
    hosted_domain: Option(String),
  )
}

@internal
pub fn new(
  id: String,
  name: String,
  valid: service.Result(Nil),
  authorize: fn(Authorization) -> String,
  verify: fn(Exchange) -> service.Result(Identity),
) -> Provider {
  Provider(id, name, valid, authorize, verify)
}

pub fn id(provider: Provider) -> String {
  provider.id
}

pub fn name(provider: Provider) -> String {
  provider.name
}

@internal
pub fn validate(provider: Provider) -> service.Result(Nil) {
  provider.valid
}

@internal
pub fn authorization_url(provider: Provider, request: Authorization) -> String {
  provider.authorize(request)
}

@internal
pub fn exchange(
  provider: Provider,
  request: Exchange,
) -> service.Result(Identity) {
  provider.verify(request)
}

@internal
pub fn require_domain(provider: Provider, domain: String) -> Provider {
  let valid = case
    domain != "" && string.contains(domain, ".") && list_domain(domain)
  {
    True -> provider.valid
    False -> Error(service.Invalid("invalid Google hosted domain"))
  }
  Provider(
    ..provider,
    valid:,
    authorize: fn(request) {
      provider.authorize(request) <> "&hd=" <> uri.percent_encode(domain)
    },
    verify: fn(request) {
      use identity <- result.try(provider.verify(request))
      case identity.hosted_domain {
        Some(found) if found == domain -> Ok(identity)
        Some(_) | None -> Error(service.Forbidden)
      }
    },
  )
}

fn list_domain(domain: String) -> Bool {
  case domain {
    "" -> True
    _ -> {
      let assert Ok(#(first, rest)) = string.pop_grapheme(domain)
      string.contains("abcdefghijklmnopqrstuvwxyz0123456789.-", first)
      && list_domain(rest)
    }
  }
}
