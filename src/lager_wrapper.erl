%% @copyright 2011, 2012 SiftLogic LLC
%%
%% @doc
%%

-module(lager_wrapper).

-compile([{parse_transform, lager_transform},
          %% IMPORTANT: DO NOT DO THIS ANYWHERE ELSE!!!!
          %% to resolve name clash with BIF error/2
          {no_auto_import, [error/2]}]).

-export([emergency/1, emergency/2]). %% system is unusable
-export([alert/1, alert/2]).         %% action must be taken immediately
-export([critical/1, critical/2]).   %% critical conditions
-export([error/1, error/2]).         %% error conditions
-export([warning/1, warning/2]).     %% warning conditions
-export([notice/1, notice/2]).       %% normal, but significant, condition
-export([info/1, info/2]).           %% informational message
-export([debug/1, debug/2]).         %% debug-level message

emergency(Format) ->
    emergency(Format, []).

emergency(Format, Data) ->
    Msg = format(Format, Data),
    lager:emergency("~s", [Msg]).

alert(Format) ->
    alert(Format, []).

alert(Format, Data) ->
    Msg = format(Format, Data),
    lager:alert("~s", [Msg]).

critical(Format) ->
    critical(Format, []).

critical(Format, Data) ->
    Msg = format(Format, Data),
    lager:critical("~s", [Msg]).

error(Format) ->
    error(Format, []).

error(Format, Data) ->
    Msg = format(Format, Data),
    lager:error("~s", [Msg]).

warning(Format) ->
    warning(Format, []).

warning(Format, Data) ->
    Msg = format(Format, Data),
    lager:warning("~s", [Msg]).

notice(Format) ->
    notice(Format, []).

notice(Format, Data) ->
    Msg = format(Format, Data),
    lager:notice("~s", [Msg]).

info(Format) ->
    info(Format, []).

info(Format, Data) ->
    Msg = format(Format, Data),
    lager:info("~s", [Msg]).

debug(Format) ->
    debug(Format, []).

debug(Format, Data) ->
    Msg = format(Format, Data),
    lager:debug("~s", [Msg]).

format(Format, Data) ->
    catch throw(stacktrace),
    Stacktrace = try throw(foo) catch throw:_ -> erlang:get_stacktrace() end,
    Frame = case Stacktrace of
                [_, _, ThisOne | _] -> ThisOne;
                [_ | _] -> unknown
            end,
    case Frame of
        unknown ->
            format_oneline("~p [unknown location] " ++ Format,
                           [self() | Data]);
        {M, F, A} ->
            format_oneline("~p ~p:~p/~p " ++ Format,
                           [self(), M, F, A | Data]);
        {M, F, A, Info} ->
            case lists:keysearch(line, 1, Info) of
                {value, {line, Line}} ->
                    format_oneline("~p ~p:~p/~p #~p " ++ Format,
                                   [self(), M, F, A, Line | Data]);
                false ->
                    format_oneline("~p ~p:~p/~p " ++ Format,
                                   [self(), M, F, A | Data])
            end
    end.

format_oneline(Format, Data) ->
    oneline(lists:flatten(io_lib:format(Format, Data))).

oneline([$\n | Rest]) -> [$\s | newline(Rest)];
oneline([C | Rest]) -> [C | oneline(Rest)];
oneline([]) -> [].

newline([$\s | Rest]) -> newline(Rest);
newline(Rest) -> oneline(Rest).
