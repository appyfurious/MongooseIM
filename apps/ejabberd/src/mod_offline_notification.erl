-module(mod_offline_notification).
-author('kharevich.vitali@gmail.com').

-behaviour(gen_mod).

-export([start/2,
   init/2,
   stop/1,
   process_notice/3]).

-define(PROCNAME, ?MODULE).
-define(API_URL(Path), "https://onesignal.com/api/v1" ++ Path).
-define(APP_ID(), list_to_binary(gen_mod:get_module_opt(<<"localhost">>, ?MODULE, onesignal_app_id, ''))).
-define(API_KEY(), list_to_binary(gen_mod:get_module_opt(<<"localhost">>, ?MODULE, onesignal_api_key, ''))).

-include("ejabberd.hrl").
-include("jlib.hrl").

start(Host, Opts) ->
    ?INFO_MSG("Starting mod_offline_notification", [] ),
    register(?PROCNAME,spawn(?MODULE, init, [Host, Opts])),
    ok.

init(Host, _Opts) ->
    inets:start(),
    ssl:start(),
    ejabberd_hooks:add(offline_message_hook, Host, ?MODULE, process_notice, 10),
    ok.

stop(Host) ->
    ?INFO_MSG("Stopping mod_offline_notification", [] ),
    ejabberd_hooks:delete(offline_message_hook, Host, ?MODULE, process_notice, 10),
    ok.

process_notice(From, To, Packet) ->
    Type = xml:get_tag_attr_s(<<"type">>, Packet),
    MessageBody = xml:get_path_s(Packet, [{elem, <<"body">>}, cdata]),

    case Type of
      <<"chat">> when MessageBody /= <<"">> ->
        case user_notification_settings(To#jid.luser) of 
          {enabled, [DeviceIdentifier, true, _]} ->
            send_notification(Type, DeviceIdentifier, From#jid.luser, MessageBody)
        end;
      <<"connect">> ->
        case user_notification_settings(To#jid.luser) of 
          {enabled, [DeviceIdentifier, _, true]} ->
            send_notification(Type, DeviceIdentifier, From#jid.luser, MessageBody)
        end;
      _ ->
        % ignore other packets
        false
    end.

send_notification(Type, DeviceIdentifier, From, MessageBody) ->
  JSON = jsx:encode([
    {app_id, ?APP_ID()}, 
    {include_ios_tokens, [DeviceIdentifier]},
    {data, [
      {type, Type},
      {from, From}
    ]},
    {contents, [
      {en, notification_text(Type, From, MessageBody)}
    ]}
  ]),

  httpc:request(post, {?API_URL("/notifications"), headers(?API_KEY()), "application/json", JSON},[],[]).

notification_text(Type, Username, MessageText)->
  FullName = user_fullname(Username),
  case Type of
    <<"chat">> -> 
      <<FullName/binary, ": ", MessageText/binary>>;
    <<"connect">> ->
      <<"New request from ", FullName/binary>>
  end.

user_notification_settings(Username) ->
  case ejabberd_odbc:sql_query(<<"localhost">>, ["SELECT push_id, message_notifications, request_notifications FROM user_profiles WHERE username='", ejabberd_odbc:escape(Username), "';"]) of
    {selected, _, [{<<"">>, _, _}]} ->
      {disabled};
    {selected, _, [{PushIdentifier, ChatNotifaction, RequestNotification}]} ->
      {enabled, [PushIdentifier, ChatNotifaction == <<"1">>, RequestNotification == <<"1">>]};
    _ ->
      {disabled}
  end.

user_fullname(Username) ->
  case ejabberd_odbc:sql_query(<<"localhost">>, ["SELECT CONCAT_WS(' ', first_name, last_name) as user_fullname FROM user_profiles WHERE username='", ejabberd_odbc:escape(Username), "';"]) of
    {selected, _, [{FullName}]} ->
      FullName;
    _ ->
      <<"Incognito">>
  end.

headers() ->
  [{"content-type", "application/json"}].

headers(ApiKey) when is_list(ApiKey) ->
  headers(list_to_binary(ApiKey));

headers(ApiKey) when is_binary(ApiKey) ->
  [{"authorization", binary_to_list(<<"Basic ", ApiKey/binary>>)} | headers()].