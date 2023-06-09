-module(server).

-export([start_server/0]).

-include_lib("./defs.hrl").

-spec start_server() -> _.
-spec loop(_State) -> _.
-spec do_join(_ChatName, _ClientPID, _Ref, _State) -> _.
-spec do_leave(_ChatName, _ClientPID, _Ref, _State) -> _.
-spec do_new_nick(_State, _Ref, _ClientPID, _NewNick) -> _.
-spec do_client_quit(_State, _Ref, _ClientPID) -> _NewState.
start_server() ->
    catch unregister(server),
    register(server, self()),
    case whereis(testsuite) of
        undefined ->
            ok;
        TestSuitePID ->
            TestSuitePID ! {server_up, self()}
    end,
    %% nickname map. client_pid => "nickname"
    loop(#serv_st{
        nicks = maps:new(),
        %% registration map. "chat_name" => [client_pids]
        registrations = maps:new(),
        %% chatroom map. "chat_name" => chat_pid
        chatrooms = maps:new()
    }).

loop(State) ->
    receive
        %% initial connection
        {ClientPID, connect, ClientNick} ->
            NewState =
                #serv_st{
                    nicks = maps:put(ClientPID, ClientNick, State#serv_st.nicks),
                    registrations = State#serv_st.registrations,
                    chatrooms = State#serv_st.chatrooms
                },
            loop(NewState);
        %% client requests to join a chat
        {ClientPID, Ref, join, ChatName} ->
            NewState = do_join(ChatName, ClientPID, Ref, State),
            loop(NewState);
        %% client requests to join a chat
        {ClientPID, Ref, leave, ChatName} ->
            NewState = do_leave(ChatName, ClientPID, Ref, State),
            loop(NewState);
        %% client requests to register a new nickname
        {ClientPID, Ref, nick, NewNick} ->
            NewState = do_new_nick(State, Ref, ClientPID, NewNick),
            loop(NewState);
        %% client requests to quit
        {ClientPID, Ref, quit} ->
            NewState = do_client_quit(State, Ref, ClientPID),
            loop(NewState);
        {TEST_PID, get_state} ->
            TEST_PID ! {get_state, State},
            loop(State)
    end.

%% executes join protocol from server perspective
do_join(ChatName, ClientPID, Ref, State) ->
    case maps:is_key(ChatName, State#serv_st.chatrooms) of
        %%chatroom does not exist
        false ->
            %%chat room is spawned
            ChatPID = spawn(chatroom, start_chatroom, [ChatName]),
            {ok, ClientNick} = maps:find(ClientPID, State#serv_st.nicks),
            ChatPID ! {self(), Ref, register, ClientPID, ClientNick},
            #serv_st{
                nicks = State#serv_st.nicks,
                registrations = maps:put(ChatName, [ClientPID], State#serv_st.registrations),
                chatrooms = maps:put(ChatName, ChatPID, State#serv_st.chatrooms)
            };
        %%chatroom does exist
        true ->
            {ok, ClientNick} = maps:find(ClientPID, State#serv_st.nicks),
            {ok, ChatPID} = maps:find(ChatName, State#serv_st.chatrooms),
            ChatPID ! {self(), Ref, register, ClientPID, ClientNick},
            #serv_st{
                nicks = State#serv_st.nicks,
                registrations =
                    maps:put(
                        ChatName,
                        [ClientPID] ++ (maps:find(ChatName, State#serv_st.registrations)),
                        State#serv_st.registrations
                    ),
                chatrooms = State#serv_st.chatrooms
            }
    end.

% io:format("server:do_join(...): IMPLEMENT ME~n"),
% State.

%% executes leave protocol from server perspective
do_leave(ChatName, ClientPID, Ref, State) ->
    ChatPID = maps:get(ChatName, State#serv_st.chatrooms),
    RemovedPID = lists:delete(ClientPID, maps:get(ChatName, State#serv_st.registrations)),
    NewRegistration = maps:update(ChatName, RemovedPID, State#serv_st.registrations),

    NewState = #serv_st{
        nicks = State#serv_st.nicks,
        registrations = NewRegistration,
        chatrooms = State#serv_st.chatrooms
    },

    ChatPID ! {self(), Ref, unregister, ClientPID},
    ClientPID ! {self(), Ref, ack_leave},

    NewState.
% io:format("server:do_leave(...): IMPLEMENT ME~n"),
% State.

%% executes new nickname protocol from server perspective
do_new_nick(State, Ref, ClientPID, NewNick) ->
    case lists:member(NewNick, maps:values(State#serv_st.nicks)) of
        %% nickname is already in use
        true ->
            ClientPID ! {self(), Ref, err_nick_used},
            State;
        %% nickname is not in use
        false ->
            Func = fun(_, Y) -> lists:member(ClientPID, Y) end,
            Rooms = maps:filter(Func, State#serv_st.registrations),
            UpdateRoom =
                fun(X) ->
                    {ok, PID} = maps:find(X, State#serv_st.chatrooms),
                    PID ! {self(), Ref, update_nick, ClientPID, NewNick}
                end,
            lists:foreach(UpdateRoom, maps:keys(Rooms)),
            ClientPID ! {self(), Ref, ok_nick},
            #serv_st{
                nicks = maps:put(ClientPID, NewNick, State#serv_st.nicks),
                registrations = State#serv_st.registrations,
                chatrooms = State#serv_st.chatrooms
            }
    end.

client_quit_helper(State, Msg, ChatList) ->
    case ChatList of
        [] ->
            ok;
        [H | T] ->
            maps:get(H, State#serv_st.chatrooms) ! Msg,
            client_quit_helper(State, Msg, T)
    end.
%% executes client quit protocol from server perspective
do_client_quit(State, Ref, ClientPID) ->
    ChatRooms = maps:keys(
        maps:filter(fun(_K, V) -> lists:member(ClientPID, V) end, State#serv_st.registrations)
    ),
    client_quit_helper(State, {self(), Ref, unregister, ClientPID}, ChatRooms),
    Updated = #serv_st{
        nicks = maps:remove(ClientPID, State#serv_st.nicks),
        registrations = maps:map(
            fun(_K, V) -> lists:delete(ClientPID, V) end, State#serv_st.registrations
        ),
        chatrooms = State#serv_st.chatrooms
    },
    ClientPID ! {self(), Ref, ack_quit},
    Updated.
