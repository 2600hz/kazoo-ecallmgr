%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2011-2023, 2600Hz
%%% @doc
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(ecallmgr_config_tests).

-export([]).

-include_lib("eunit/include/eunit.hrl").
-include("ecallmgr.hrl").

-spec render_test_() -> any().
render_test_() ->
    {'setup'
    ,fun kz_fixturedb_util:start_me/0
    ,fun kz_fixturedb_util:stop_me/1
    ,fun(_ReturnOfSetup) ->
             [
              {"HELP-44944: no filtering of callfwd endpoints", no_filter_when_call_failover()}
             ,{"HELP-44944: filtering of unregistered SIP endpoints", filter_when_unreged()}
             ,{"HELP-44944: filtering of unregistered SIP endpoints with dedup", filter_when_unreged_dedup()}
             ,{"HELP-10722: filtering endpoints", filter_endpoints_10722()}
             ]
     end
    }.

%% @doc if a device is unregistered but has a failover route, it
%% should have the failover channel built
no_filter_when_call_failover() ->
    AccountId = <<"account0000000000000000000044944">>,
    UserId = <<"user0000000000000000000000000004">>,

    %% device-4 should be "registered" while device-5 is not but has failover
    Needles = [_DeviceId = <<"Authorizing-ID='device00000000000000000000000004'">>
              ,_CallFwdDeviceId = <<"Authorizing-ID='device00000000000000000000000005'">>
              ,_CallFwdDestination = <<"loopback/+12223334455">>
              ],

    %% should be device-4, device-5 (with failover)
    Endpoints = kz_endpoints:by_owner_id(UserId, kz_json:new(), new_call(AccountId)),

    %% should be device-4 and device-5-failover
    Channels = build_channels(Endpoints, 'false'),

    [?_assertEqual(2, length(Channels))
    | find_needles(Needles, Channels)
    ].

filter_when_unreged() ->
    AccountId = <<"account0000000000000000000044944">>,
    UserId = <<"user0000000000000000000000000005">>,

    Needles = [_FailoverRoute = <<"loopback/+13334445555">>],

    Endpoints = kz_endpoints:by_owner_id(UserId, kz_json:new(), new_call(AccountId)),
    Channels = build_channels(Endpoints),

    [?_assertEqual(1, length(Channels))
    | find_needles(Needles, Channels)
    ].

filter_when_unreged_dedup() ->
    AccountId = <<"account0000000000000000000044944">>,
    UserId = <<"user0000000000000000000000000005">>,

    Needles = [_FailoverRoute = <<"loopback/+13334445555">>],

    Endpoints = kz_endpoints:by_owner_id(UserId, kz_json:new(), new_call(AccountId)),
    Channels = build_channels(Endpoints),

    [?_assertEqual(1, length(Channels))
    | find_needles(Needles, Channels)
    ].

filter_endpoints_10722() ->
    AccountId = <<"account0000000000000000000010722">>,
    UserId = <<"7145b996f7ee0d40b314114a9869b7fe">>,

    RegedNeedles = [_Device1Id = <<"Authorizing-ID='14b279cdaef7d55cff7235ba2a5010e9'">>
                   ,_Device2Id = <<"Authorizing-ID='239d0734328f7043629d425ce7d93a4d'">>
                   ,_Device3Id = <<"Authorizing-ID='2fee5aa5a89193f63822d09019dca1d7'">>
                   ,_Device4Id = <<"Authorizing-ID='e192d667e3abd732d802353b70c26248'">>
                   ],

    %% all four endpoints are "registered" so no need for failover
    %% channels
    Endpoints = [Endpoint | _EPs] = kz_endpoints:by_owner_id(UserId, kz_json:new(), new_call(AccountId)),
    Channels = build_channels(Endpoints),

    %% because the only endpoint is unregistered, and the user has
    %% failover configured, build the failover route
    UnregedNeedles = [_IsFowarding = <<"Call-Forward='true'">>
                     ,_DeviceId = <<"Authorizing-ID='14b279cdaef7d55cff7235ba2a5010e9'">>
                     ,_ForwardingTo = <<"loopback/+18887776666">>
                     ],
    UnregedEndpoint = kz_json:set_values([{<<"To-User">>, <<"unregistered">>}
                                         ,{<<"To-Username">>, <<"unregistered">>}
                                         ]
                                        ,Endpoint
                                        ),
    FailoverChannels = build_channels([UnregedEndpoint]),

    [?_assertEqual(1, length(FailoverChannels))
    ,?_assertEqual(4, length(Channels))
    | find_needles(RegedNeedles, Channels)
     ++ find_needles(UnregedNeedles, FailoverChannels)
    ].

find_needles(Needles, Channels) ->
    [?_assert(found(Needle, Channels)) || Needle <- Needles].

build_channels(Endpoints) ->
    build_channels(Endpoints, 'true').

build_channels(Endpoints, FilterWhenAllUnreged) ->
    BridgeEndpoints = ecallmgr_util:endpoint_jobjs_to_records(Endpoints),
    Filtered = ecallmgr_util:maybe_filter_failover_channels(BridgeEndpoints, FilterWhenAllUnreged),
    ecallmgr_util:build_bridge_channels(Filtered, []).

new_call(AccountId) ->
    Exec = [{fun kapps_call:set_account_id/2, AccountId}
           ,{fun kapps_call:set_account_db/2, kzs_util:format_account_db(AccountId)}
           ,{fun kapps_call:set_request/2, <<"+12223334444@2600hz.com">>}
           ,{fun kapps_call:set_to/2, <<"+12223334444@2600hz.com">>}
           ,{fun kapps_call:set_from/2, <<"+19998887777@atari.com">>}
           ,{fun kapps_call:set_call_id/2, kz_binary:rand_hex(6)}
           ,{fun kapps_call:set_resource_type/2, <<"audio">>}
           ,{fun kapps_call:set_caller_id_name/2, <<"Caller ID Name">>}
           ,{fun kapps_call:set_caller_id_number/2, <<"+19998887777">>}
           ],
    kapps_call:exec(Exec, kapps_call:new()).

found(_Needle, []) -> ?debugFmt("needle ~s not found~n", [_Needle]), 'false';
found(Needle, [Haystack|Haystacks]) ->
    case binary:match(Haystack, Needle) of
        'nomatch' -> found(Needle, Haystacks);
        {_, _} -> 'true'
    end.
