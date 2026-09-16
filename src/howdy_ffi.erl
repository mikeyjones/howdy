-module(howdy_ffi).
-export([fixed_window_new/1, token_bucket_new/2, fixed_window_hit/4,
         token_bucket_hit/6, token_bucket_check/5, now_ms/0]).
-export([fixed_window_cleanup/2, token_bucket_cleanup/4]).
-export([channel_join/2, channel_leave/2, channel_members/1, channel_broadcast/3, tuple_second/1]).
-export([parse_query/1]).

%% -- Query strings ---------------------------------------------------------------
%%
%% One pass over the query string, no library calls: `&` separates pairs, the
%% first `=` separates key from value, `+` is a space and `%XY` a byte. A `%`
%% with fewer than two bytes after it in the same part is literal; with two
%% that are not both hex it is an error, as is anything that is not UTF-8
%% once decoded. A
%% pair without `=` has an empty value. Results match gleam/uri.parse_query
%% (OTP's uri_string:dissect_query), which the test suite fuzzes against,
%% with one deliberate difference: `&#` is literal here. OTP treats it as an
%% HTML numeric character reference, decoding `&#65;` to `A` in some
%% positions and crashing on `&#` at the end of the string.
-define(IS_HEX(C), ((C >= $0 andalso C =< $9) orelse (C >= $a andalso C =< $f) orelse (C >= $A andalso C =< $F))).

parse_query(<<>>) ->
    {ok, []};
parse_query(Query) ->
    try
        {ok, query_key(Query, <<>>, false, [])}
    catch throw:invalid_query ->
        {error, nil}
    end.

%% Escaped tracks whether a percent-escape was decoded into the current
%% part; only then can the bytes be invalid UTF-8, since raw characters are
%% matched as UTF-8 as they are consumed.
query_key(<<$&, Rest/binary>>, Key, Escaped, Acc) ->
    query_key(Rest, <<>>, false, [{query_part(Key, Escaped), <<>>} | Acc]);
query_key(<<$=, Rest/binary>>, Key, Escaped, Acc) ->
    query_value(Rest, query_part(Key, Escaped), <<>>, false, Acc);
query_key(<<>>, Key, Escaped, Acc) ->
    lists:reverse([{query_part(Key, Escaped), <<>>} | Acc]);
query_key(<<$+, Rest/binary>>, Key, Escaped, Acc) ->
    query_key(Rest, <<Key/binary, $\s>>, Escaped, Acc);
query_key(<<$%, H, L, Rest/binary>>, Key, _Escaped, Acc) when ?IS_HEX(H), ?IS_HEX(L) ->
    query_key(Rest, <<Key/binary, (hex(H) * 16 + hex(L))>>, true, Acc);
query_key(<<$%, H, L, _/binary>>, _Key, _Escaped, _Acc)
        when H =/= $&, H =/= $=, L =/= $&, L =/= $= ->
    throw(invalid_query);
query_key(<<C/utf8, Rest/binary>>, Key, Escaped, Acc) ->
    query_key(Rest, <<Key/binary, C/utf8>>, Escaped, Acc);
query_key(_, _Key, _Escaped, _Acc) ->
    throw(invalid_query).

query_value(<<$&, Rest/binary>>, Key, Value, Escaped, Acc) ->
    query_key(Rest, <<>>, false, [{Key, query_part(Value, Escaped)} | Acc]);
query_value(<<>>, Key, Value, Escaped, Acc) ->
    lists:reverse([{Key, query_part(Value, Escaped)} | Acc]);
query_value(<<$+, Rest/binary>>, Key, Value, Escaped, Acc) ->
    query_value(Rest, Key, <<Value/binary, $\s>>, Escaped, Acc);
query_value(<<$%, H, L, Rest/binary>>, Key, Value, _Escaped, Acc) when ?IS_HEX(H), ?IS_HEX(L) ->
    query_value(Rest, Key, <<Value/binary, (hex(H) * 16 + hex(L))>>, true, Acc);
query_value(<<$%, H, L, _/binary>>, _Key, _Value, _Escaped, _Acc)
        when H =/= $&, L =/= $& ->
    throw(invalid_query);
query_value(<<C/utf8, Rest/binary>>, Key, Value, Escaped, Acc) ->
    query_value(Rest, Key, <<Value/binary, C/utf8>>, Escaped, Acc);
query_value(_, _Key, _Value, _Escaped, _Acc) ->
    throw(invalid_query).

query_part(Part, false) ->
    Part;
query_part(Part, true) ->
    case unicode:characters_to_binary(Part) of
        Part -> Part;
        _ -> throw(invalid_query)
    end.

hex(C) when C >= $0, C =< $9 -> C - $0;
hex(C) when C >= $a, C =< $f -> C - $a + 10;
hex(C) when C >= $A, C =< $F -> C - $A + 10.


%% Tables remain owned by the constructor's caller. A linked janitor monitors
%% that owner (including normal exits), so neither table nor timer outlives it.
%% Only the janitor scans; requests never send cleanup messages or scan ETS.
%% Constructors return {Table, SweepIntervalMs}.
fixed_window_new(WindowMs) ->
    new_limiter(min(60000, WindowMs), {fixed_window, WindowMs}).

token_bucket_new(CapacityMilli, RatePerSecond) ->
    IdleMs = max(1000, (CapacityMilli + RatePerSecond - 1) div RatePerSecond),
    new_limiter(min(60000, IdleMs), {token_bucket, CapacityMilli, RatePerSecond}).

new_limiter(Interval, Policy) ->
    Table = ets:new(howdy_rate_limit, [set, public, {write_concurrency, true}]),
    Owner = self(),
    spawn_link(fun() ->
        Ref = monitor(process, Owner),
        cleanup_loop(Table, Ref, Interval, Policy)
    end),
    {Table, Interval}.

cleanup_loop(Table, Ref, Interval, Policy) ->
    receive
        {'DOWN', Ref, process, _, _} -> ok
    after Interval ->
        %% The owner's table can disappear before its DOWN arrives.
        Status = try
            Now = now_ms(),
            case Policy of
                {fixed_window, WindowMs} ->
                    fixed_window_cleanup(Table, floor_div(Now, WindowMs));
                {token_bucket, CapacityMilli, RatePerSecond} ->
                    token_bucket_cleanup(Table, CapacityMilli, RatePerSecond, Now)
            end,
            alive
        catch error:badarg ->
            case ets:info(Table) of
                undefined -> gone;
                _ -> error(badarg)
            end
        end,
        case Status of
            alive -> cleanup_loop(Table, Ref, Interval, Policy);
            gone -> ok
        end
    end.

floor_div(A, B) ->
    case A rem B < 0 of true -> A div B - 1; false -> A div B end.

now_ms() ->
    erlang:monotonic_time(millisecond).

%% Atomic per-row deletion cannot discard a concurrently refreshed bucket.
%% Sweeps return how many rows they removed and give those slots back.
fixed_window_cleanup(Table, Window) ->
    Deleted = ets:select_delete(Table, [{{{'_', '$1'}, '_'}, [{'<', '$1', Window}], [true]}]),
    release(Table, Deleted),
    Deleted.

%% A bucket whose refill has reached capacity is indistinguishable from an
%% absent row, so evicting it loses nothing. This subsumes idle eviction: a
%% bucket untouched for a full refill interval is always at capacity. Depleted
%% or partially refilled buckets are never evicted.
token_bucket_cleanup(Table, CapacityMilli, RatePerSecond, NowMs) ->
    Refilled = {'+', '$1', {'*', {'-', NowMs, '$2'}, RatePerSecond}},
    Deleted = ets:select_delete(Table, [{{'_', '$1', '$2'}, [{'>=', Refilled, CapacityMilli}], [true]}]),
    release(Table, Deleted),
    Deleted.

%% -- Admission -----------------------------------------------------------------
%%
%% A limiter holds at most MaxIdentities rows (unbounded when it is the atom
%% `infinity`). The count lives in the table under ?COUNT, a key no cleanup
%% pattern matches. A new row first reserves a slot with one atomic counter
%% update and only then inserts; the slot is given back if the insert loses
%% to a concurrent one, and sweeps give back what they delete. Rows therefore
%% never exceed the cap, even under concurrent first hits. The only effect of
%% contention is that a hit for a new key may be refused while another new
%% key's insert is in flight at the cap.
%% Hits on an existing row never consult the counter, so depleted buckets and
%% open windows keep limiting while the table is full.
%%
%% Keys longer than 64 bytes are replaced by their SHA-256 so row size is
%% bounded regardless of what a client puts in an identifying header.
%% Functions return {admitted, Value} or refused.
-define(COUNT, '$howdy_identities').
-define(MAX_KEY_BYTES, 64).

key(Key) when byte_size(Key) > ?MAX_KEY_BYTES -> crypto:hash(sha256, Key);
key(Key) -> Key.

reserve(_Table, infinity) ->
    true;
reserve(Table, Max) ->
    case ets:update_counter(Table, ?COUNT, {2, 1}, {?COUNT, 0}) > Max of
        true -> release(Table, 1), false;
        false -> true
    end.

%% Never below zero, and never creates the counter: an unbounded table has none.
release(_Table, 0) ->
    ok;
release(Table, N) ->
    try ets:update_counter(Table, ?COUNT, {2, -N, 0, 0}) of
        _ -> ok
    catch error:badarg ->
        case ets:member(Table, ?COUNT) of
            false -> ok;
            true -> error(badarg)
        end
    end.

%% Atomically count a hit. Expired windows are reclaimed by the janitor even
%% if no further requests arrive. Membership is checked first: raising and
%% catching badarg from update_counter costs time that grows with table size,
%% so the exception is left for the rare case of a sweep removing the row
%% between the check and the update.
fixed_window_hit(Table, Key, Window, MaxIdentities) ->
    Row = {key(Key), Window},
    case ets:member(Table, Row) of
        true ->
            try ets:update_counter(Table, Row, {2, 1}) of
                Count -> {admitted, Count}
            catch error:badarg ->
                case ets:info(Table) of
                    undefined -> error(badarg);
                    _ -> fixed_window_hit(Table, Key, Window, MaxIdentities)
                end
            end;
        false ->
            fixed_window_insert(Table, Key, Window, Row, MaxIdentities)
    end.

fixed_window_insert(Table, Key, Window, Row, MaxIdentities) ->
    case reserve(Table, MaxIdentities) of
        false ->
            %% A concurrent hit on the same key may have just inserted it.
            case ets:member(Table, Row) of
                true -> fixed_window_hit(Table, Key, Window, MaxIdentities);
                false -> refused
            end;
        true ->
            case ets:insert_new(Table, {Row, 1}) of
                true -> {admitted, 1};
                false ->
                    release(Table, 1),
                    fixed_window_hit(Table, Key, Window, MaxIdentities)
            end
    end.

%% Token bucket in milli-tokens so refill never loses a remainder.
%% Row: {Key, MilliTokens, LastRefillMs}.
%%
%% Refill, admission and consumption are one compare-and-swap of the row.
%% A competing writer invalidates our snapshot, so retry from its new state.
%% Returns the balance after refill and before taking a token.
token_bucket_hit(Table, Key, CapacityMilli, RatePerSecond, MaxIdentities, NowMs) ->
    token_bucket_update(Table, key(Key), CapacityMilli, RatePerSecond, MaxIdentities, fun() -> NowMs end).

%% Sample after lookup, and again on a failed CAS: a request paused across
%% eviction must not recreate a full bucket with its pre-eviction timestamp.
token_bucket_check(Table, Key, CapacityMilli, RatePerSecond, MaxIdentities) ->
    token_bucket_update(Table, key(Key), CapacityMilli, RatePerSecond, MaxIdentities, fun now_ms/0).

token_bucket_update(Table, Key, CapacityMilli, RatePerSecond, Max, Clock) ->
    case ets:lookup(Table, Key) of
        [] ->
            case reserve(Table, Max) of
                false ->
                    %% A concurrent hit on the same key may have just inserted it.
                    case ets:member(Table, Key) of
                        true -> token_bucket_update(Table, Key, CapacityMilli, RatePerSecond, Max, Clock);
                        false -> refused
                    end;
                true ->
                    %% The first hit consumes a token as part of inserting the bucket.
                    case ets:insert_new(Table, {Key, CapacityMilli - 1000, Clock()}) of
                        true ->
                            {admitted, CapacityMilli};
                        false ->
                            release(Table, 1),
                            token_bucket_update(Table, Key, CapacityMilli, RatePerSecond, Max, Clock)
                    end
            end;
        [{Key, Tokens, Last} = Old] ->
            %% A request may have sampled time before a competing request but
            %% reached ETS later. Never move the refill clock backwards.
            Time = max(Clock(), Last),
            Available = min(CapacityMilli, Tokens + (Time - Last) * RatePerSecond),
            Remaining = case Available >= 1000 of
                true -> Available - 1000;
                false -> Available
            end,
            New = {Key, Remaining, Time},
            %% Key is a Gleam String (binary), not match-spec syntax.
            case ets:select_replace(Table, [{Old, [], [{const, New}]}]) of
                1 -> {admitted, Available};
                0 -> token_bucket_update(Table, Key, CapacityMilli, RatePerSecond, Max, Clock)
            end
    end.

%% -- WebSocket channels ------------------------------------------------------
%%
%% Topics are `pg` groups in a scope owned by howdy. Members are the socket
%% processes; `pg` monitors them and drops them when they exit, so a socket
%% that dies never needs to leave.

-define(CHANNEL_SCOPE, howdy_websocket_channels).

%% Start the scope on first use. It is not linked to the caller, so it
%% outlives the socket that happened to start it.
channel_scope() ->
    case whereis(?CHANNEL_SCOPE) of
        undefined ->
            case pg:start(?CHANNEL_SCOPE) of
                {ok, _} -> ok;
                {error, {already_started, _}} -> ok
            end;
        _ ->
            ok
    end,
    ?CHANNEL_SCOPE.

channel_join(Topic, Pid) ->
    ok = pg:join(channel_scope(), Topic, Pid),
    nil.

channel_leave(Topic, Pid) ->
    _ = pg:leave(channel_scope(), Topic, Pid),
    nil.

channel_members(Topic) ->
    pg:get_members(channel_scope(), Topic).

%% Send `{Tag, Message}` to every member of Topic. Duplicates arise when a
%% process joined more than once, so they are sent to once.
channel_broadcast(Topic, Tag, Message) ->
    lists:foreach(
        fun(Pid) -> Pid ! {Tag, Message} end,
        lists:usort(channel_members(Topic))
    ),
    nil.

tuple_second(Tuple) ->
    element(2, Tuple).
