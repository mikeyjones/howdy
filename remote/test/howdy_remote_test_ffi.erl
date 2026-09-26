-module(howdy_remote_test_ffi).
-export([start_distribution/0, start_peer/0, stop_peer/1, crash/0]).

%% Turn this node into a distributed one so peers can connect to it. Both
%% nodes live on `localhost`: a bare shortname uses the machine's hostname,
%% which may resolve to an address the peer cannot reach (e.g. LAN IPv6 only).
start_distribution() ->
    _ = os:cmd("epmd -daemon"),
    case net_kernel:start('howdy_remote_test@localhost', #{name_domain => shortnames}) of
        {ok, _} -> nil;
        {error, {already_started, _}} -> nil
    end.

%% Start a connected peer node that can load this project's modules.
start_peer() ->
    Paths = [P || P <- code:get_path(), string:find(P, "/build/") =/= nomatch],
    {ok, Peer, Node} = peer:start(#{
        name => peer:random_name(howdy_remote_peer),
        host => "localhost",
        args => lists:append([["-pa", P] || P <- Paths])
    }),
    {Peer, atom_to_binary(Node)}.

stop_peer(Peer) ->
    peer:stop(Peer),
    nil.

crash() ->
    erlang:error(deliberate).
