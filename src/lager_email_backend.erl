%% @author Daniel Luna <daniel@lunas.se>
%% @author Josh Marchán <josh@siftlogic.com>
%% @copyright 2012 SiftLogic LLC
%% @doc
-module(lager_email_backend).
-author('Daniel Luna <daniel@lunas.se>').
-author('Josh Marchán <josh@siftlogic.com>').
-behaviour(gen_event).

-compile([{parse_transform, lager_transform}]).

-export([init/1,
         handle_call/2,
         handle_event/2,
         handle_info/2,
         terminate/2,
         code_change/3,
         test/0]).

-record(state, {
          name,
          level,
          immediate_send_level,
          email_conf,
          last_send_time = null,
          messages = [],
          send_timer = null
         }).

-record(msg, {level, date, time, location, message}).

-record(email, {short_subject, count, level, date, time, body}).

-record(email_conf, {
          from,
          to,
          subject_prefix,
          opts,
          relay,
          send_delay % Delay before sending the next glob of emails, in seconds.
         }).

-define(SPECIAL_TRIGGER_MESSAGE, "Triggering delayed log email send.").

-define(DEFAULT_OPTIONS, [{relay, localhost},
                          {port, 25},
                          {auth, never},
                          {tls, never}]).

init(Params) ->
    Name = get_conf(name, Params, ?MODULE),
    Level = get_conf(level, Params, critical),
    ImmediateSendLevel = get_conf(immediate_send_level, Params, critical),
    Options = get_conf(opts, Params, []),
    Opts = lists:ukeymerge(1, lists:sort(Options),
                           lists:sort(?DEFAULT_OPTIONS)),
    EmailConf = #email_conf{
      from = get_conf(from, Params),
      to = get_conf(recipients, Params),
      subject_prefix = get_conf(subject_prefix, Params,
                                ["[", atom_to_list(node()), "] "]),
      opts = Opts,
      send_delay = get_conf(send_delay, Params, 60)
     },
    State = #state{
      name = Name,
      level = lager_util:level_to_num(Level),
      immediate_send_level = lager_util:level_to_num(ImmediateSendLevel),
      email_conf = EmailConf},
    %% io:format("Starting ~s with state ~p~n", [?MODULE, State]),
    {ok, State}.

