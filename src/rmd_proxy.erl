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

-module(rmd_proxy).

-export([synchronize_nodes/2]).

-include("riak_mesos_director.hrl").
-include_lib("balance/include/balance.hrl").

%%%===================================================================
%%% API
%%%===================================================================

synchronize_nodes(Framework, Cluster) ->
    AvailableNodes = rmd_zk:get_riak_nodes(Framework, Cluster),
    {state,_,_,_,_,_,ProxyHTTPNodes,_,_,_,_} = bal_proxy:get_state(balance_http),
    {state,_,_,_,_,_,ProxyPBNodes,_,_,_,_} = bal_proxy:get_state(balance_protobuf),

    F1 = fun([{name, NodeName},
              {protobuf,[{host, Host}, {port, PBPort}]},
              {http,[{host, Host}, {port, HTTPPort}]}], Acc0) ->
          Acc1 = case bal_proxy:get_host(balance_http, NodeName) of
              false ->
                HTTPBe = #be{id=NodeName, name=binary_to_list(Host), port=HTTPPort, status=up, maxconn=1024, lasterr=no_error, lasterrtime=0},
                lager:info("Adding ~p to http proxy", [NodeName]),
                bal_proxy:add_be(balance_http, HTTPBe, ""),
                [{http, NodeName} | Acc0];
              _ -> Acc0
          end,
          Acc2 = case bal_proxy:get_host(balance_protobuf, NodeName) of
              false ->
                PBBe = #be{id=NodeName, name=binary_to_list(Host), port=PBPort, status=up, maxconn=1024, lasterr=no_error, lasterrtime=0},
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
        case node_is_available(NodeName, AvailableNodes) of
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
        case node_is_available(NodeName, AvailableNodes) of
            false ->
                lager:info("Removing ~p from protobuf proxy", [NodeName]),
                bal_proxy:del_be(balance_pb, NodeName),
                [{protobuf, NodeName}|Acc0];
            _ -> Acc0
        end
    end,
    RemovedPB = lists:foldl(F3, [], ProxyPBNodes),
    [{added, Added}, {removed, RemovedHTTP ++ RemovedPB}].



%%%===================================================================
%%% Private
%%%===================================================================

node_is_available(_, []) -> false;
node_is_available(Id, [[{name, Id}|_]|_]) -> true;
node_is_available(Id, [[{name, _}|_]|Rest]) -> node_is_available(Id, Rest).
