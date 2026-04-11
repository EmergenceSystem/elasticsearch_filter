%%%-------------------------------------------------------------------
%%% @doc Elasticsearch search library for Emergence filter agents.
%%%
%%% Not an OTP application — no start/stop. Use as a dependency:
%%%
%%%   em_filter:start_agent(my_agent, elasticsearch_filter_app, #{
%%%       capabilities => elasticsearch_filter_app:base_capabilities()
%%%                       ++ [<<"my_domain">>]
%%%   })
%%%
%%% Config file: elastic_config.json (in working directory).
%%% See elastic_config.json.sample for the full format.
%%%
%%% Handler contract: handle/2 (Body, Memory) -> {Results, Memory}.
%%% @end
%%%-------------------------------------------------------------------
-module(elasticsearch_filter_app).

-export([handle/2, base_capabilities/0]).

%% Exported for testing
-export([detect_query_type/1, auth_headers/1, map_hit/2, build_query/3]).

-define(DEFAULT_TIMEOUT, 10).
-define(DEFAULT_SIZE,    10).

%%====================================================================
%% Public API
%%====================================================================

-spec base_capabilities() -> [binary()].
base_capabilities() ->
    em_filter:base_capabilities() ++ [<<"elasticsearch">>, <<"elastic">>].

-spec handle(binary() | term(), map()) -> {list(), map()}.
handle(Body, Memory) when is_binary(Body) ->
    {search(Body), Memory};
handle(_Body, Memory) ->
    {[], Memory}.

%%====================================================================
%% Search — fan out across clusters and indices
%%====================================================================

search(QueryBin) ->
    Config   = read_config(),
    Clusters = maps:get(<<"clusters">>,    Config, []),
    Timeout  = maps:get(<<"timeout">>,     Config, ?DEFAULT_TIMEOUT),
    Size     = maps:get(<<"result_size">>, Config, ?DEFAULT_SIZE),
    Parent   = self(),
    Pids = [spawn(fun() ->
        Parent ! {result, search_cluster(Cluster, QueryBin, Timeout, Size)}
    end) || Cluster <- Clusters],
    DeadlineMs = erlang:system_time(millisecond) + Timeout * 1000,
    lists:flatmap(fun(_) ->
        Remaining = max(0, DeadlineMs - erlang:system_time(millisecond)),
        receive
            {result, Results} -> Results
        after Remaining -> []
        end
    end, Pids).

search_cluster(Cluster, QueryBin, Timeout, Size) ->
    BaseUrl = binary_to_list(maps:get(<<"url">>, Cluster, <<"http://localhost:9200">>)),
    Auth    = maps:get(<<"auth">>,    Cluster, #{}),
    Indices = maps:get(<<"indices">>, Cluster, []),
    Headers = auth_headers(Auth),
    lists:flatmap(fun(Index) ->
        search_index(BaseUrl, Headers, Index, QueryBin, Timeout, Size)
    end, Indices).

search_index(BaseUrl, Headers, Index, QueryBin, TimeoutSecs, Size) ->
    Name    = binary_to_list(maps:get(<<"name">>, Index)),
    Fields  = maps:get(<<"search_fields">>, Index, [<<"title">>, <<"body">>]),
    Url     = BaseUrl ++ "/" ++ Name ++ "/_search",
    Body    = build_query(binary_to_list(QueryBin), Fields, Size),
    BodyWithSource = Body#{<<"_source">> => source_fields(Index)},
    Payload = binary_to_list(json:encode(BodyWithSource)),
    AllHeaders = Headers ++ [{"Content-Type", "application/json"},
                             {"Accept",       "application/json"}],
    case httpc:request(post,
            {Url, AllHeaders, "application/json", Payload},
            [{timeout, TimeoutSecs * 1000}],
            [{body_format, binary}]) of
        {ok, {{_, 200, _}, _, RespBody}} ->
            try json:decode(RespBody) of
                #{<<"hits">> := #{<<"hits">> := Hits}} ->
                    lists:filtermap(fun(Hit) -> map_hit(Hit, Index) end, Hits);
                _ ->
                    []
            catch _:_ -> [] end;
        _ ->
            []
    end.

%%====================================================================
%% Query building
%%====================================================================

%% @doc Build an ES query map.
%% Uses query_string when the input looks like ES syntax (field:val,
%% boolean operators, range brackets), multi_match otherwise.
-spec build_query(string(), [binary()], pos_integer()) -> map().
build_query(Query, Fields, Size) ->
    EsQuery = case detect_query_type(Query) of
        query_string ->
            #{<<"query_string">> => #{<<"query">> => list_to_binary(Query)}};
        multi_match ->
            #{<<"multi_match">> => #{
                <<"query">>     => list_to_binary(Query),
                <<"fields">>    => Fields,
                <<"type">>      => <<"best_fields">>,
                <<"fuzziness">> => <<"AUTO">>
            }}
    end,
    #{<<"query">> => EsQuery, <<"size">> => Size}.

