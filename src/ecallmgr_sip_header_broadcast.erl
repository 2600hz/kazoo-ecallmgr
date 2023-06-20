%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2013-2023, 2600Hz
%%% @doc Checks received SIP INFO messages for headers with the X-KX-Publish-*
%%% prefix and if found:
%%%    1. Exports those custom headers on the call that it was received on
%%%    2. Determines if the channel is in a conference
%%%        2a. If its in a conference sets those headers on all participants,
%%%            then sends a SIP INFO to them with the custom headers.
%%%        2b. Returns
%%%    3. If its not in a conference checks if there is an "other leg"
%%%        3a. If there is an other leg connected, sets those headers on it
%%%            then sends the peer a SIP INFO with the custom headers.
%%%
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(ecallmgr_sip_header_broadcast).

-export([init/0]).

-export([handle_publish_headers/1]).

-include("ecallmgr.hrl").

-type call_event() :: map().

%%%=============================================================================
%%% API
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @doc
%% ecallmgr_sip_header_broadcast:init().
%% webphone.getCallList().getCall()._getSession().sendInfo("application/json", {}, {extraHeaders: ["X-Foo: bar"]});
%% @end
%%------------------------------------------------------------------------------
-spec init() -> 'ok'.
init() ->
    _ = kazoo_bindings:bind(<<"event_stream.process.call_event.RECV_INFO">>, ?MODULE, 'handle_publish_headers'),
    'ok'.

