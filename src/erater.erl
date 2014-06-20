-module(erater).
-behavior(application).

% API
-export([start/0]).
-export([configure/2]).
-export([acquire/3]).

% Application calbacks
-export([start/2, stop/1]).

% Internal API
-export([run_spawned_counter/2, find_or_spawn/2]).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% Application
start() ->
    {ok, _} = application:ensure_all_started(erater),
    ok.

start(_, _) ->
    StartResult = erater_sup:start_link(),
    case application:get_env(?MODULE, groups) of
        undefined ->
            ok;
        {ok, Groups} when is_list(Groups) ->
            [configure(Group, Config) || {Group, Config} <- Groups]
    end,
    StartResult.

stop(_) ->
    ok.
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


configure(Group, Config) when is_atom(Group) ->
    ok = erater_config:validate(Config),
    case erater_sup:add_group(Group, Config) of
        {ok, _Pid} ->
            ok;
        {error,{already_started,Pid}} ->
            erater_group:configure(Pid, Config)
    end.

acquire(Group, CounterName, MaxWait) when is_atom(Group), is_integer(MaxWait) ->
    RPS = erater_group:get_config(Group, rps),
    CounterPid = case erater_shard:whereis(Group, CounterName) of
        local ->
            find_or_spawn(Group, CounterName);
        Node when Node /= undefined ->
            rpc:call(Node, ?MODULE, find_or_spawn, [Group, CounterName])
    end,
    erater_counter:acquire(CounterPid, RPS, MaxWait).

key(Group, CounterName) ->
    {n, l, {Group, CounterName}}.

find_or_spawn(Group, CounterName) ->
    Key = key(Group, CounterName),
    case gproc:where(Key) of
        CounterPid when is_pid(CounterPid) ->
            CounterPid;
        undefined ->
            {CounterPid, _} = gproc:reg_or_locate(Key, true, fun() -> ?MODULE:run_spawned_counter(Group, CounterName) end),
            CounterPid
    end.

% Hack: proc_lib internals are used here
run_spawned_counter(Group, CounterName) ->
    {dictionary, ParentDict} = process_info(whereis(Group), dictionary),
    Config = erater_group:get_config(Group),
    Parent = Group,
    Ancestors = proplists:get_value('$ancestors', ParentDict, []),

    proc_lib:init_p(Parent, Ancestors, erater_counter, run, [CounterName, Config]).