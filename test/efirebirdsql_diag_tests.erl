%%% Diagnostic only, never merged: which parameter shape kills Firebird 2.5, and where.
%%% Every case runs on its own connection; connect retries while the server restarts.
-module(efirebirdsql_diag_tests).

-include_lib("eunit/include/eunit.hrl").

conectar(Db, Crear) -> conectar(Db, Crear, 40).

conectar(_Db, _Crear, 0) ->
    {error, sin_servidor};
conectar(Db, Crear, N) ->
    case catch efirebirdsql:connect("localhost", os:getenv("ISC_USER", "sysdba"),
            os:getenv("ISC_PASSWORD", "masterkey"), Db, [{createdb, true} || Crear]) of
        {ok, C} -> {ok, C};
        _ -> timer:sleep(500), conectar(Db, Crear, N - 1)
    end.

x(N) -> binary:copy(<<"x">>, N).

%% {nombre, sql, params, lectura}; lectura = {Sql, Esperado} | ninguna
caso(Db, {Nombre, Sql, Params, Lectura}) ->
    T0 = erlang:monotonic_time(millisecond),
    Salida = case conectar(Db, false) of
        {ok, C} ->
            R = (catch efirebirdsql:execute(C, Sql, Params)),
            S = case {R, Lectura} of
                {ok, ninguna} -> ok;
                {ok, {SqlLee, Esperado}} ->
                    ok = efirebirdsql:execute(C, SqlLee),
                    {ok, [{_, V}]} = efirebirdsql:fetchone(C),
                    {ok, igual, V =:= Esperado};
                {Otro, _} -> Otro
            end,
            catch efirebirdsql:rollback(C),
            catch efirebirdsql:close(C),
            S;
        Otro -> {sin_conexion, Otro}
    end,
    io:format(user, "DIAG ~s: ~P (~p ms de espera incluida)~n",
              [Nombre, Salida, 6, erlang:monotonic_time(millisecond) - T0]).

ins(Col) -> iolist_to_binary(["insert into t (id, ", Col, ") values (?, ?)"]).
lee(Col, Id) -> iolist_to_binary(io_lib:format("select ~s from t where id = ~p", [Col, Id])).

diag_test_() ->
    {timeout, 600, fun() ->
        Db = lists:flatten(io_lib:format("/tmp/~p.fdb", [erlang:system_time()])),
        {ok, C0} = conectar(Db, true),
        ok = efirebirdsql:execute(C0, <<"select rdb$get_context('SYSTEM', 'ENGINE_VERSION') from rdb$database">>),
        io:format(user, "DIAG motor: ~p~n", [efirebirdsql:fetchone(C0)]),
        ok = efirebirdsql:execute(C0, <<"CREATE TABLE t (id INTEGER NOT NULL, h0 BLOB SUB_TYPE 0, h1 BLOB SUB_TYPE 1, v VARCHAR(100))">>),
        ok = efirebirdsql:commit(C0),
        efirebirdsql:close(C0),
        ConBlob = (code:ensure_loaded(efirebirdsql_op) =:= {module, efirebirdsql_op})
                  andalso erlang:function_exported(efirebirdsql_op, create_blob, 2),
        io:format(user, "DIAG driver con blobs: ~p~n", [ConBlob]),
        %% From safe to risky, so a crash late in the list loses the least.
        Base = [
            {"varchar(100) <- inline 65520 (se espera error de truncado)", ins("v"), [1, x(65520)], ninguna},
            {"h0 <- inline 65520", ins("h0"), [2, x(65520)], {lee("h0", 2), x(65520)}},
            {"h1 <- inline 65520", ins("h1"), [3, x(65520)], {lee("h1", 3), x(65520)}},
            {"h0,h1 <- inline 33000 + 33000", <<"insert into t (id, h0, h1) values (?, ?, ?)">>, [4, x(33000), x(33000)], {lee("h0", 4), x(33000)}},
            {"h0,h1 <- inline 40000 + 40000", <<"insert into t (id, h0, h1) values (?, ?, ?)">>, [5, x(40000), x(40000)], {lee("h1", 5), x(40000)}},
            {"h0 <- inline 65521", ins("h0"), [6, x(65521)], {lee("h0", 6), x(65521)}},
            {"h0 <- inline 65522", ins("h0"), [7, x(65522)], {lee("h0", 7), x(65522)}},
            {"h0 <- inline 65523", ins("h0"), [8, x(65523)], {lee("h0", 8), x(65523)}},
            {"h0 <- inline 65524", ins("h0"), [9, x(65524)], {lee("h0", 9), x(65524)}},
            {"varchar(100) <- inline 65525 (error de truncado = la capa remota sobrevive)", ins("v"), [10, x(65525)], ninguna},
            {"select octet_length(cast(? as blob sub_type 0)) <- 65525",
             <<"select octet_length(cast(? as blob sub_type 0)) from rdb$database">>, [x(65525)], ninguna},
            {"h1 <- inline 65525", ins("h1"), [11, x(65525)], {lee("h1", 11), x(65525)}},
            {"h0 <- inline 65525", ins("h0"), [12, x(65525)], {lee("h0", 12), x(65525)}},
            {"varchar(100) <- inline 65535", ins("v"), [13, x(65535)], ninguna}
        ],
        Blob = [
            {"h0 <- blob 65536", ins("h0"), [20, x(65536)], {lee("h0", 20), x(65536)}},
            {"h1 <- blob 70000", ins("h1"), [21, x(70000)], {lee("h1", 21), x(70000)}},
            {"h0,h1 <- inline 65520 + blob 65536", <<"insert into t (id, h0, h1) values (?, ?, ?)">>, [22, x(65520), x(65536)], {lee("h1", 22), x(65536)}}
        ],
        Casos = case ConBlob of true -> Blob ++ Base; false -> Base end,
        lists:foreach(fun(Caso) -> caso(Db, Caso) end, Casos)
    end}.
