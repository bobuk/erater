-module(erater_sup).
-behavior(supervisor).

-export([start_link/0, start_link/1, add_group/2, add_proxy/2, start_configurator/2, get_configurator/1]).
-export([init/1]).

%% Supervisors local registration names
regname(root) ->
    erater_sup;
regname(groups) ->
    erater_groups;
regname({group, Name, _}) ->
    list_to_atom(atom_to_list(Name) ++ "_sup");
regname({proxies, Group}) ->
    list_to_atom(atom_to_list(Group) ++ "_proxies").


%% By default start root supervisor
start_link() ->
    start_link(root).

%% Generic start function
start_link(Param) ->
    supervisor:start_link({local, regname(Param)}, ?MODULE, Param).

%% Start new group in groups supervisor
add_group(Name, Options) when is_atom(Name) ->
    GroupSpec = {Name,
                 {?MODULE, start_link, [{group, Name, Options}]},
                 transient, 1000, supervisor, []},
    supervisor:start_child(erater_groups, GroupSpec).

add_proxy(Group, Pair) ->
    supervisor:start_child(regname({proxies, Group}), [Group, Pair]).


%% Start group configurator under group supervisor
start_configurator(Group, Config) ->
    Sup = regname({group, Group, []}),
    ConfiguratorSpec = {configurator,
                 {erater_configurator, start_link, [Group, Config]},
                 transient, 100, worker, [erater_configurator]},
    StartResult = supervisor:start_child(Sup, ConfiguratorSpec),
    case StartResult of
        {error, already_present} -> % Transient child spec is not removed on death, so do it when needed
            ok = supervisor:delete_child(Sup, configurator),
            start_configurator(Group, Config);
        _ ->
            StartResult
    end.

%% If configurator is already running, return its pid. Return undefined otherwise
get_configurator(Group) when is_atom(Group) ->
    Sup = regname({group, Group, []}),
    ConfPids = [Pid || {configurator, Pid, _, _} <- supervisor:which_children(Sup)],
    case ConfPids of
        [Pid] -> Pid;
        [] -> undefined
    end.

%% Root supervisor init
init(root) ->
    Groups = {groups,
              {?MODULE, start_link, [groups]},
              permanent, 1000, supervisor, []},
    Pinger = {pinger,
              {erater_pinger, start_link, []},
              permanent, 1000, worker, [erater_pinger]},
    {ok, {{one_for_one, 5, 10}, [Groups, Pinger]}};

%% Groups supervisor is empty on start
init(groups) ->
    {ok, {{one_for_one, 5, 10}, []}};

%% Each group is supervisor itself
init({group, Name, Options}) ->
    Driver = erater_config:driver(Options), %% erater_group by default, other drivers (e.g. ETS) may appear in future
    Manager = {manager,
                 {Driver, start_link, [Name, Options]},
                 transient, 1000, worker, [Driver]},
    Timeserver = {timeserver,
                  {erater_timeserver, start_link, [Name, Options]},
                  transient, 1000, worker, [erater_timeserver]},
    ProxySup = {proxies,
                {?MODULE, start_link, [{proxies, Name}]},
                permanent, 1000, supervisor, []},
    MinishardParts = minishard_sup:cluster_internal_specs(Name, erater_shard),
    {ok, {{one_for_all, 10, 1}, [Manager, Timeserver, ProxySup] ++ MinishardParts}};

%% Each group has its own proxy set
init({proxies, _}) ->
    ProxySpec = {undefined,
                 {erater_proxy, start_link, []},
                 temporary, 1000, worker, [erater_proxy]},
    {ok, {{simple_one_for_one, 10, 1}, [ProxySpec]}}.

