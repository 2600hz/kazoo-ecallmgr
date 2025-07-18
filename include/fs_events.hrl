-ifndef(FS_EVENTS_HRL).

-define(NODE_MODULES_KEY(R), [<<"configuration">>
                             ,R
                             ,<<"modules">>
                             ]).

-define(FAX_EVENTS, ['spandsp::txfaxresult'
                    ,'spandsp::rxfaxresult'
                    ,'spandsp::txfaxpageresult'
                    ,'spandsp::rxfaxpageresult'
                    ,'spandsp::txfaxnegociateresult'
                    ,'spandsp::rxfaxnegociateresult'
                    ]).

-define(FS_SOFIA_TRANSFER_EVENTS, ['sofia::transferor'
                                  ,'sofia::transferee'
                                  ,'sofia::replaced'
                                  ,'sofia::intercepted'
                                  ]).

-define(FS_EVENTS, [{'channel', ['CHANNEL_CREATE', 'CHANNEL_ANSWER', 'CHANNEL_DESTROY']}
                   ,{'bridge', ['CHANNEL_BRIDGE', 'CHANNEL_UNBRIDGE']}
                   ,{'media', ['DETECTED_TONE', 'DTMF','CHANNEL_PROGRESS','CHANNEL_PROGRESS_MEDIA']}
                   ,{'record', ['RECORD_START', 'RECORD_STOP', 'RECORD_PAUSE', 'RECORD_RESUME', 'RECORD_MASK', 'RECORD_UNMASK']}
                   ,{'callflow', ['ROUTE_WINNER', 'CHANNEL_EXECUTE_COMPLETE', 'CHANNEL_APP_EXECUTE_COMPLETE', 'CHANNEL_METAFLOW']}
                   ,{'presence', ['PRESENCE_IN']}
                   ,{'channel_full_update', ['CHANNEL_DATA','CHANNEL_SYNC','CALL_UPDATE']}
                   ,{'channel_update', ['CHANNEL_HOLD','CHANNEL_UNHOLD']}
                   ,{'conference', ['conference::maintenance']}
                   ,{'fax', ?FAX_EVENTS}
                   ,{'kazoo', ['kazoo::noop', 'kazoo::masquerade']}
                   ,{'transfer', ?FS_SOFIA_TRANSFER_EVENTS}
                   ,{'loopback', ['loopback::bowout', 'loopback::direct']}
                   ,{'cdr', ['KZ_CDR']}
                   ]).

-define(FS_EVENTS_HRL, 'true').
-endif.
