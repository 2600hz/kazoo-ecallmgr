%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2022, 2600Hz
%%% @doc Helps to know whether or not, a given endpoint has reached the given limit.
%%%
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
-type request() :: kz_term:api_terms().
-type endpoint_type() :: kz_term:ne_binary(). %% account, user, or device.
-type endpoint_id() :: kz_term:ne_binary().
-type pub_fun() :: fun((kz_term:api_terms()) -> 'ok').

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
handle_enforce_endpoint_limit_req(JObj, Props) ->
    'true' = kapi_call:enforce_endpoint_limit_req_v(JObj),
    BaseReq = [{<<"Fields">>, <<"all">>}
              ,{<<"Active-Only">>, 'true'}
              | kz_api:default_headers(?APP_NAME, ?APP_VERSION)
              ],
    EndpointType = kz_json:get_ne_binary_value(<<"Endpoint-Type">>, JObj),
    EndpointId = kz_json:get_ne_binary_value(<<"Endpoint-ID">>, JObj),
    handle_enforce_endpoint_limit_req(JObj, Props, BaseReq, EndpointType, EndpointId).

%%------------------------------------------------------------------------------
%% @doc Build the actual request and select the appropriate publish and response validation
%% functions based on EndpointType's value.
%% @end
%%------------------------------------------------------------------------------
-spec handle_enforce_endpoint_limit_req(endpoint_limit_req()
                                       ,kz_term:proplist()
                                       ,request()
                                       ,endpoint_type()
                                       ,endpoint_id()
                                       ) -> 'ok'.
handle_enforce_endpoint_limit_req(JObj, Props, BaseReq, <<"account">>=EndpointType, EndpointId) ->
    Req = [{<<"Account-ID">>, EndpointId} | BaseReq],
    PubFun = fun kapi_call:publish_query_account_channels_req/1,
    handle_enforce_endpoint_limit_req(JObj, Props, Req, EndpointType, EndpointId, PubFun);
handle_enforce_endpoint_limit_req(JObj, Props, BaseReq, <<"user">>=EndpointType, EndpointId) ->
    Req = [{<<"Owner-ID">>, EndpointId} | BaseReq],
    PubFun = fun kapi_call:publish_query_user_channels_req/1,
    handle_enforce_endpoint_limit_req(JObj, Props, Req, EndpointType, EndpointId, PubFun);
handle_enforce_endpoint_limit_req(JObj, Props, BaseReq, <<"device">>=EndpointType, EndpointId) ->
    Req = [{<<"Auth-ID">>, EndpointId} | BaseReq],
    PubFun = fun kapi_call:publish_query_auth_id_req/1,
    handle_enforce_endpoint_limit_req(JObj, Props, Req, EndpointType, EndpointId, PubFun).

-spec handle_enforce_endpoint_limit_req(endpoint_limit_req()
                                       ,kz_term:proplist()
                                       ,request()
                                       ,endpoint_type()
                                       ,endpoint_id()
                                       ,pub_fun()
                                       ) -> 'ok'.
handle_enforce_endpoint_limit_req(JObj, _Props, Req, EndpointType, EndpointId, PubFun) ->
    EndpointLimit = kz_json:get_integer_value(<<"Endpoint-Limit">>, JObj),
    Resps = kz_amqp_worker:call_collect(Req, PubFun, {'ecallmgr', 'true'}),
    CurrentCount = length(get_bridge_ids_from_responses(Resps)),
    lager:debug("~s ~s is using ~B out of ~B allowed channels",
                [EndpointType, EndpointId, CurrentCount, EndpointLimit]),
    publish_enforce_endpoint_limit_resp(JObj, CurrentCount =:= EndpointLimit).

%%------------------------------------------------------------------------------
%% @doc Get `bridge_ids' value from every channel in the response, remove duplicated value and
%% returns the counting of the elements in the resulting list.
%% @end
%%------------------------------------------------------------------------------
-spec get_bridge_ids_from_responses(kz_amqp_worker:request_return()) -> kz_term:ne_binaries().
get_bridge_ids_from_responses({'ok', Resps}) ->
    lager:debug("received responses from ~B ecallmgr nodes", [length(Resps)]),
    %% The response is a list of kz_json:objects(), 1 object per ecallmgr reply, in the form of:
    %% `{ok, [{[{<<"Channels">>, ChannelsFromEcallmgr1}, ...]}'
    %% `     ,{[{<<"Channels">>, ChannelsFromEcallmgrN}, ...]}'
    %% `     ]}'
    BridgeIds = [[kz_json:get_ne_binary_value(<<"bridge_id">>, Channel)
                  || Channel <- kz_json:get_list_value(<<"Channels">>, EcallmgrResp)
                 ]
                 || EcallmgrResp <- Resps
                ],
    %% Flatten resulting list, that way all the values are at the same depth=1 level, and then
    %% remove duplicated values, if any.
    lists:usort(lists:flatten(BridgeIds));
get_bridge_ids_from_responses(_Unexpected) ->
    lager:warning("unexpected channels listing response: ~p", [_Unexpected]),
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