%% @doc Heuristic: query_string if input contains ES-specific syntax.
-spec detect_query_type(string()) -> multi_match | query_string.
detect_query_type(Query) ->
    HasFieldColon = re:run(Query, "\\w+:",        [{capture, none}]) =:= match,
    HasBoolOp     = re:run(Query, "\\b(AND|OR|NOT)\\b", [{capture, none}]) =:= match,
    HasRange      = re:run(Query, "[\\[\\{]",     [{capture, none}]) =:= match,
    case HasFieldColon orelse HasBoolOp orelse HasRange of
        true  -> query_string;
        false -> multi_match
    end.

%%====================================================================
%% Result mapping
%%====================================================================

source_fields(Index) ->
    case maps:get(<<"embryo_type">>, Index, <<"url">>) of
        <<"text">> ->
            [maps:get(<<"content_field">>, Index, <<"content">>)];
        _ ->
            [maps:get(<<"url_field">>,    Index, <<"url">>),
             maps:get(<<"title_field">>,  Index, <<"title">>),
             maps:get(<<"resume_field">>, Index, <<"body">>)]
    end.

%% @doc Map a single ES hit to an Emergence embryo.
%% Returns false to filter out hits with missing required fields.
-spec map_hit(map(), map()) -> {true, map()} | false.
map_hit(#{<<"_source">> := Source}, Index) ->
    case maps:get(<<"embryo_type">>, Index, <<"url">>) of
        <<"text">> ->
            Field   = maps:get(<<"content_field">>, Index, <<"content">>),
            Content = maps:get(Field, Source, <<>>),
            case Content of
                <<>> -> false;
                _    -> {true, #{<<"type">>       => <<"text">>,
                                 <<"properties">> => #{<<"content">> => Content}}}
            end;
        _ ->
            Url   = maps:get(maps:get(<<"url_field">>,    Index, <<"url">>),   Source, <<>>),
            Title = maps:get(maps:get(<<"title_field">>,  Index, <<"title">>), Source, <<>>),
            Raw   = maps:get(maps:get(<<"resume_field">>, Index, <<"body">>),  Source, <<>>),
            Resume = binary:part(Raw, 0, min(300, byte_size(Raw))),
            case Url of
                <<>> -> false;
                _    -> {true, #{<<"type">>       => <<"url">>,
                                 <<"properties">> => #{
                                     <<"url">>    => Url,
                                     <<"title">>  => Title,
                                     <<"resume">> => Resume
                                 }}}
            end
    end;
map_hit(_, _) ->
    false.

%%====================================================================
%% Authentication
%%====================================================================

%% @doc Build Authorization header for API key or basic auth.
%% API key is passed as-is (Elastic returns it pre-encoded).
%% Basic auth encodes username:password in base64.
-spec auth_headers(map()) -> [{string(), string()}].
auth_headers(#{<<"type">> := <<"api_key">>, <<"key">> := Key}) ->
    [{"Authorization", "ApiKey " ++ binary_to_list(Key)}];
auth_headers(#{<<"type">> := <<"basic">>,
               <<"username">> := User,
               <<"password">> := Pass}) ->
    Encoded = base64:encode(<<User/binary, ":", Pass/binary>>),
    [{"Authorization", "Basic " ++ binary_to_list(Encoded)}];
auth_headers(_) ->
    [].

%%====================================================================
%% Config
%%====================================================================

read_config() ->
    case file:read_file("elastic_config.json") of
        {ok, Bin} ->
            try json:decode(Bin) of
                Map when is_map(Map) -> Map;
                _                   -> #{}
            catch _:_ -> #{} end;
        _ ->
            #{}
    end.