-spec handle_publish_headers(call_event()) -> 'ok'.
handle_publish_headers(#{call_id:= UUID}=Event) ->
    kz_log:put_callid(UUID),
    case headers_to_publish(<<"Custom-SIP-Info-Headers">>, Event) of
        [] -> 'ok';
        Headers -> publish_headers(Event, Headers)
    end.

%%%=============================================================================
%%% Internal functions
%%%=============================================================================

%%------------------------------------------------------------------------------
%% @doc Given the JSON root key, return a proplist of all properties that match
%% (case insensitive) x-kz-publish-*, where the proplist key is case sensitive
%% and the value matches that of the JSON property.
%% @end
%%------------------------------------------------------------------------------
-spec headers_to_publish(kz_term:ne_binary(), call_event()) -> kz_term:proplist().
headers_to_publish(RootKey, #{payload := JObj}) ->
    %% Compare the key/header name as case insensitive but
    %% capture it as case sensitive
    Keys = [{kz_term:to_lower_binary(Key), Key}
            || Key <- kz_json:get_keys(RootKey, JObj)
           ],
    props:filter_undefined(
      lists:foldr(fun({<<"x-kz-publish-", _Rest/binary>>, Header}, Headers) ->
                          Value = kz_json:get_ne_binary_value([RootKey, Header], JObj),
                          [{Header, Value} | Headers];
                     (_, Headers) -> Headers
                  end, [], Keys
                 )
     ).

%%------------------------------------------------------------------------------
%% @doc Export the publish headers, for future peers, avoiding re-exporting
%% as FS will stack the export var.  Set the publish headers to the current value
%% to ensure the exports match the most recent update, then publish either to
%% other conference participants, a bridged peer, or none of the above.
%% @end
%%------------------------------------------------------------------------------
-spec publish_headers(call_event(), kz_term:proplist()) -> 'ok'.
publish_headers(#{call_id:= UUID, payload := JObj}=Event, Headers) ->
    lager:debug("publishing headers from SIP INFO prefixed with X-KZ-Publish-*"),

    %% For the call that sent the SIP INFO with the publish headers
    %% export those headers in FS so that any call it touch from this point
    %% forward will also inherit those headers.  IE: if the headers get set
    %% via an INFO then the calls setting them is bridged the SIP messages
    %% sent to the bridge endpoint should also carry the publish headers.
    export_headers(UUID, Event, Headers),

    %% Export technically will set the headers but if the exports already happened
    %% then they will be skipped because the export var will stack unbounded, so we
    %% need to set to be sure that the most current value is being used.
    set_headers(UUID, Event, Headers),

    %% If the call is in a conference then there will be a Conference-ID parameter
    %% and we need to set the headers then SIP INFO each participant, otherwise
    %% check if this is bridged and if so set the headers and then SIP INFO the other leg.
    case kz_json:get_ne_binary_value(<<"Conference-ID">>, JObj) of
        'undefined' -> maybe_publish_other_leg(Event, Headers);
        ConferenceId -> publish_to_conference_participants(ConferenceId, Event, Headers)
    end.

-spec export_headers(kz_term:ne_binary(), call_event(), kz_term:proplist()) -> 'ok'.
export_headers(_UUID, _Event, []) -> 'ok';
export_headers(UUID, #{node:= Node, payload:= JObj}=Event, [{Header, Value} | Headers]) ->
    Exported = kz_json:get_ne_binary_value(<<"Exported-Bridge-Variables">>, JObj, <<>>),
    _ = case binary:match(Exported, Header) of
            'nomatch' ->
                %% There might be more effecient ways to export (using a multiset) but
                %% the FS export command ensures that each variable is set on the call, added
                %% to the export list, and imported to any connected legs.  I don't believe we
                %% have a multi-set that does all that when this was written.
                %% Since these publish headers are only expected to be used extremely rarely
                %% there is no need to optimize the FS interactions unless usage later dictates.
                lager:debug("exporting header ~s with value ~s", [Header, Value]),
                _ = ecallmgr_util:send_cmd(Node, UUID, <<"bridge_export">>, <<"sip_h_", Header/binary, "=", Value/binary>>),
                ecallmgr_util:send_cmd(Node, UUID, <<"bridge_export">>, <<"sip_info_h_", Header/binary, "=", Value/binary>>);
            _Else -> 'ok'
        end,
    export_headers(UUID, Event, Headers).

%%------------------------------------------------------------------------------
%% @doc Fetch the list of participants, using direct FS interactions as this is
%% intended to be used with conference that might not be tracked by
%% ecallmgr_fs_conferences.  For each participant set the publish SIP headers on
%% that channel and trigger a SIP INFO.
%% @end
%%------------------------------------------------------------------------------
-spec publish_to_conference_participants(kz_term:ne_binary(), call_event(), kz_term:proplist()) -> 'ok'.
publish_to_conference_participants(ConferenceId, #{node:= Node, call_id:= UUID}=Event, Headers) ->
    %% This use case will invoked when using the conference factory so its safest to query
    %% FS directly rather than ecallmgr_fs_conferences.
    case freeswitch:api(Node, 'conference', <<ConferenceId/binary, " json_list">>) of
        {'ok', Result} ->
            lager:debug("SIP INFO publisher is in conference ~s/~s"
                       ,[Node, ConferenceId]
                       ),
            [JObj|_] = kz_json:decode(Result),
            Participants = [ParticipantId
                            || Participant <- kz_json:get_value(<<"members">>, JObj, [])
                                   ,(ParticipantId = kz_json:get_ne_binary_value(<<"uuid">>, Participant, UUID)) =/= UUID
                           ],
            publish_to_participants(Participants, Event, Headers);
        {'error', _R} ->
            lager:warning("SIP INFO publisher is in conference ~s/~s but unable to fetch participants: ~s"
                         ,[Node, ConferenceId, _R]
                         )
    end.

-spec publish_to_participants(kz_term:ne_binaries(), call_event(), kz_term:proplist()) -> 'ok'.
publish_to_participants([], _Event, _Headers) -> 'ok';
publish_to_participants([Participant|Participants], Event, Headers) ->
    set_headers(Participant, Event, Headers),
    send_info(Participant, Event),
    publish_to_participants(Participants, Event, Headers).

%%------------------------------------------------------------------------------
%% @doc Find a channel bridged to the one that sent the SIP INFO, and if there
%% is set the publish SIP headers on that channel then trigger a SIP INFO.
%% @end
%%------------------------------------------------------------------------------
-spec maybe_publish_other_leg(call_event(), kz_term:proplist()) -> 'ok'.
maybe_publish_other_leg(#{call_id:= UUID}=Event, Headers) ->
    case ecallmgr_fs_channel:fetch_other_leg(UUID) of
        {'error', 'not_found'} -> 'ok';
        {'ok', OtherLeg} ->
            PeerUUID = kz_json:get_ne_binary_value(<<"uuid">>, OtherLeg),
            set_headers(PeerUUID, Event, Headers),
            send_info(PeerUUID, Event)
    end.

%%------------------------------------------------------------------------------
%% @doc Utility function to set the headers proplist on a given channel
%% with a single command, for all future SIP messages (not just SIP INFO).
%% @end
%%------------------------------------------------------------------------------
-spec set_headers(kz_term:ne_binary(), call_event(), kz_term:proplist()) -> 'ok'.
set_headers(UUID, #{node:= Node}, Headers) ->
    lager:debug("setting published SIP INFO headers on call ~s", [UUID]),
    Cmd = 'kz_uuid_setvar_multi_encoded',
    Arg = list_to_binary(
            [UUID
            ," ^^"
            ,[[<<";sip_info_h_", Header/binary, "=", Value/binary>>
              ,<<";sip_h_", Header/binary, "=", Value/binary>>
              ]
              || {Header, Value} <- Headers
             ]
            ]
           ),
    freeswitch:api(Node, Cmd, Arg).

%%------------------------------------------------------------------------------
%% @doc Utility function to trigger the transmittion of a SIP INFO message on
%% the given channel.
%% @end
%%------------------------------------------------------------------------------
-spec send_info(kz_term:ne_binary(), call_event()) -> 'ok'.
send_info(UUID, #{node:= Node}) ->
    lager:debug("sending SIP INFO to call ~s", [UUID]),
    freeswitch:api(Node, 'uuid_send_info', UUID).
