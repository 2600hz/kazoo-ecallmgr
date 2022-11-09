%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2022, 2600Hz
%%% @doc
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(ecallmgr_fs_endpoint_limit).
-behaviour(gen_listener).

%% API
-export([start_link/0
        ,handle_enforce_endpoint_limit_req/2
        ]).

%% gen_server callbacks
-export([init/1
        ,handle_call/3
        ,handle_cast/2
        ,handle_info/2
        ,handle_event/2
        ,terminate/2
        ,code_change/3
        ]).

-include("ecallmgr.hrl").

-define(SERVER, ?MODULE).

-define(RESPONDERS, [{{?MODULE, 'handle_enforce_endpoint_limit_req'}
                     ,[{<<"channel">>, <<"enforce_endpoint_limit_req">>}]
                     }
                    ]).
-define(BINDINGS, [{'call', [{'restrict_to', ['enforce_endpoint_limit_req']}]}]).
-define(QUEUE_NAME, <<?MODULE_STRING>>).
-define(QUEUE_OPTIONS, [{'exclusive', 'false'}]).
-define(CONSUME_OPTIONS, [{'exclusive', 'false'}]).

-type state() :: 'ok'.
-type endpoint_limit_req() :: kz_json:object().

%%%=============================================================================
%%% API
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @doc Starts the server.
%% @end
%%------------------------------------------------------------------------------
-spec start_link() -> kz_types:startlink_ret().
start_link() ->
    gen_listener:start_link({'local', ?MODULE}, ?MODULE,
                            [{'responders', ?RESPONDERS}
                            ,{'bindings', ?BINDINGS}
                            ,{'queue_name', ?QUEUE_NAME}
                            ,{'queue_options', ?QUEUE_OPTIONS}
                            ,{'consume_options', ?CONSUME_OPTIONS}
                            ], []).

-spec handle_enforce_endpoint_limit_req(endpoint_limit_req(), kz_term:proplist()) -> 'ok'.
handle_enforce_endpoint_limit_req(JObj, _Props) ->
    'true' = kapi_call:enforce_endpoint_limit_req_v(JObj),
    EndpointId = kz_json:get_ne_binary_value(<<"Endpoint-ID">>, JObj),
    _EndpointType = kz_json:get_ne_binary_value(<<"Endpoint-Type">>, JObj),
    EndpointLimit = kz_json:get_integer_value(<<"Endpoint-Limit">>, JObj),
    Req = [{<<"Authorizing-IDs">>, [EndpointId]}
          ,{<<"Fields">>, <<"all">>}
          ,{<<"Active-Only">>, 'false'}
          | kz_api:default_headers(?APP_NAME, ?APP_VERSION)
          ],

    Resps = kz_amqp_worker:call_collect(Req
                                       ,fun kapi_call:publish_query_user_channels_req/1
                                       ,{'ecallmgr', fun kapi_call:query_user_channels_resp_v/1, 'true', 'true'}
                                       ),
    CurrentCount = length(get_bridge_ids_from_responses(Resps)),
    lager:debug("~s ~s has ~B out of ~B maximum concurrent calls",
                [_EndpointType, EndpointId, CurrentCount, EndpointLimit]),
    publish_enforce_endpoint_limit_resp(JObj, CurrentCount =:= EndpointLimit).


-spec get_bridge_ids_from_responses(kz_amqp_worker:request_return()) -> kz_term:ne_binaries().
get_bridge_ids_from_responses({'ok', Rs}) ->
    %% The response is a list of lists, in the form of:
    %% `{ok, [[ChannelsFromEcallmgr1], [...], [ChannelsFromEcallmgrN]]}'
    BridgeIds = [[kz_json:get_ne_binary_value(<<"bridge_id">>, Channel)
                  || Channel <- kz_json:get_list_value(<<"Channels">>, EcallmgrResp)
                 ]
                 || EcallmgrResp <- Rs
                ],
    lists:usort(lists:flatten(BridgeIds));
get_bridge_ids_from_responses(_Other) ->
    lager:warning("unexpected response trying to list channels per endpoint_id: ~p", [_Other]),
    %% Returning an empty list, just to avoid blocking the callee from receiving calls.
    [].

-spec publish_enforce_endpoint_limit_resp(endpoint_limit_req(), boolean()) -> 'ok'.
publish_enforce_endpoint_limit_resp(JObj, HasReachedLimit) ->
    ServerId = kz_api:server_id(JObj),
    Resp = [{?KEY_MSG_ID, kz_api:msg_id(JObj)}
           ,{<<"Has-Reached-Limit">>, HasReachedLimit}
           | kz_api:default_headers(?APP_NAME, ?APP_VERSION)
           ],
    kz_amqp_worker:cast(Resp
                       ,fun(P) -> kapi_call:publish_enforce_endpoint_limit_resp(ServerId, P) end
                       ).


%%%=============================================================================
%%% gen_server callbacks
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @doc Initializes the server.
%% @end
%%------------------------------------------------------------------------------
-spec init([]) -> {'ok', state()}.
init([]) ->
    kz_log:put_callid(?DEFAULT_LOG_SYSTEM_ID),
    {'ok', 'ok'}.

%%------------------------------------------------------------------------------
%% @doc Handling call messages.
%% @end
%%------------------------------------------------------------------------------
-spec handle_call(any(), kz_term:pid_ref(), state()) -> kz_types:handle_call_ret_state(state()).
handle_call(_Req, _From, State) ->
    lager:debug("unhandled call from ~p: ~p", [_From, _Req]),
    {'noreply', State}.

%%------------------------------------------------------------------------------
%% @doc Handling cast messages.
%% @end
%%------------------------------------------------------------------------------
-spec handle_cast(any(), state()) -> kz_types:handle_cast_ret_state(state()).
handle_cast(_Req, State) ->
    lager:debug("unhandled cast: ~p", [_Req]),
    {'noreply', State}.

%%------------------------------------------------------------------------------
%% @doc Handling all non call/cast messages.
%% @end
%%------------------------------------------------------------------------------
-spec handle_info(any(), state()) -> kz_types:handle_info_ret_state(state()).
handle_info(_Msg, State) ->
    lager:debug("unhandled msg: ~p", [_Msg]),
    {'noreply', State}.

%%------------------------------------------------------------------------------
%% @doc Allows listener to pass options to handlers.
%% @end
%%------------------------------------------------------------------------------
-spec handle_event(kz_json:object(), state()) -> gen_listener:handle_event_return().
handle_event(_JObj, _State) ->
    {'reply', []}.

%%------------------------------------------------------------------------------
%% @doc This function is called by a `gen_server' when it is about to
%% terminate. It should be the opposite of `Module:init/1' and do any
%% necessary cleaning up. When it returns, the `gen_server' terminates
%% with Reason. The return value is ignored.
%%
%% @end
%%------------------------------------------------------------------------------
-spec terminate(any(), state()) -> 'ok'.
terminate(_Reason, _State) ->
    lager:debug("endpoint_limit listener going down: ~p", [_Reason]).

%%------------------------------------------------------------------------------
%% @doc Convert process state when code is changed.
%% @end
%%------------------------------------------------------------------------------
-spec code_change(any(), state(), any()) -> {'ok', state()}.
code_change(_OldVsn, State, _Extra) ->
    {'ok', State}.