handle_call({set_loglevel, Level}, #state{name = _Name} = State) ->
    %% io:format("Changed loglevel of ~s to ~p~n", [_Name, Level]),
    {ok, ok, State#state{level=lager_util:level_to_num(Level)}};
handle_call(get_loglevel, #state{level = Level} = State) ->
    {ok, Level, State};
handle_call(_Request, State) ->
    {ok, ok, State}.

handle_event({log, _Level, {_Date, _Time},
              [_LevelStr, _Location, [?SPECIAL_TRIGGER_MESSAGE]]},
             #state{messages = Msgs} = State) ->
    case length(Msgs) > 0 of
        true ->
            {ok, send_all(State)};
        false ->
            {ok, State}
    end;
handle_event({log, Dest, Level, {Date, Time}, [_LevelStr, Location, Message]},
             #state{name = Name, level = L} = State)
  when Level > L ->
    case lists:member({lager_email_backend, Name}, Dest) of
        true ->
            {ok, enqueue(State, Level, Date, Time, Location, Message)};
        false ->
            {ok, State}
    end;
handle_event({log, Level, {Date, Time}, [_LevelStr, Location, Message]},
             #state{level = L} = State) when Level =< L->
    NewState = enqueue(State, Level, Date, Time, Location, Message),
    {ok, NewState};
handle_event(_Event, State) ->
    {ok, State}.

handle_info({'DOWN', _, process, _, normal}, State) ->
    {ok, State};
handle_info({'DOWN', _, process, _, shutdown}, State) ->
    {ok, State};
handle_info({'DOWN', _, process, _, Reason}, State) ->
    io:format("~p #~p Crash while sending: ~p~n", [?MODULE, ?LINE, Reason]),
    {ok, State};
handle_info(Info, State) ->
    io:format("~p #~p Unknown info ~p~n", [?MODULE, ?LINE, Info]),
    {ok, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

ignore_error(Error) ->
    ignore_error(["OTP-PUB-KEY",
                  "type not compatible with table constraint",
                  "amqp_connection_type_sup",
                  "socket_error,einval",
                  "mochiweb,new_request",
                  "ssl_connection",
                  "pkix_decode_cert",
                  "pubkey_cert"], Error).

ignore_error([], _Error) ->
    false;
ignore_error([H | T], Error) ->
    case re:run(Error, H, [caseless, {capture, none}]) of
        match ->
            true;
        nomatch ->
            ignore_error(T, Error)
    end.

enqueue(#state{email_conf = #email_conf{send_delay = SendDelay},
               last_send_time = LastSendTime, messages = Msgs0,
               send_timer = Timer, immediate_send_level = ImmediateSendLevel}
        = State0,
        Level, Date, Time, Location, LogMessage) ->
    Msg = msg(Level, Date, Time, Location, LogMessage),
    State = State0#state{messages = [Msg | Msgs0]},
    case LastSendTime =:= null orelse
        (time_add(LastSendTime, SendDelay) < erlang:now()) orelse
        Level =< ImmediateSendLevel of
        true ->
            case Timer of
                null ->
                    ok;
                TRef ->
                    timer:cancel(TRef)
            end,
            send_all(State);
        false ->
            State
    end.

time_add({MegaSecs, Secs, MicroSecs}, Seconds) ->
    NewSecs = MegaSecs * 1000000 + Secs + Seconds,
    {NewSecs div 1000000, NewSecs rem 1000000, MicroSecs}.

send_all(#state{messages = Messages,
                email_conf = #email_conf{send_delay = SendDelay}}
         = State0) ->
    Emails = compose_emails(Messages),
    case length(Emails) > 0 of
        true ->
            State1 =
                lists:foldl(
                  fun(#email{count = Count, level = Level,
                             short_subject = ShortSubject,
                             date = Date, time = Time,
                             body = Body},
                      StateN) ->
                          send(StateN, ShortSubject, Count, Level, Date, Time, Body)
                  end,
                  State0,
                  Emails),
            %% TODO - after the send is done, start a process that will log another
            %%        message which will trigger another email blob send.
            {ok, TRef} = timer:apply_after(
                           SendDelay*1000,
                           lager,
                           log,
                           [info, self(), ?SPECIAL_TRIGGER_MESSAGE]),
            State1#state{messages = [],
                         last_send_time = erlang:now(),
                         send_timer = TRef};
        false ->
            State0
    end.

compose_emails(Messages) ->
    lists:foldl(
      fun(Msg, Emails) ->
              #msg{level = Level,
                   date = Date,
                   time = Time,
                   location = Location,
                   message = MsgText} = Msg,
              case ignore_error(MsgText) of
                  true ->
                      Emails;
                  false ->
                      ShortSubject = mk_shortstr(MsgText),
                      LevelStr = atom_to_list(lager_util:num_to_level(Level)),
                      Body =
                          [Date, "T", Time, "\r\n",
                           Location, "\r\n",
                           LevelStr, "\r\n",
                           MsgText],
                      case lists:keyfind(
                             ShortSubject,
                             #email.short_subject,
                             Emails) of
                          #email{count = Count,
                                 body = OldBody} = Email ->
                              NewEmail =
                                  Email#email{count = Count + 1,
                                              body = [Body,
                                                      "\r\n"
                                                      "~~~~~~~~~~~~~~~"
                                                      "~~~~~~~~~~~~~~~"
                                                      "~~~~~~~~~~~~~~~"
                                                      "\r\n"
                                                      | OldBody]},
                              lists:keyreplace(
                                ShortSubject, #email.short_subject, Emails, NewEmail);
                          false ->
                              NewEmail =
                                  #email{count = 1,
                                         short_subject = ShortSubject,
                                         level = Level,
                                         body = Body,
                                         date = Date,
                                         time = Time},
                              lists:keystore(
                                ShortSubject, #email.short_subject, Emails, NewEmail)
                      end
              end
      end,
      [],
      Messages).

send(#state{email_conf = EmailConf} = State,
     ShortSubject, Count, Level, _Date, _Time, EmailBody) ->
    #email_conf{
      from = From,
      to = ToList,
      subject_prefix = SubjectPrefix,
      opts = Opts} = EmailConf,
    LevelStr = atom_to_list(lager_util:num_to_level(Level)),
    ShortLog =
        case Count =< 1 of
            true ->
                io_lib:format(
                  "~s - ~s",
                  [LevelStr, ShortSubject]);
            false ->
                io_lib:format(
                  "~s (~p messages) - ~s",
                  [LevelStr, Count, ShortSubject])
        end,
    Msg =
        ["Subject: ", SubjectPrefix, ShortLog, "\r\n"
         "From: <", From, ">\r\n"
         "To: ", string:join(ToList, ","),
         "\r\n\r\n",
         EmailBody],
    {_Pid, _Ref} =
        spawn_monitor(fun() -> send_blocking(From, ToList, Msg, Opts) end),
    %% NOTE - this TODO is probably unnecessary, since we already check the
    %%        DOWN signal and log to console with relevant information.
    %% TODO = "Store _Pid and _Ref and handle errors.",
    State.

mk_shortstr(Str) ->
    case re:run(Str,
                "([a-z0-9_]+:[a-z0-9_]+/\\d+) #(\\d+)",
                [global, caseless, {capture, all_but_first, binary}]) of
        {match, [[Funcall, LineNumber] | _]} ->
            iolist_to_binary(io_lib:format("~s #~s", [Funcall, LineNumber]));
        nomatch ->
            Prefix =
                case re:run(Str,
                            "CRASH REPORT",
                            [global, caseless, {capture, none}]) of
                    match -> "CRASH REPORT - ";
                    nomatch -> ""
                end,
            case re:run(
                   Str,
                   "<\\d+\\.\\d+\\.\\d+>@([a-z0-9_]+:[a-z0-9_]+):(\\d+)",
                   [global,
                    caseless,
                    {capture, all_but_first, binary}]) of
                {match, [[Funcall, LineNumber] | _]} ->
                    iolist_to_binary([Prefix, Funcall, " #", LineNumber]);
                nomatch ->
                    iolist_to_binary(
                      [Prefix,
                       case re:run(
                              Str,
                              "([a-z0-9_]+:[a-z0-9_]+/\\d+)",
                              [global,
                               caseless,
                               {capture, all_but_first, binary}]) of
                           {match, [[Funcall] | _]} ->
                               Funcall;
                           nomatch ->
                               "uncategorized"
                       end])
            end
    end.

send_blocking(From, ToList, Msg, Opts) ->
    case gen_smtp_client:send_blocking({From, ToList, Msg}, Opts) of
        {error, Type, Error} ->
            Cmd =
                lists:flatten(io_lib:format(
                                "gen_smtp_client:send_blocking({"
                                "~p, ~p, ~p}, ~p)",
                                [From, ToList, Msg, Opts])),
            exit({error, Type, Error, Cmd, erlang:get_stacktrace()});
        {error, Reason} ->
            Cmd =
                lists:flatten(io_lib:format(
                                "gen_smtp_client:send_blocking({"
                                "~p, ~p, ~p}, ~p)",
                                [From, ToList, Msg, Opts])),
            exit({error, Reason, Cmd, erlang:get_stacktrace()});
        SMTPReceipt when is_binary(SMTPReceipt) ->
            io:format("Successfully sent email to ~s with receipt ~s",
                      [string:join(ToList, ", "), SMTPReceipt]),
            ok
    end.

get_conf(Key, L, Default) ->
    case lists:keyfind(Key, 1, L) of
        {Key, Value} -> Value;
        false -> Default
    end.

get_conf(Key, L) ->
    case lists:keyfind(Key, 1, L) of
        {Key, Value} -> Value;
        false -> exit({?MODULE, missing_config, Key})
    end.

msg(Level, Date, Time, Location, Message) ->
    #msg{level = Level, date = Date, time = Time,
         location = Location, message = Message}.

test() ->
    application:load(lager),
    Config1 = [{name, group1},
               {level, critical},
               {from, "noreply@example.com"},
               {recipients, ["devnull@example.com"]},
               {opts, [{relay, "localhost"}, {port, 26}]}],
    Config2 = [{name, group2},
               {level, alert},
               {from, "noreply@example.com"},
               {recipients, ["devnull@example.com"]},
               {opts, [{relay, "localhost"}, {port, 26}]}],
    application:set_env(lager, handlers,
                        [{lager_console_backend, debug},
                         {lager_email_backend, Config1},
                         {lager_email_backend, Config2}]),
    application:set_env(lager, error_logger_redirect, false),
    application:start(compiler),
    application:start(syntax_tools),
    ok = application:start(lager),
    lager:debug("Testing DEBUG"),
    lager:info("Testing INFO"),
    lager:notice("Testing NOTICE"),
    lager:warning("Testing WARNING"),
    lager:error("Testing ERROR"),
    lager:critical("Testing CRITICAL"),
    lager:alert("Testing ALERT"),
    lager:emergency("Testing EMERGENCY"),
    receive
    after 5000 -> ok
    end,
    application:stop(lager),
    ok.
