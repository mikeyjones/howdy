-module(howdy_telemetry_logs).

%% A logger handler that ties log lines to traces. It runs in the process
%% that logs, so it sees that process's current span:
%%
%% - Warnings and worse become `log` events on the current span, so they
%%   show up in any tracing backend next to the work that caused them.
%% - A crash report from a process with no span of its own becomes a failed
%%   `process crash` span, so crashes outside requests are not lost.
%% - Every line goes to the recorders, if any, for the dev admin.

-export([log/2, message/1, current_ids/0]).

-include_lib("opentelemetry_api/include/opentelemetry.hrl").

-define(MAX_MESSAGE, 4096).

log(Event = #{level := Level, meta := Meta}, #{config := #{recorders := Recorders}}) ->
    Message = message(Event),
    {TraceId, SpanId} = case current_ids() of
        undefined -> crash_span(Meta, Message);
        Ids -> span_event(Level, Message), Ids
    end,
    At = maps:get(time, Meta, erlang:system_time(microsecond)),
    [howdy_telemetry_recorder:record_log(R, TraceId, SpanId, At, Level, Message) || R <- Recorders],
    ok.

message(Event) ->
    Formatted = logger_formatter:format(Event, #{single_line => true, template => [msg]}),
    Binary = unicode:characters_to_binary(Formatted),
    case byte_size(Binary) > ?MAX_MESSAGE of
        true -> <<(string:slice(Binary, 0, ?MAX_MESSAGE))/binary, "…"/utf8>>;
        false -> Binary
    end.

%% The ids of the current span, if it is being recorded.
current_ids() ->
    case otel_tracer:current_span_ctx() of
        SpanCtx = #span_ctx{trace_id = TraceId, span_id = SpanId} ->
            case otel_span:is_recording(SpanCtx) of
                true -> {TraceId, SpanId};
                false -> undefined
            end;
        _ ->
            undefined
    end.

span_event(Level, Message) ->
    case logger:compare_levels(Level, warning) of
        lt -> ok;
        _ ->
            otel_span:add_event(otel_tracer:current_span_ctx(), <<"log">>,
                                #{<<"log.severity">> => atom_to_binary(Level),
                                  <<"log.message">> => Message})
    end.

crash_span(#{error_logger := #{type := crash_report}}, Message) ->
    Tracer = opentelemetry:get_application_tracer('howdy@telemetry'),
    SpanCtx = otel_tracer:start_span(otel_ctx:new(), Tracer, <<"process crash">>,
                                     #{attributes => #{<<"exception.message">> => Message}}),
    otel_span:set_status(SpanCtx, ?OTEL_STATUS_ERROR, <<"process crashed">>),
    otel_span:end_span(SpanCtx),
    case otel_span:is_recording(SpanCtx) orelse SpanCtx#span_ctx.trace_flags band 1 =:= 1 of
        true -> {SpanCtx#span_ctx.trace_id, SpanCtx#span_ctx.span_id};
        false -> {undefined, undefined}
    end;
crash_span(_Meta, _Message) ->
    {undefined, undefined}.
