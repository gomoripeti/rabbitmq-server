%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%
%% Copyright (c) 2007-2021 VMware, Inc. or its affiliates.  All rights reserved.
%%

-module(rabbit_exchange_type_topic).

-include_lib("khepri/include/khepri.hrl").
-include_lib("rabbit_common/include/rabbit.hrl").

-behaviour(rabbit_exchange_type).

-export([description/0, serialise_events/0, route/2]).
-export([validate/1, validate_binding/2,
         create/2, delete/3, policy_changed/2, add_binding/3,
         remove_bindings/3, assert_args_equivalence/2]).
-export([info/1, info/2]).

-export([clear_data_in_khepri/0, mnesia_write_to_khepri/1]).

-rabbit_boot_step({?MODULE,
                   [{description, "exchange type topic"},
                    {mfa,         {rabbit_registry, register,
                                   [exchange, <<"topic">>, ?MODULE]}},
                    {requires,    rabbit_registry},
                    {enables,     kernel_ready}]}).

%%----------------------------------------------------------------------------

info(_X) -> [].
info(_X, _) -> [].

description() ->
    [{description, <<"AMQP topic exchange, as per the AMQP specification">>}].

serialise_events() -> false.

%% NB: This may return duplicate results in some situations (that's ok)
route(X, Delivery) ->
    rabbit_khepri:try_mnesia_or_khepri(
      fun() ->
              route_in_mnesia(X, Delivery)
      end,
      fun() ->
              route_in_khepri(X, Delivery)
      end).

validate(_X) -> ok.
validate_binding(_X, _B) -> ok.
create(_Tx, _X) -> ok.

delete(transaction, #exchange{name = X}, _Bs) ->
    rabbit_khepri:try_mnesia_or_khepri(
      fun() -> delete_in_mnesia(X) end,
      fun() -> delete_in_khepri(X) end);
delete(none, _Exchange, _Bs) ->
    ok.

policy_changed(_X1, _X2) -> ok.

add_binding(transaction, _Exchange, Binding) ->
    internal_add_binding(Binding);
add_binding(none, _Exchange, _Binding) ->
    ok.

remove_bindings(transaction, _X, Bs) ->
    rabbit_khepri:try_mnesia_or_khepri(
      fun() ->
              remove_bindings_in_mnesia(Bs)
      end,
      fun() ->
              remove_bindings_in_khepri(Bs)
      end);
remove_bindings(none, _X, _Bs) ->
    ok.

assert_args_equivalence(X, Args) ->
    rabbit_exchange:assert_args_equivalence(X, Args).

%%----------------------------------------------------------------------------
remove_bindings_in_mnesia(Bs) ->
    %% See rabbit_binding:lock_route_tables for the rationale for
    %% taking table locks.
    case Bs of
        [_] -> ok;
        _   -> [mnesia:lock({table, T}, write) ||
                   T <- [rabbit_topic_trie_node,
                         rabbit_topic_trie_edge,
                         rabbit_topic_trie_binding]]
    end,
    [case follow_down_get_path(X, split_topic_key(K)) of
         {ok, Path = [{FinalNode, _} | _]} ->
             trie_remove_binding(X, FinalNode, D, Args),
             remove_path_if_empty(X, Path);
         {error, _Node, _RestW} ->
             %% We're trying to remove a binding that no longer exists.
             %% That's unexpected, but shouldn't be a problem.
             ok
     end ||  #binding{source = X, key = K, destination = D, args = Args} <- Bs],
    ok.

remove_bindings_in_khepri(Bs) ->
    %% Let's handle bindings data outside of the transaction
    Data = [begin
                Path = khepri_exchange_type_topic_path(X) ++ split_topic_key_in_khepri(K),
                {Path, #{destination => D, arguments => Args}}
            end || #binding{source = X, key = K, destination = D, args = Args} <- Bs],
    rabbit_khepri:transaction(
      fun() ->
              [begin
                   case khepri_tx:get(Path) of
                       {ok, #{Path := #{data := Set0,
                                        child_list_length := Children}}} ->
                           Set = sets:del_element(Binding, Set0),
                           case {Children, sets:size(Set)} of
                               {0, 0} ->
                                   khepri_tx:delete(Path),
                                   %% TODO can we use a keep_while condition?
                                   remove_path_if_empty_in_khepri(lists:droplast(Path));
                               _ ->
                                   khepri_tx:put(Path, Set)
                           end;
                       _ ->
                           ok
                   end
               end || {Path, Binding} <- Data]
      end, rw),
    ok.

%% TODO use keepwhile instead?
remove_path_if_empty_in_khepri([?MODULE, topic_trie_binding]) ->
    ok;
remove_path_if_empty_in_khepri(Path) ->
    case khepri_tx:get(Path) of
        {ok, #{Path := #{data := Set,
                         child_list_length := Children}}} ->
            case {Children, sets:size(Set)} of
                {0, 0} ->
                    khepri_tx:delete(Path),
                    remove_path_if_empty_in_khepri(lists:droplast(Path));
                _ ->
                    ok
            end;
        _ ->
            ok
    end.

delete_in_mnesia(X) ->
    trie_remove_all_nodes(X),
    trie_remove_all_edges(X),
    trie_remove_all_bindings(X),
    ok.

delete_in_khepri(X) ->
    {ok, _} = rabbit_khepri:delete(khepri_exchange_type_topic_path(X)),
    ok.

internal_add_binding(#binding{source = X, key = K, destination = D, args = Args}) ->
    rabbit_khepri:try_mnesia_or_khepri(
      fun() ->
              FinalNode = follow_down_create(X, split_topic_key(K)),
              trie_add_binding(X, FinalNode, D, Args),
              ok
      end,
      fun () -> internal_add_binding_in_khepri(X, K, D, Args) end).

internal_add_binding_in_khepri(X, K, D, Args) ->
    Path = khepri_exchange_type_topic_path(X) ++ split_topic_key_in_khepri(K),
    Binding = #{destination => D, arguments => Args},
    rabbit_khepri:transaction(
      fun() ->
              Set0 = case khepri_tx:get(Path) of
                         {ok, #{Path := #{data := S}}} -> S;
                         _ -> sets:new()
                     end,
              Set = sets:add_element(Binding, Set0),
              {ok, _} = khepri_tx:put(Path, Set),
              ok
      end, rw).

khepri_exchange_type_topic_path(#resource{virtual_host = VHost, name = Name}) ->
    [?MODULE, topic_trie_binding, VHost, Name].

route_in_mnesia(#exchange{name = X},
                #delivery{message = #basic_message{routing_keys = Routes}}) ->
    lists:append([begin
                      Words = split_topic_key(RKey),
                      mnesia:async_dirty(fun trie_match/2, [X, Words])
                  end || RKey <- Routes]).

route_in_khepri(#exchange{name = X},
                #delivery{message = #basic_message{routing_keys = Routes}}) ->
    lists:append([begin
                      Words = khepri_topic_match(split_topic_key_in_khepri(RKey)),
                      Root = khepri_exchange_type_topic_path(X),
                      Path = Root ++ Words,
                      Fanout = Root ++ [<<"#">>],
                      Map = rabbit_khepri:transaction(
                              fun() ->
                                      case khepri_tx:get(Fanout, #{expect_specific_node => true}) of
                                          {ok, #{Fanout := #{data := _}} = Map} ->
                                              Map;
                                          _ ->
                                              case khepri_tx:get(Path) of
                                                  {ok, Map} -> Map;
                                                  _ -> #{}
                                              end
                                      end
                              end, ro),
                      maps:fold(fun(_, #{data := Data}, Acc) ->
                                        Bindings = sets:to_list(Data),
                                        [maps:get(destination, B) || B <- Bindings] ++ Acc;
                                   (_, _, Acc) ->
                                        Acc
                                end, [], Map)
                  end || RKey <- Routes]).

khepri_topic_match(Words) ->
    lists:map(fun(W) -> #if_any{conditions = [W, <<"*">>]} end, Words).

trie_match(X, Words) ->
    trie_match(X, root, Words, []).

trie_match(X, Node, [], ResAcc) ->
    trie_match_part(X, Node, "#", fun trie_match_skip_any/4, [],
                    trie_bindings(X, Node) ++ ResAcc);
trie_match(X, Node, [W | RestW] = Words, ResAcc) ->
    lists:foldl(fun ({WArg, MatchFun, RestWArg}, Acc) ->
                        trie_match_part(X, Node, WArg, MatchFun, RestWArg, Acc)
                end, ResAcc, [{W, fun trie_match/4, RestW},
                              {"*", fun trie_match/4, RestW},
                              {"#", fun trie_match_skip_any/4, Words}]).

trie_match_part(X, Node, Search, MatchFun, RestW, ResAcc) ->
    case trie_child(X, Node, Search) of
        {ok, NextNode} -> MatchFun(X, NextNode, RestW, ResAcc);
        error          -> ResAcc
    end.

trie_match_skip_any(X, Node, [], ResAcc) ->
    trie_match(X, Node, [], ResAcc);
trie_match_skip_any(X, Node, [_ | RestW] = Words, ResAcc) ->
    trie_match_skip_any(X, Node, RestW,
                        trie_match(X, Node, Words, ResAcc)).

follow_down_create(X, Words) ->
    case follow_down_last_node(X, Words) of
        {ok, FinalNode}      -> FinalNode;
        {error, Node, RestW} -> lists:foldl(
                                  fun (W, CurNode) ->
                                          NewNode = new_node_id(),
                                          trie_add_edge(X, CurNode, NewNode, W),
                                          NewNode
                                  end, Node, RestW)
    end.

follow_down_last_node(X, Words) ->
    follow_down(X, fun (_, Node, _) -> Node end, root, Words).

follow_down_get_path(X, Words) ->
    follow_down(X, fun (W, Node, PathAcc) -> [{Node, W} | PathAcc] end,
                [{root, none}], Words).

follow_down(X, AccFun, Acc0, Words) ->
    follow_down(X, root, AccFun, Acc0, Words).

follow_down(_X, _CurNode, _AccFun, Acc, []) ->
    {ok, Acc};
follow_down(X, CurNode, AccFun, Acc, Words = [W | RestW]) ->
    case trie_child(X, CurNode, W) of
        {ok, NextNode} -> follow_down(X, NextNode, AccFun,
                                      AccFun(W, NextNode, Acc), RestW);
        error          -> {error, Acc, Words}
    end.

remove_path_if_empty(_, [{root, none}]) ->
    ok;
remove_path_if_empty(X, [{Node, W} | [{Parent, _} | _] = RestPath]) ->
    case mnesia:read(rabbit_topic_trie_node,
                     #trie_node{exchange_name = X, node_id = Node}, write) of
        [] -> trie_remove_edge(X, Parent, Node, W),
              remove_path_if_empty(X, RestPath);
        _  -> ok
    end.

trie_child(X, Node, Word) ->
    case mnesia:read({rabbit_topic_trie_edge,
                      #trie_edge{exchange_name = X,
                                 node_id       = Node,
                                 word          = Word}}) of
        [#topic_trie_edge{node_id = NextNode}] -> {ok, NextNode};
        []                                     -> error
    end.

trie_bindings(X, Node) ->
    MatchHead = #topic_trie_binding{
      trie_binding = #trie_binding{exchange_name = X,
                                   node_id       = Node,
                                   destination   = '$1',
                                   arguments     = '_'}},
    mnesia:select(rabbit_topic_trie_binding, [{MatchHead, [], ['$1']}]).

trie_update_node_counts(X, Node, Field, Delta) ->
    E = case mnesia:read(rabbit_topic_trie_node,
                         #trie_node{exchange_name = X,
                                    node_id       = Node}, write) of
            []   -> #topic_trie_node{trie_node = #trie_node{
                                       exchange_name = X,
                                       node_id       = Node},
                                     edge_count    = 0,
                                     binding_count = 0};
            [E0] -> E0
        end,
    case setelement(Field, E, element(Field, E) + Delta) of
        #topic_trie_node{edge_count = 0, binding_count = 0} ->
            ok = mnesia:delete_object(rabbit_topic_trie_node, E, write);
        EN ->
            ok = mnesia:write(rabbit_topic_trie_node, EN, write)
    end.

trie_add_edge(X, FromNode, ToNode, W) ->
    trie_update_node_counts(X, FromNode, #topic_trie_node.edge_count, +1),
    trie_edge_op(X, FromNode, ToNode, W, fun mnesia:write/3).

trie_remove_edge(X, FromNode, ToNode, W) ->
    trie_update_node_counts(X, FromNode, #topic_trie_node.edge_count, -1),
    trie_edge_op(X, FromNode, ToNode, W, fun mnesia:delete_object/3).

trie_edge_op(X, FromNode, ToNode, W, Op) ->
    ok = Op(rabbit_topic_trie_edge,
            #topic_trie_edge{trie_edge = #trie_edge{exchange_name = X,
                                                    node_id       = FromNode,
                                                    word          = W},
                             node_id   = ToNode},
            write).

trie_add_binding(X, Node, D, Args) ->
    trie_update_node_counts(X, Node, #topic_trie_node.binding_count, +1),
    trie_binding_op(X, Node, D, Args, fun mnesia:write/3).

trie_remove_binding(X, Node, D, Args) ->
    trie_update_node_counts(X, Node, #topic_trie_node.binding_count, -1),
    trie_binding_op(X, Node, D, Args, fun mnesia:delete_object/3).

trie_binding_op(X, Node, D, Args, Op) ->
    ok = Op(rabbit_topic_trie_binding,
            #topic_trie_binding{
              trie_binding = #trie_binding{exchange_name = X,
                                           node_id       = Node,
                                           destination   = D,
                                           arguments     = Args}},
            write).

trie_remove_all_nodes(X) ->
    remove_all(rabbit_topic_trie_node,
               #topic_trie_node{trie_node = #trie_node{exchange_name = X,
                                                       _             = '_'},
                                _         = '_'}).

trie_remove_all_edges(X) ->
    remove_all(rabbit_topic_trie_edge,
               #topic_trie_edge{trie_edge = #trie_edge{exchange_name = X,
                                                       _             = '_'},
                                _         = '_'}).

trie_remove_all_bindings(X) ->
    remove_all(rabbit_topic_trie_binding,
               #topic_trie_binding{
                 trie_binding = #trie_binding{exchange_name = X, _ = '_'},
                 _            = '_'}).

remove_all(Table, Pattern) ->
    lists:foreach(fun (R) -> mnesia:delete_object(Table, R, write) end,
                  mnesia:match_object(Table, Pattern, write)).

new_node_id() ->
    rabbit_guid:gen().

split_topic_key(Key) ->
    split_topic_key(Key, [], []).

split_topic_key_in_khepri(Key) ->
    Words = split_topic_key(Key, [], []),
    [list_to_binary(W) || W <- Words].

split_topic_key(<<>>, [], []) ->
    [];
split_topic_key(<<>>, RevWordAcc, RevResAcc) ->
    lists:reverse([lists:reverse(RevWordAcc) | RevResAcc]);
split_topic_key(<<$., Rest/binary>>, RevWordAcc, RevResAcc) ->
    split_topic_key(Rest, [], [lists:reverse(RevWordAcc) | RevResAcc]);
split_topic_key(<<C:8, Rest/binary>>, RevWordAcc, RevResAcc) ->
    split_topic_key(Rest, [C | RevWordAcc], RevResAcc).

clear_data_in_khepri() ->
    Path = [?MODULE, topic_trie_binding],
    case rabbit_khepri:delete(Path) of
        {ok, _} -> ok;
        Error -> throw(Error)
    end.

mnesia_write_to_khepri(#topic_trie_binding{trie_binding = #trie_binding{exchange_name = X,
                                                                        destination   = D}}) ->
    %% There isn't enough information to rebuild the tree as the routing key is split
    %% along the trie tree on mnesia. But, we can query the bindings table (migrated
    %% previosly) and migrate the entries that match this <X, D> combo
    %% We'll probably update multiple times the bindings that differ only on the arguments,
    %% but that is fine. Migration happens only once, so it is better to do a bit more of work
    %% than skipping bindings because out of order arguments.
    Map = rabbit_binding:match_source_and_destination_in_khepri(X, D),
    Bindings = lists:foldl(fun(#{bindings := SetOfBindings}, Acc) ->
                                   sets:to_list(SetOfBindings) ++ Acc
                           end, [], maps:values(Map)),
    [internal_add_binding_in_khepri(X, K, D, Args) || #binding{key = K,
                                                               args = Args} <- Bindings],
    ok.
