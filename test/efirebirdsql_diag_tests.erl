%%% Diagnostic only, never merged: which parameter shape kills Firebird 2.5, and where.
%%% Every case runs in its own process and connection: the connection gen_server links to
%%% its caller, so a server crash must not take the test process down. Connect retries while
%%% the server restarts.
-module(efirebirdsql_diag_tests).

-include_lib("eunit/include/eunit.hrl").

conectar(Db, Crear) -> conectar(Db, Crear, 60).

conectar(_Db, _Crear, 0) ->
    {error, sin_servidor};
conectar(Db, Crear, N) ->
    Padre = self(),
    {Pid, Ref} = spawn_monitor(fun() ->
        R = (catch efirebirdsql:connect("localhost", os:getenv("ISC_USER", "sysdba"),
                os:getenv("ISC_PASSWORD", "masterkey"), Db, [{createdb, true} || Crear])),
        Padre ! {self(), R},
        receive seguir -> ok end,
        %% keep this process alive while the case runs: the connection is linked to it
        receive fin -> ok end
    end),
    receive
        {Pid, {ok, C}} -> {ok, C, Pid};
        {Pid, _} -> Pid ! fin, timer:sleep(500), conectar(Db, Crear, N - 1);
        {'DOWN', Ref, process, Pid, _} -> timer:sleep(500), conectar(Db, Crear, N - 1)
    after 15000 ->
        exit(Pid, kill), conectar(Db, Crear, N - 1)
    end.

x(N) -> binary:copy(<<"x">>, N).

%% {nombre, sql, params, lectura}; lectura = {Sql, Esperado} | ninguna
caso(Db, {Nombre, Sql, Params, Lectura}) ->
    T0 = erlang:monotonic_time(millisecond),
    Salida = case conectar(Db, false) of
        {ok, C, Duenno} ->
            Padre = self(),
            %% run the statement from a throwaway process too (the connection is linked to Duenno)
            {Pid, Ref} = spawn_monitor(fun() ->
                R = (catch efirebirdsql:execute(C, Sql, Params)),
                S = case {R, Lectura} of
                    {ok, ninguna} -> ok;
                    {ok, {SqlLee, Esperado}} ->
                        case catch efirebirdsql:execute(C, SqlLee) of
                            ok ->
                                case catch efirebirdsql:fetchone(C) of
                                    {ok, [{_, V}]} -> {ok, igual, V =:= Esperado};
                                    Otro -> {ok, lectura_fallo, Otro}
                                end;
                            Otro -> {ok, lectura_fallo, Otro}
                        end;
                    {Otro, _} -> Otro
                end,
                catch efirebirdsql:rollback(C),
                catch efirebirdsql:close(C),
                Padre ! {self(), S}
            end),
            S2 = receive
                {Pid, S} -> S;
                {'DOWN', Ref, process, Pid, Motivo} -> {proceso_murio, Motivo}
            after 60000 -> exit(Pid, kill), timeout
            end,
            Duenno ! fin,
            S2;
        Otro -> {sin_conexion, Otro}
    end,
    io:format(user, "DIAG ~s: ~p (~p ms, espera de conexion incluida)~n",
              [Nombre, Salida, erlang:monotonic_time(millisecond) - T0]).

ins(Col) -> iolist_to_binary(["insert into t (id, ", Col, ") values (?, ?)"]).
lee(Col, Id) -> iolist_to_binary(io_lib:format("select ~s from t where id = ~p", [Col, Id])).

