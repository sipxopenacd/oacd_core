%%	The contents of this file are subject to the Common Public Attribution
%%	License Version 1.0 (the “License”); you may not use this file except
%%	in compliance with the License. You may obtain a copy of the License at
%%	http://opensource.org/licenses/cpal_1.0. The License is based on the
%%	Mozilla Public License Version 1.1 but Sections 14 and 15 have been
%%	added to cover use of software over a computer network and provide for
%%	limited attribution for the Original Developer. In addition, Exhibit A
%%	has been modified to be consistent with Exhibit B.
%%
%%	Software distributed under the License is distributed on an “AS IS”
%%	basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See the
%%	License for the specific language governing rights and limitations
%%	under the License.
%%
%%	The Original Code is Spice Telephony.
%%
%%	The Initial Developers of the Original Code is 
%%	Andrew Thompson and Micah Warren.
%%
%%	All portions of the code written by the Initial Developers are Copyright
%%	(c) 2008-2009 SpiceCSM.
%%	All Rights Reserved.
%%
%%	Contributor(s):
%%
%%	Andrew Thompson <athompson at spicecsm dot com>
%%	Micah Warren <mwarren at spicecsm dot com>
%%

%% @doc Stat tracker and monitoring module.  A combination of the cdr handler
%% and cpx_supervisor.  This handles health stats, and non-process monitoring.

-module(cpx_monitor).
-author(micahw).

-behaviour(gen_leader).

-ifdef(EUNIT).
-include_lib("eunit/include/eunit.hrl").
-endif.

-type(call_health() :: {Aggregate :: integer()}).
-type(agent_health() :: {Aggregate :: integer(), [{string(), call_health()}]}).
-type(queue_health() :: {Aggregate :: integer(), [{string(), call_health()}]}).
-type(agent_profile_health() :: {Aggregate :: integer(), [{string(), agent_health()}]}).
-type(queue_group_health() :: {Aggregate :: integer(), [{string(), queue_health()}]}).
-type(node_health() :: {Aggregate :: integer(), Queuegroups :: [{string(), queue_group_health()}], Agentprofiles :: [{string(), agent_profile_health()}]}).
-type(system_health() :: {Aggregate :: integer(), Nodes :: [{atom(), node_health()}]}).

-include("log.hrl").

%% API
-export([
	start_link/1,
	start/1,
	stop/0
	]).

%% gen_server callbacks
-export([init/1, 
	elected/3,
	surrendered/3,
	handle_DOWN/3,
	handle_leader_call/4,
	handle_leader_cast/3,
	from_leader/3,
	handle_call/4, 
	handle_cast/3, 
	handle_info/2,
	terminate/2, 
	code_change/4]).

-record(state, {
	nodes = [] :: [atom()],
	monitoring = [] :: [atom()],
	down = [] :: [atom()],
	auto_restart_mnesia = true :: 'false' | 'false',
	status = stable :: 'stable' | 'merging' | 'split',	
	splits = [] :: [{atom(), integer()}],
	merge_status = none :: 'none' | any(),
	merging = none :: 'none' | [atom()]
}).

%%====================================================================
%% API
%%====================================================================
	
start_link(Args) ->
	Nodes = lists:flatten(proplists:get_all_values(nodes, Args)),
	?INFO("nodes:  ~p", [Nodes]),
    gen_leader:start_link(?MODULE, Nodes, [], ?MODULE, Args, []).

start(Args) ->
	Nodes = proplists:get_all_values(nodes, Args),
	gen_leader:start(?MODULE, Nodes, [], ?MODULE, Args, []).
	
stop() ->
	gen_leader:call(?MODULE, stop).

%%====================================================================
%% gen_server callbacks
%%====================================================================
init(Args) when is_list(Args) ->
	process_flag(trap_exit, true),
	Nodes = lists:flatten(proplists:get_all_values(nodes, Args)),
	Mons = Nodes,
	lists:foreach(fun(N) -> monitor_node(N, true) end, Mons),
    {ok, #state{
		nodes = Nodes, 
		monitoring = Mons,
		auto_restart_mnesia = proplists:get_value(auto_restart_mnesia, Args, true)
	}}.


