-module(elasticsearch_filter_test).
-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% detect_query_type/1
%%====================================================================

detect_simple_test() ->
    ?assertEqual(multi_match, elasticsearch_filter_app:detect_query_type("erlang otp")).

detect_field_colon_test() ->
    ?assertEqual(query_string, elasticsearch_filter_app:detect_query_type("title:erlang")).

detect_and_operator_test() ->
    ?assertEqual(query_string, elasticsearch_filter_app:detect_query_type("erlang AND otp")).

detect_or_operator_test() ->
    ?assertEqual(query_string, elasticsearch_filter_app:detect_query_type("erlang OR elixir")).

detect_not_operator_test() ->
    ?assertEqual(query_string, elasticsearch_filter_app:detect_query_type("erlang NOT java")).

detect_range_test() ->
    ?assertEqual(query_string, elasticsearch_filter_app:detect_query_type("date:[2024 TO *]")).

detect_plain_phrase_test() ->
    ?assertEqual(multi_match, elasticsearch_filter_app:detect_query_type("distributed systems")).

%%====================================================================
%% auth_headers/1
%%====================================================================

auth_api_key_test() ->
    Headers = elasticsearch_filter_app:auth_headers(
        #{<<"type">> => <<"api_key">>, <<"key">> => <<"mykey123">>}),
    ?assertEqual([{"Authorization", "ApiKey mykey123"}], Headers).

auth_basic_test() ->
    Headers = elasticsearch_filter_app:auth_headers(
        #{<<"type">>     => <<"basic">>,
          <<"username">> => <<"user">>,
          <<"password">> => <<"pass">>}),
    Encoded = binary_to_list(base64:encode(<<"user:pass">>)),
    ?assertEqual([{"Authorization", "Basic " ++ Encoded}], Headers).

auth_none_test() ->
    ?assertEqual([], elasticsearch_filter_app:auth_headers(#{})).

auth_unknown_type_test() ->
    ?assertEqual([], elasticsearch_filter_app:auth_headers(#{<<"type">> => <<"other">>})).

%%====================================================================
%% build_query/3
%%====================================================================

build_query_multi_match_test() ->
    Q = elasticsearch_filter_app:build_query("erlang", [<<"title">>, <<"body">>], 10),
    ?assertMatch(#{<<"query">> := #{<<"multi_match">> := _}, <<"size">> := 10}, Q).

build_query_query_string_test() ->
    Q = elasticsearch_filter_app:build_query("title:erlang", [<<"title">>], 5),
    ?assertMatch(#{<<"query">> := #{<<"query_string">> := _}, <<"size">> := 5}, Q).

%%====================================================================
%% map_hit/2
%%====================================================================

map_hit_url_test() ->
    Index = #{},
    Hit   = #{<<"_source">> => #{
        <<"url">>   => <<"https://example.com">>,
        <<"title">> => <<"Erlang OTP">>,
        <<"body">>  => <<"Some content here">>
    }},
    {true, Result} = elasticsearch_filter_app:map_hit(Hit, Index),
    ?assertEqual(<<"url">>, maps:get(<<"type">>, Result)),
    Props = maps:get(<<"properties">>, Result),
    ?assertEqual(<<"https://example.com">>, maps:get(<<"url">>,   Props)),
    ?assertEqual(<<"Erlang OTP">>,          maps:get(<<"title">>, Props)).

map_hit_url_custom_fields_test() ->
    Index = #{<<"url_field">>   => <<"link">>,
              <<"title_field">> => <<"headline">>,
              <<"resume_field">> => <<"summary">>},
    Hit = #{<<"_source">> => #{
        <<"link">>     => <<"https://custom.com">>,
        <<"headline">> => <<"Custom Title">>,
        <<"summary">>  => <<"Custom summary">>
    }},
    {true, Result} = elasticsearch_filter_app:map_hit(Hit, Index),
    Props = maps:get(<<"properties">>, Result),
    ?assertEqual(<<"https://custom.com">>, maps:get(<<"url">>,   Props)),
    ?assertEqual(<<"Custom Title">>,       maps:get(<<"title">>, Props)).

map_hit_missing_url_test() ->
    Index = #{},
    Hit   = #{<<"_source">> => #{<<"title">> => <<"No URL here">>}},
    ?assertEqual(false, elasticsearch_filter_app:map_hit(Hit, Index)).

map_hit_text_type_test() ->
    Index = #{<<"embryo_type">>   => <<"text">>,
              <<"content_field">> => <<"message">>},
    Hit   = #{<<"_source">> => #{<<"message">> => <<"log line content">>}},
    {true, Result} = elasticsearch_filter_app:map_hit(Hit, Index),
    ?assertEqual(<<"text">>, maps:get(<<"type">>, Result)),
    Props = maps:get(<<"properties">>, Result),
    ?assertEqual(<<"log line content">>, maps:get(<<"content">>, Props)).

map_hit_text_empty_content_test() ->
    Index = #{<<"embryo_type">> => <<"text">>},
    Hit   = #{<<"_source">> => #{<<"content">> => <<>>}},
    ?assertEqual(false, elasticsearch_filter_app:map_hit(Hit, Index)).

map_hit_no_source_test() ->
    ?assertEqual(false, elasticsearch_filter_app:map_hit(#{<<"_id">> => <<"1">>}, #{})).

map_hit_resume_truncated_test() ->
    LongText = binary:copy(<<"x">>, 500),
    Index = #{},
    Hit   = #{<<"_source">> => #{
        <<"url">>  => <<"https://example.com">>,
        <<"body">> => LongText
    }},
    {true, Result} = elasticsearch_filter_app:map_hit(Hit, Index),
    Props  = maps:get(<<"properties">>, Result),
    Resume = maps:get(<<"resume">>, Props),
    ?assertEqual(300, byte_size(Resume)).
