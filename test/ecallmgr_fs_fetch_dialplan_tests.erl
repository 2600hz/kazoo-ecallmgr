%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2011-2025, 2600Hz
%%% @doc
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(ecallmgr_fs_fetch_dialplan_tests).

-export([]).

-include_lib("eunit/include/eunit.hrl").
-include("ecallmgr.hrl").

is_blacklisted_by_prefixes_test_() ->
    BlackListWithPrefix = kz_json:from_list([{<<"+1200">>, kz_json:new()}
                                            ,{<<"2001">>, kz_json:new()}
                                            ]),

    [?_assertEqual('false', ecallmgr_fs_fetch_dialplan:is_blacklisted_by_prefixes(BlackListWithPrefix
                                                                                 ,kz_json:set_value(<<"Caller-ID-Number">>, <<"+13002001122">>, kz_json:new())))
    ,?_assertEqual('false', ecallmgr_fs_fetch_dialplan:is_blacklisted_by_prefixes(BlackListWithPrefix
                                                                                 ,kz_json:set_value(<<"Caller-ID-Number">>, <<"+13012001122">>, kz_json:new())))
    ,?_assertEqual('true', ecallmgr_fs_fetch_dialplan:is_blacklisted_by_prefixes(BlackListWithPrefix
                                                                                ,kz_json:set_value(<<"Caller-ID-Number">>, <<"+12002001122">>, kz_json:new())))
    ].
