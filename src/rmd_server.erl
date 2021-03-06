%% -------------------------------------------------------------------
%%
%% Copyright (c) 2015 Basho Technologies, Inc.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

-module(rmd_server).
-behaviour(gen_server).

-export([start_link/1]).
-export([get_status/0,
         configure/2,
         get_riak_frameworks/0,
         get_riak_clusters/0,
         get_riak_nodes/0]).
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         code_change/3,
         terminate/2]).

-include("riak_mesos_director.hrl").
-include_lib("erlzk/include/erlzk.hrl").
-include_lib("balance/include/balance.hrl").

-record(state, {zk, framework, cluster}).

%%%===================================================================
%%% API
%%%===================================================================

start_link(Args) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Args, []).

get_status() ->
    gen_server:call(?MODULE, {get_status}).

configure(Framework, Cluster) ->
    gen_server:cast(?MODULE, {configure, Framework, Cluster}).

get_riak_frameworks() ->
    gen_server:call(?MODULE, {get_riak_frameworks}).

get_riak_clusters() ->
    gen_server:call(?MODULE, {get_riak_clusters}).

get_riak_nodes() ->
    gen_server:call(?MODULE, {get_riak_nodes}).

%%%===================================================================
%%% Callbacks
%%%===================================================================

init([ZkNodesList, Framework, Cluster]) ->
    process_flag(trap_exit, true),
    {ok, ZK} = erlzk:connect(ZkNodesList, 30000),
    do_configure(ZK, Framework, Cluster),
    {ok, #state{zk=ZK, framework=Framework, cluster=Cluster}}.

handle_call({get_status}, _From,
        State=#state{framework=Framework, cluster=Cluster}) ->
    F1 = fun(St, Acc0) ->
        F2 = fun(Node, Acc1) ->
            N = [{id, Node#be.id},
            {name, list_to_binary(Node#be.name)},
            {port, Node#be.port},
            {status, Node#be.status},
            {maxconn, Node#be.maxconn},
            {pendconn, Node#be.pendconn},
            {actconn, Node#be.actconn},
            {lasterr, list_to_binary(lists:flatten(io_lib:format("~p",[Node#be.lasterr])))},
            {lasterrtime, datetime_str(Node#be.lasterrtime)},
            {act_count, Node#be.act_count},
            {act_time, Node#be.act_time}],
            % {pidlist, Node#be.pidlist}],
            [N|Acc1]
        end,
        Nodes = lists:foldl(F2, [], St#bp_state.be_list),

        P = [{name, St#bp_state.register_name},
        {local_ip, list_to_binary(St#bp_state.local_ip)},
        {local_port, St#bp_state.local_port},
        {conn_timeout, St#bp_state.conn_timeout},
        {act_timeout, St#bp_state.act_timeout},
        {nodes, Nodes}],
        % {acceptor, St#bp_state.acceptor},
        % {start_time, St#bp_state.start_time},
        % {to_timer, St#bp_state.to_timer},
        % {wait_list, St#bp_state.wait_list}],
        [P|Acc0]
    end,
    ProxyStatus = lists:foldl(F1, [], [
        bal_proxy:get_state(balance_http),
        bal_proxy:get_state(balance_protobuf)]),

    {WebHost, WebPort} = case riak_mesos_director:web_host_port() of
        {H, P} -> {list_to_binary(H), P};
        _ -> {undefined, undefined}
    end,
    ZKHosts = [begin
                   list_to_binary(NodeHost ++ ":" ++ integer_to_list(NodePort))
               end || {NodeHost, NodePort} <- riak_mesos_director:zk_node_list()],
    ZKNode = coordinated_nodes_zknode(Framework, Cluster),

    Status = [{proxy, ProxyStatus},
     {web, [{enabled, riak_mesos_director:web_enabled()},
            {host, WebHost},{port, WebPort}]},
     {zookeeper, [{hosts, ZKHosts},
                  {nodes_location, list_to_binary(ZKNode)}]}],
    {reply, Status, State};
handle_call({get_riak_frameworks}, _From, State=#state{zk=ZK}) ->
    Children = get_children(ZK, "/riak/frameworks"),
    {reply, Children, State};
handle_call({get_riak_clusters}, _From,
        State=#state{zk=ZK, framework=Framework}) ->
    ZKNode = coordinated_nodes_zknode(Framework, ""),
    CNodes = get_children(ZK, ZKNode),

    F1 = fun(CNode, Acc) ->
        ZKNode1 = lists:flatten(io_lib:format("~s/~s",[ZKNode, CNode])),
        NodeJson = get_data(ZK, ZKNode1),
        {struct,[_,{<<"ClusterName">>,NCluster},_,_,_,_,_]} = mochijson2:decode(NodeJson),
        [NCluster|Acc]
        end,
    Nodes = lists:foldl(F1, [], CNodes),
    Set = sets:from_list(Nodes),
    {reply, sets:to_list(Set), State};
handle_call({get_riak_nodes}, _From,
        State=#state{zk=ZK, framework=Framework, cluster=Cluster}) ->
    ZKNode = coordinated_nodes_zknode(Framework, Cluster),
    Nodes = do_get_riak_nodes(ZK, ZKNode, Framework, Cluster),
    {reply, Nodes, State};
handle_call(Message, _From, State) ->
    lager:error("Received undefined message in call: ~p", [Message]),
    {reply, {error, undefined_message}, State}.

handle_cast({configure, Framework, Cluster}, State=#state{zk=ZK}) ->
    do_configure(ZK, Framework, Cluster),
    {noreply, State#state{framework=Framework, cluster=Cluster}};
handle_cast(_Message, State) ->
    {noreply, State}.

handle_info({'EXIT', _Pid, _Reason}, State) ->
    {noreply, State};
handle_info({get_children, ZKNodeBin, node_children_changed}=Message,
        State=#state{zk=ZK,framework=Framework, cluster=Cluster}) ->
    ZKNode = binary_to_list(ZKNodeBin),
    lager:info("Received coordinated node change event: ~p. "
        "Synchronizing Riak Nodes...", [Message]),
    Changes = do_synchronize_riak_nodes(ZK, ZKNode, Framework, Cluster),
    lager:info("Synchronized Riak nodes, changes: ~p", [Changes]),
    erlzk:get_children(ZK, ZKNode, self()),
    {noreply, State};
handle_info(Message, State) ->
    lager:warning("Received unknown message: ~p", [Message]),
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(Reason, _State) ->
    lager:error("rmd_server terminated, reason: ~p", [Reason]),
    ok.

%%%===================================================================
%%% Private
%%%===================================================================

coordinated_nodes_zknode(Framework, _Cluster) ->
    Path = "/riak/frameworks/~s/coordinator/coordinatedNodes",
    lists:flatten(io_lib:format(Path,[Framework])).

do_get_riak_nodes(ZK, ZKNode0, _Framework, Cluster) ->
    CNodes = get_children(ZK, ZKNode0),

    F1 = fun(CNode, Acc) ->
        ZKNode1 = lists:flatten(io_lib:format("~s/~s",[ZKNode0, CNode])),
        NodeJson = get_data(ZK, ZKNode1),
        {struct,[{<<"FrameworkName">>,_NFramework},
                 {<<"ClusterName">>,NCluster},
                 {<<"NodeName">>,NodeName},
                 {<<"DisterlPort">>,_DistErlPort},
                 {<<"PBPort">>,PBPort},
                 {<<"HTTPPort">>,HTTPPort},
                 {<<"Hostname">>,HostName}]} = mochijson2:decode(NodeJson),

        case binary_to_list(NCluster) of
            Cluster ->
                [[{name, list_to_atom(binary_to_list(NodeName))},
                 {protobuf,
                   [{host, HostName}, {port, PBPort}]},
                 {http,
                    [{host, HostName}, {port, HTTPPort}]}]|Acc];
            _ -> Acc
        end

        end,
    Nodes = lists:foldl(F1, [], CNodes),
    Nodes.

do_synchronize_riak_nodes(ZK, ZKNode, Framework, Cluster) ->
    AvailableNodes = do_get_riak_nodes(ZK, ZKNode, Framework, Cluster),
    HTTPSt = bal_proxy:get_state(balance_http),
    ProxyHTTPNodes = HTTPSt#bp_state.be_list,
    PBSt = bal_proxy:get_state(balance_protobuf),
    ProxyPBNodes = PBSt#bp_state.be_list,

    F1 = fun([{name, NodeName},
              {protobuf,[{host, Host}, {port, PBPort}]},
              {http,[{host, Host}, {port, HTTPPort}]}], Acc0) ->
          Acc1 = case bal_proxy:get_host(balance_http, NodeName) of
              false ->
                HTTPBe = #be{id=NodeName,
                             name=binary_to_list(Host),
                             port=HTTPPort,
                             status=up,
                             maxconn=1024,
                             lasterr=no_error,
                             lasterrtime=0},

                lager:info("Adding ~p to http proxy", [NodeName]),
                bal_proxy:add_be(balance_http, HTTPBe, ""),
                [{http, NodeName} | Acc0];
              _ -> Acc0
          end,
          Acc2 = case bal_proxy:get_host(balance_protobuf, NodeName) of
              false ->
                PBBe = #be{id=NodeName,
                           name=binary_to_list(Host),
                           port=PBPort,
                           status=up,
                           maxconn=1024,
                           lasterr=no_error,
                           lasterrtime=0},
                lager:info("Adding ~p to protobuf proxy", [NodeName]),
                bal_proxy:add_be(balance_protobuf, PBBe, ""),
                [{protobuf, NodeName} | Acc1];
              _ -> Acc1
          end,
          Acc2
    end,
    Added = lists:foldl(F1, [], AvailableNodes),

    %% TODO: Mark as down, and wait until all active connections are gone
    %% before deleting
    F2 = fun(#be{id=NodeName}, Acc0) ->
        case riak_node_is_available(NodeName, AvailableNodes) of
            false ->
                lager:info("Removing ~p from http proxy", [NodeName]),
                bal_proxy:del_be(balance_http, NodeName),
                [{http, NodeName}|Acc0];
            _ -> Acc0
        end
    end,
    RemovedHTTP = lists:foldl(F2, [], ProxyHTTPNodes),

    %% TODO: Mark as down, and wait until all active connections are gone
    %% before deleting
    F3 = fun(#be{id=NodeName}, Acc0) ->
        case riak_node_is_available(NodeName, AvailableNodes) of
            false ->
                lager:info("Removing ~p from protobuf proxy", [NodeName]),
                bal_proxy:del_be(balance_protobuf, NodeName),
                [{protobuf, NodeName}|Acc0];
            _ -> Acc0
        end
    end,
    RemovedPB = lists:foldl(F3, [], ProxyPBNodes),
    [{added, Added}, {removed, RemovedHTTP ++ RemovedPB}].

do_watch_riak_nodes(ZK, ZKNode) ->
    erlzk:get_children(ZK, ZKNode, self()).

get_children(ZK, ZKNode) ->
    case erlzk:get_children(ZK, ZKNode) of
        {ok, Children} ->
            F1 = fun(Child, Acc) ->
                [list_to_binary(Child)|Acc] end,
            lists:foldl(F1, [], Children);
        {error, Reason} ->
            lager:error("Error getting children at node ~p: ~p",
                [ZKNode, Reason]),
            []
    end.

get_data(ZK, ZKNode) ->
    case erlzk:get_data(ZK, ZKNode) of
        {ok, {Data, _Stat}} -> Data;
        {error, Reason} ->
            lager:error("Error getting data at node ~p: ~p", [ZKNode, Reason]),
            []
    end.

% remote(N, M, F, A) ->
%     safe_rpc(N, M, F, A, 60000).
%
% safe_rpc(Node, Module, Function, Args, Timeout) ->
%     try rpc:call(Node, Module, Function, Args, Timeout) of
%         Result ->
%             Result
%     catch
%         'EXIT':{noproc, _NoProcDetails} ->
%             {badrpc, rpc_process_down}
%     end.

riak_node_is_available(_, []) -> false;
riak_node_is_available(Id, [[{name, Id}|_]|_]) -> true;
riak_node_is_available(Id, [[{name, _}|_]|Rest]) ->
    riak_node_is_available(Id, Rest).

do_configure(ZK, Framework, Cluster) ->
    ZKNode = coordinated_nodes_zknode(Framework, Cluster),
    do_synchronize_riak_nodes(ZK, ZKNode, Framework, Cluster),
    do_watch_riak_nodes(ZK, ZKNode).

datetime_str({_Mega, _Secs, _Micro}=Now) ->
    datetime_str(calendar:now_to_datetime(Now));
datetime_str({{Year, Month, Day}, {Hour, Min, Sec}}) ->
    list_to_binary(lists:flatten(io_lib:format("~4..0B-~2..0B-~2..0B ~2..0B:~2..0B:~2..0B",
                                 [Year,Month,Day,Hour,Min,Sec])));
datetime_str(_) ->
    null.