%% @hidden
elected(State, Election, Node) -> 
	?INFO("elected by ~w", [Node]),
	% what was down and is now up?
	Edown = gen_leader:down(Election),
	Foldf = fun({N, T}, {Up, Down}) ->
		case lists:memeber(N, Edown) of
			true ->
				{Up, [{N, T} | Down]};
			false ->
				{[{N, T} | Up], Down}
		end
	end,
	{Merge, Stilldown} = lists:foldl(Foldf, {[], []}, State#state.splits),
	Findoldest = fun({_N, T}, Time) when T > Time ->
			T;
		({_N, T}, Time) ->
			Time
	end,
	case Merge of
		[] ->
			{ok, ok, State};
		_Else ->
			Oldest = lists:foldl(Findoldest, 0, Merge),
			Mergenodes = lists:map(fun({N, _T}) -> N end, Merge),
			spawn(agent_auth, merge, [Mergenodes, Oldest, self()]),
			{ok, ok, State#state{status = merging, merge_status = [{agent_auth, waiting}], merging = Mergenodes}}
	end.

%% @hidden
surrendered(State, _LeaderState, _Election) -> 
	{ok, State}.
	
%% @hidden
handle_DOWN(Node, State, _Election) ->
	Newsplits = case proplists:get_value(Node, State#state.splits) of
		undefined ->
			[{Node, util:now()} | State#state.splits];
		_Time ->
			State#state.splits
	end,
	{ok, State#state{splits = Newsplits}}.

%% @hidden
handle_leader_call(Message, From, State, _Election) ->
	?WARNING("received unexpected leader_call ~p from ~p", [Message, From]),
	{reply, ok, State}.

%% @hidden
handle_leader_cast(Message, State, Election) ->
	?WARNING("received unexpected leader_cast ~p", [Message]),
	{noreply, State}.

%% @hidden
from_leader(_Msg, State, _Election) -> 
	?DEBUG("Stub from leader.", []),
	{ok, State}.

%%--------------------------------------------------------------------
%% Function: %% handle_call(Request, From, State) -> {reply, Reply, State} |
%%--------------------------------------------------------------------
handle_call(stop, _From, State, Election) ->
	{stop, normal, ok, State};
handle_call(_Request, _From, State, Election) ->
    Reply = ok,
    {reply, Reply, State}.

%%--------------------------------------------------------------------
%% Function: handle_cast(Msg, State) -> {noreply, State} |
%%--------------------------------------------------------------------
handle_cast({recover, Node}, State, _Election) ->
	case lists:member(Node, State#state.down) of
		false ->
			% just chill
			{noreply, State};
		true ->
			?INFO("~w appears to have recovered.", [Node]),
			Newdown = lists:delete(Node, State#state.down),
			Newmon = [Node | State#state.monitoring],
			{noreply, State#state{down = Newdown, monitoring = Newmon}}
	end;
handle_cast(_Request, State, _Election) -> 
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: handle_info(Info, State) -> {noreply, State} |
%%--------------------------------------------------------------------
handle_info({merge_complete, Mod, _Recs}, #state{merge_status = none, status = Status}= State) when Status == stable; Status == split ->
	?INFO("Prolly a late merge complete from ~w.", [Mod]),
	{noreply, State};
handle_info({merge_complete, Mod, Recs}, #state{status = merging} = State) ->
	Newmerged = dict:store(Mod, Recs, State#state.merge_status),
	case merge_complete(Newmerged) of
		true ->
			F = fun() ->
				sync_mnesia(State#state.monitoring, State#state.merging),
				case State#state.auto_restart_mnesia of
					true ->
						?WARNING("automatically restarting mnesia on formerly split nodes", []),
						lists:foreach(fun(N) -> rpc:call(mnesia, stop, [], 1000), rpc:call(mnesia, start, [], 1000) end, State#state.monitoring);
					false ->
						?WARNING("Mnesia will remain split until it is restarted on all other nodes.", []),
						ok
				end
			end,
			spawn(F),
			case State#state.down of
				[] ->
					{noreply, State#state{status = stable, merging = [], merge_status = none}};
				_Else ->
					{noreply, State#state{status = split, merging = [], merge_status = none}}
			end;
		false ->
			{noreply, State#state{merge_status = Newmerged}}
	end;
handle_info({nodedown, Node}, State) ->
	case lists:member(Node, State#state.monitoring) of
		true ->
			%monitor_node(Node, false),
			?ALERT("Node ~w is detected as being down!", [Node]),
			Newdown = [Node | State#state.down],
			Newmon = lists:delete(Node, State#state.monitoring),
			Sfun = fun() ->
				check_loop(Node)
			end,
			Pid = spawn_link(Sfun),
			timer:send_after(10000, Pid, check),
			{noreply, State#state{down = Newdown, monitoring = Newmon, status = split}};
		false ->
			% just chill
			{noreply, State}
	end;
handle_info({'EXIT', From, Reason}, State) ->
	?INFO("~p said it died due to ~p.", [From, Reason]),
	{noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: terminate(Reason, State) -> void()
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% Func: code_change(OldVsn, State, Extra) -> {ok, NewState}
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Election, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

recover(Node) ->
	gen_server:cast(?MODULE, {recover, Node}).

recovery_watch(Node) ->
	monitor_node(Node, false),
	receive
		{nodedown, Node} ->
			timer:send_after(1000, check)
	after 100 ->
		recover(Node),
		ok
	end,
	check_loop(Node).

check_loop(Node) ->
	receive
		check ->
			recovery_watch(Node); 
		_Otherwise -> 
			check_loop(Node)
	end.
	
merge_complete(Dict) ->
	% TODO extend this to more than just agent_auth
	case dict:find(agent_auth, Dict) of
		error ->
			false;
		{ok, waiting} ->
			false;
		{ok, _Rows} ->
			true
	end.

sync_mnesia([], _Rows) ->
	ok;
sync_mnesia([Node | Nodes], Rows) when Node =:= node() ->
	sync_mnesia(Nodes, Rows);
sync_mnesia([Node | Nodes], Rows) ->
	write_rows(Node, Rows),
	rpc:call(Node, mnesia, stop, [], 1000),
	sync_mnesia(Nodes, Rows).

write_rows(_Node, []) ->
	ok;
write_rows(Node, [{atomic, Rows} | Tail]) ->
	F = fun() ->
		lists:foreach(fun(R) -> mnesia:write(R) end, Rows)
	end,
	rpc:call(mnesia, transaction, [F], 10000),
	write_rows(Node, Tail).
	

-ifdef(EUNIT).

state_test_() ->
	[{"node down message recieved",
	fun() ->
		State = #state{
			monitoring = [node]
		},
		{noreply, Newstate} = handle_info({nodedown, node}, State),
		Expect = #state{down = [node], monitoring = [], status = split},
		?assertEqual(Expect, Newstate)
	end},
	{"node down message about a node we aren't monitoring",
	fun() ->
		State = #state{down = [node]},
		{noreply, Newstate} = handle_info({nodedown, node}, State),
		?assertEqual(State, Newstate)
	end},
	{"recovery message",
	fun() ->
		State = #state{down = [node]},
		{noreply, Newstate} = handle_cast({recover, node}, State, {}),
		Expected = #state{monitoring = [node], down = []},
		?assertEqual(Expected, Newstate)
	end},
	{"recovery about a node that isn't down",
	fun() ->
		State = #state{monitoring = [node]},
		{noreply, Newstate} = handle_cast({recover, node}, State, {}),
		?assertEqual(State, Newstate)
	end}].
	

-endif.
