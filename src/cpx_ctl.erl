-module(cpx_ctl).
-export([process/1]).

-include_lib("stdlib/include/qlc.hrl").
-include("agent.hrl").
-include("queue.hrl").

-define(RET_SUCCESS, {ok, 0}).
-define(RET_INVALID_COMMAND, {error, 1}).

-define(PRINT(Fmt), io:format(Fmt, [])).
-define(PRINT(Fmt, Data), io:format(Fmt, Data)).

-record(ctl_agent, {agent, profile, state, login_time}).

process(["stop"]) ->
	?PRINT("Stopping openacd~n"),
	init:stop(),
	?RET_SUCCESS;

process(["restart"]) ->
	?PRINT("Restarting openacd~n"),
	init:restart(),
	?RET_SUCCESS;

process(["pid"]) ->
	?PRINT("~s~n", [os:getpid()]),
	?RET_SUCCESS;

process(["status"]) ->
	{ok, Uptime} = application:get_env(openacd, uptime),
	AgentCount = length(agent_manager:list()),
	{ok, Queues} = call_queue_config:get_queues(),
	QueueCount = length(Queues),
	Plugins = cpx:plugins_running(),
	?PRINT("Uptime: ~p~n", [Uptime]),
	?PRINT("Number of queues: ~p~n", [QueueCount]),
	?PRINT("Number of agents logged in: ~p~n", [AgentCount]),
	?PRINT("~nPlugins running:~n"),
	[?PRINT("~p~n", [P]) || {P, running} <- Plugins],
	?RET_SUCCESS;

process(["list-agents"]) ->
	Agents = qlc:e(qlc:q([#ctl_agent{agent=Login, profile=Profile, state=State, login_time=StartTime} || {_, _, #cpx_agent_prop{login=Login, profile=Profile, state=State, start_time=StartTime}} <- gproc:table({l, p})])),
	lists:foreach(fun(A) ->
		?PRINT("~-10s", [A#ctl_agent.agent]),
		?PRINT("~-15s", [A#ctl_agent.profile]),
		{{Y,M,D}, {H,Mi,S}} = calendar:now_to_local_time(A#ctl_agent.login_time),
		?PRINT("~4..0B/~2..0B/~2..0B ~2..0B:~2..0B:~2..0B     ", [Y,M,D,H,Mi,S]),
		case A#ctl_agent.state of
			available -> ?PRINT("Available~n");
			{released, {Reason,_,_}} -> ?PRINT("Released: ~s~n", [Reason])
		end
	end, Agents),
	?RET_SUCCESS;

process(["list-queues"]) ->
	{ok, Queues} = call_queue_config:get_queues(),
	lists:foreach(fun(Queue) ->
		?PRINT("~s~n", [Queue#call_queue.name])
	end, Queues),
	?RET_SUCCESS;

process(["list-calls"]) ->
	?RET_SUCCESS;

process(["show-agent", _Agent]) ->
	?RET_SUCCESS;

process(["show-queue", _Queue]) ->
	?RET_SUCCESS;

process(["trace-agent", _Agent]) ->
	?RET_SUCCESS;

process(["kick-agent", _Agent]) ->
	?RET_SUCCESS;

process(_) ->
	?RET_INVALID_COMMAND.
