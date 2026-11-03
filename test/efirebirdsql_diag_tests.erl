%%% Diagnostic only, never merged: which parameter size closes the connection on Firebird 2.5.
-module(efirebirdsql_diag_tests).

-include_lib("eunit/include/eunit.hrl").

conectar(Db, Crear) ->
    efirebirdsql:connect("localhost", os:getenv("ISC_USER", "sysdba"),
        os:getenv("ISC_PASSWORD", "masterkey"), Db, [{createdb, true} || Crear]).

caso(Db, Id, Nombre, H0, H1) ->
    case conectar(Db, false) of
        {ok, C} ->
            R = (catch efirebirdsql:execute(C,
                <<"insert into t (id, h0, h1) values (?, ?, ?)">>, [Id, H0, H1])),
            Salida = case R of
                ok ->
                    ok = efirebirdsql:execute(C,
                        iolist_to_binary(io_lib:format("select h0, h1 from t where id = ~p", [Id]))),
                    {ok, [{_, L0}, {_, L1}]} = efirebirdsql:fetchone(C),
                    {ok, igual, L0 =:= H0, L1 =:= H1};
                Otro ->
                    Otro
            end,
            catch efirebirdsql:close(C),
            io:format(user, "DIAG ~s: ~p~n", [Nombre, Salida]);
        Otro ->
            io:format(user, "DIAG ~s: sin conexion ~p~n", [Nombre, Otro])
    end.

x(N) -> binary:copy(<<"x">>, N).

diag_test_() ->
    {timeout, 120, fun() ->
        Db = lists:flatten(io_lib:format("/tmp/~p.fdb", [erlang:system_time()])),
        {ok, C0} = conectar(Db, true),
        ok = efirebirdsql:execute(C0, <<"select rdb$get_context('SYSTEM', 'ENGINE_VERSION') from rdb$database">>),
        io:format(user, "DIAG motor: ~p~n", [efirebirdsql:fetchone(C0)]),
        ok = efirebirdsql:execute(C0, <<"CREATE TABLE t (id INTEGER NOT NULL, h0 BLOB SUB_TYPE 0, h1 BLOB SUB_TYPE 1)">>),
        ok = efirebirdsql:commit(C0),
        efirebirdsql:close(C0),
        Casos = [
            {"blob 65536", x(65536), nil},
            {"blob 102400", x(102400), nil},
            {"blob + blob", x(70000), x(70000)},
            {"inline 65500", x(65500), nil},
            {"inline 20000 + inline 20000", x(20000), x(20000)},
            {"inline 32000 + inline 32000", x(32000), x(32000)},
            {"inline 32700 + inline 32700", x(32700), x(32700)},
            {"inline 65510", x(65510), nil},
            {"inline 65520", x(65520), nil},
            {"inline 65525", x(65525), nil},
            {"inline 65530", x(65530), nil},
            {"inline 65533", x(65533), nil},
            {"inline 33000 + inline 33000", x(33000), x(33000)},
            {"inline 40000 + inline 40000", x(40000), x(40000)},
            {"inline 65535", x(65535), nil}
        ],
        lists:foldl(fun({Nombre, H0, H1}, Id) ->
            caso(Db, Id, Nombre, H0, H1),
            Id + 1
        end, 1, Casos)
    end}.
