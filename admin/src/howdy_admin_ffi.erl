-module(howdy_admin_ffi).
-export([cells/1]).

%% A database row as it came from the driver, as a list of optional strings.
%% pog rows are tuples and sqlight rows are lists; every value becomes text
%% so the admin can show any column without knowing its type.
cells(Row) when is_tuple(Row) -> cells(tuple_to_list(Row));
cells(Row) when is_list(Row) -> [cell(V) || V <- Row];
cells(Other) -> [cell(Other)].

cell(nil) -> none;
cell(null) -> none;
cell(undefined) -> none;
cell(true) -> {some, <<"true">>};
cell(false) -> {some, <<"false">>};
cell(V) when is_binary(V) -> {some, text(V)};
cell(V) when is_integer(V) -> {some, integer_to_binary(V)};
cell(V) when is_float(V) -> {some, float_to_binary(V, [short])};
cell(V) when is_atom(V) -> {some, atom_to_binary(V, utf8)};
cell({{Y, Mo, D}, {H, Mi, S}})
  when is_integer(Y), is_integer(Mo), is_integer(D),
       is_integer(H), is_integer(Mi) ->
    {some, iolist_to_binary([date(Y, Mo, D), " ", pad(H), ":", pad(Mi), ":", seconds(S)])};
cell({Y, Mo, D}) when is_integer(Y), is_integer(Mo), is_integer(D) ->
    {some, iolist_to_binary(date(Y, Mo, D))};
cell(V) ->
    {some, unicode:characters_to_binary(io_lib:format("~p", [V]))}.

text(B) ->
    case unicode:characters_to_binary(B, utf8, utf8) of
        B when byte_size(B) =/= 16 -> B;
        B -> maybe_uuid(B);
        _ when byte_size(B) =:= 16 -> uuid(B);
        _ -> <<"\\x", (binary:encode_hex(B))/binary>>
    end.

%% Sixteen valid UTF-8 bytes are almost always text, but a random UUID can
%% happen to be valid too; only treat it as a UUID when it is not printable.
maybe_uuid(B) ->
    case io_lib:printable_unicode_list(unicode:characters_to_list(B)) of
        true -> B;
        false -> uuid(B)
    end.

uuid(<<A:32, B:16, C:16, D:16, E:48>>) ->
    iolist_to_binary(io_lib:format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [A, B, C, D, E])).

date(Y, Mo, D) -> [io_lib:format("~4..0b", [Y]), "-", pad(Mo), "-", pad(D)].

pad(N) -> io_lib:format("~2..0b", [N]).

seconds(S) when is_integer(S) -> pad(S);
seconds(S) when is_float(S) -> io_lib:format("~6.3.0f", [S]);
seconds(S) -> io_lib:format("~p", [S]).
