-module(howdy_auth_sso_ffi).
-export([valid_certificate/1, public_host/1]).

%% Exactly one unencrypted X.509 certificate that OTP can decode. Nothing about
%% its chain or dates is judged: a SAML signing certificate is pinned, not
%% validated against an authority, and providers routinely self-sign them.
valid_certificate(Pem) when byte_size(Pem) =< 16384 ->
    try
        [{'Certificate', Der, not_encrypted}] = public_key:pem_decode(Pem),
        _ = public_key:pkix_decode_cert(Der, otp),
        true
    catch _:_ -> false end;
valid_certificate(_) -> false.

%% True when Host resolves, and only to addresses on the public internet. A
%% customer-supplied URL must not reach loopback, private networks, link-local
%% metadata services or the like. This is a filter ahead of the request, not a
%% pinned connection: it does not stop a name that re-resolves differently, so
%% connection configuration stays a privileged operation.
public_host(Host) when byte_size(Host) > 0, byte_size(Host) =< 253 ->
    try
        Name = binary_to_list(Host),
        V4 = addresses(Name, inet),
        V6 = addresses(Name, inet6),
        Found = V4 ++ V6,
        Found =/= [] andalso lists:all(fun public/1, Found)
    catch _:_ -> false end;
public_host(_) -> false.

addresses(Name, Family) ->
    case inet:getaddrs(Name, Family) of
        {ok, Found} -> Found;
        {error, _} -> []
    end.

public({0, _, _, _}) -> false;
public({10, _, _, _}) -> false;
public({100, B, _, _}) when B >= 64, B =< 127 -> false;
public({127, _, _, _}) -> false;
public({169, 254, _, _}) -> false;
public({172, B, _, _}) when B >= 16, B =< 31 -> false;
public({192, 0, 0, _}) -> false;
public({192, 0, 2, _}) -> false;
public({192, 168, _, _}) -> false;
public({198, B, _, _}) when B =:= 18; B =:= 19 -> false;
public({198, 51, 100, _}) -> false;
public({203, 0, 113, _}) -> false;
public({A, _, _, _}) when A >= 224 -> false;
public({_, _, _, _}) -> true;
%% IPv4-mapped and NAT64 addresses are judged as the IPv4 address they carry.
public({0, 0, 0, 0, 0, 16#ffff, C, D}) -> public(embedded(C, D));
public({16#64, 16#ff9b, 0, 0, 0, 0, C, D}) -> public(embedded(C, D));
%% Otherwise only global unicast, 2000::/3, less the documentation prefix.
public({16#2001, 16#db8, _, _, _, _, _, _}) -> false;
public({A, _, _, _, _, _, _, _}) when A >= 16#2000, A =< 16#3fff -> true;
public(_) -> false.

embedded(C, D) -> {C bsr 8, C band 255, D bsr 8, D band 255}.
