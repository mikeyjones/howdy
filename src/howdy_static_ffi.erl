%% HTTP dates for howdy/static's conditional requests.
-module(howdy_static_ffi).
-export([http_date/1, parse_http_date/1]).

%% Seconds since the epoch as an IMF-fixdate, `Sun, 06 Nov 1994 08:49:37 GMT`.
%% Formatted here rather than with `httpd_util:rfc1123_date/1`, which takes
%% local time and shifts it.
http_date(Seconds) ->
    {{Y, Mo, D}, {H, Mi, S}} = calendar:system_time_to_universal_time(Seconds, second),
    Day = element(calendar:day_of_the_week(Y, Mo, D),
                  {"Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"}),
    Month = element(Mo, {"Jan", "Feb", "Mar", "Apr", "May", "Jun",
                         "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"}),
    unicode:characters_to_binary(
        io_lib:format("~s, ~2..0B ~s ~4..0B ~2..0B:~2..0B:~2..0B GMT",
                      [Day, D, Month, Y, H, Mi, S])).

%% An IMF-fixdate to seconds since the epoch. The two obsolete forms HTTP
%% still allows (RFC 850 and asctime) are not recognised, which only costs
%% a full response; `httpd_util:convert_request_date` is not used because it
%% shifts the result by the local time zone.
parse_http_date(<<_Day:3/binary, ", ", D:2/binary, " ", Mon:3/binary, " ",
                  Y:4/binary, " ", H:2/binary, ":", Mi:2/binary, ":",
                  S:2/binary, " GMT">>) ->
    try
        Month = month(Mon),
        DateTime = {{b2i(Y), Month, b2i(D)}, {b2i(H), b2i(Mi), b2i(S)}},
        true = calendar:valid_date(element(1, DateTime)),
        Epoch = calendar:datetime_to_gregorian_seconds({{1970, 1, 1}, {0, 0, 0}}),
        {ok, calendar:datetime_to_gregorian_seconds(DateTime) - Epoch}
    catch
        _:_ -> {error, nil}
    end;
parse_http_date(_) ->
    {error, nil}.

b2i(Bin) -> binary_to_integer(Bin).

month(<<"Jan">>) -> 1;
month(<<"Feb">>) -> 2;
month(<<"Mar">>) -> 3;
month(<<"Apr">>) -> 4;
month(<<"May">>) -> 5;
month(<<"Jun">>) -> 6;
month(<<"Jul">>) -> 7;
month(<<"Aug">>) -> 8;
month(<<"Sep">>) -> 9;
month(<<"Oct">>) -> 10;
month(<<"Nov">>) -> 11;
month(<<"Dec">>) -> 12.