diag_test_() ->
    {timeout, 900, fun() ->
        Db = lists:flatten(io_lib:format("/tmp/~p.fdb", [erlang:system_time()])),
        {ok, C0, Duenno0} = conectar(Db, true),
        ok = efirebirdsql:execute(C0, <<"select rdb$get_context('SYSTEM', 'ENGINE_VERSION') from rdb$database">>),
        io:format(user, "DIAG motor: ~p~n", [efirebirdsql:fetchone(C0)]),
        ok = efirebirdsql:execute(C0, <<"CREATE TABLE t (id INTEGER NOT NULL, h0 BLOB SUB_TYPE 0, h1 BLOB SUB_TYPE 1, v VARCHAR(100))">>),
        ok = efirebirdsql:commit(C0),
        efirebirdsql:close(C0),
        Duenno0 ! fin,
        ConBlob = (code:ensure_loaded(efirebirdsql_op) =:= {module, efirebirdsql_op})
                  andalso erlang:function_exported(efirebirdsql_op, create_blob, 2),
        io:format(user, "DIAG driver con blobs: ~p~n", [ConBlob]),
        %% Message layout (id INTEGER + one text param): wire size = 12 + ceil4(L).
        %% fmt_net_length (USHORT) wraps at L >= 65521; fmt_length wraps at L >= 65527.
        Base = [
            {"varchar(100) <- inline 65520 (control: error de truncado)", ins("v"), [1, x(65520)], ninguna},
            {"h0 <- inline 65520", ins("h0"), [2, x(65520)], {lee("h0", 2), x(65520)}},
            {"h0,h1 <- inline 32700 + 32700", <<"insert into t (id, h0, h1) values (?, ?, ?)">>, [3, x(32700), x(32700)], {lee("h0", 3), x(32700)}},
            {"varchar(100) <- inline 65525 (error limpio = la capa remota sobrevive)", ins("v"), [4, x(65525)], ninguna},
            {"h0 <- inline 65521", ins("h0"), [5, x(65521)], {lee("h0", 5), x(65521)}},
            {"h0 <- inline 65522", ins("h0"), [6, x(65522)], {lee("h0", 6), x(65522)}},
            {"h0 <- inline 65523", ins("h0"), [7, x(65523)], {lee("h0", 7), x(65523)}},
            {"h0 <- inline 65524", ins("h0"), [8, x(65524)], {lee("h0", 8), x(65524)}},
            {"h0 <- inline 65525", ins("h0"), [9, x(65525)], {lee("h0", 9), x(65525)}},
            {"h0 <- inline 65526", ins("h0"), [10, x(65526)], {lee("h0", 10), x(65526)}},
            {"h0 <- inline 65527", ins("h0"), [11, x(65527)], {lee("h0", 11), x(65527)}},
            {"h1 <- inline 65525", ins("h1"), [12, x(65525)], {lee("h1", 12), x(65525)}},
            {"select octet_length(cast(? as blob sub_type 0)) <- 65525",
             <<"select octet_length(cast(? as blob sub_type 0)) from rdb$database">>, [x(65525)], ninguna},
            {"h0,h1 <- inline 32760 + 32760", <<"insert into t (id, h0, h1) values (?, ?, ?)">>, [13, x(32760), x(32760)], {lee("h1", 13), x(32760)}},
            {"h0,h1 <- inline 33000 + 33000", <<"insert into t (id, h0, h1) values (?, ?, ?)">>, [14, x(33000), x(33000)], {lee("h1", 14), x(33000)}}
        ],
        Blob = [
            {"h0 <- blob 65536", ins("h0"), [20, x(65536)], {lee("h0", 20), x(65536)}},
            {"h1 <- blob 70000", ins("h1"), [21, x(70000)], {lee("h1", 21), x(70000)}},
            {"h0,h1 <- blob 70000 + blob 70000", <<"insert into t (id, h0, h1) values (?, ?, ?)">>, [22, x(70000), x(70000)], {lee("h1", 22), x(70000)}},
            {"h0,h1 <- inline 32000 + blob 65536", <<"insert into t (id, h0, h1) values (?, ?, ?)">>, [23, x(32000), x(65536)], {lee("h1", 23), x(65536)}},
            {"h0,h1 <- inline 65500 + blob 65536 (fmt_length 65518)", <<"insert into t (id, h0, h1) values (?, ?, ?)">>, [24, x(65500), x(65536)], {lee("h1", 24), x(65536)}},
            {"h0,h1 <- inline 65520 + blob 65536 (fmt_length 65538, ya cayo en la corrida 1)", <<"insert into t (id, h0, h1) values (?, ?, ?)">>, [25, x(65520), x(65536)], {lee("h1", 25), x(65536)}}
        ],
        Casos = case ConBlob of true -> Base ++ Blob; false -> Base end,
        lists:foreach(fun(Caso) -> caso(Db, Caso) end, Casos)
    end}.
