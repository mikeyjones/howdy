-module(howdy_openapi_ffi).
-export([identity/1]).

%% Routes carry annotations as Dynamic. howdy/openapi/endpoint stores its own
%% record under its own key and reads it back, so the round trip is safe.
identity(Value) -> Value.
