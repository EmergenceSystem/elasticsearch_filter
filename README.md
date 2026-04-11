# elasticsearch_filter

[![License: Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE.md)

Erlang library for building [Emergence](https://github.com/EmergenceSystem) filter agents that search Elasticsearch.

`elasticsearch_filter` is an intermediate library — it provides `handle/2` and `base_capabilities/0` for use in agent wrappers. It does not register any agent itself.

---

## How it works

```
 ┌─────────────┐    WebSocket     ┌──────────────────────┐    HTTP/S    ┌──────────────┐
 │  em_disco   │ ◄─────────────── │  your_agent_app      │ ───────────► │Elasticsearch │
 │  (broker)   │  query / result  │  uses this lib       │  REST API    │  cluster(s)  │
 └─────────────┘                  └──────────────────────┘              └──────────────┘
                                           │
                                  fan-out per cluster
                                           │
                                  ┌────────┴────────┐
                                  │ elasticsearch_  │
                                  │ filter_app      │
                                  └─────────────────┘
```

On each query, the library fans out across all configured clusters and indices in parallel, maps ES hits to Emergence embryos, and returns the merged list.

---

## Requirements

Erlang/OTP 26+ and rebar3.

Add to your `rebar.config`:

```erlang
{deps, [
    {elasticsearch_filter, "0.1.0"}
]}.
```

---

## Quick start

```erlang
-module(my_elastic_agent_app).
-behaviour(application).
-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    em_filter:start_agent(my_elastic_agent, elasticsearch_filter_app, #{
        capabilities => elasticsearch_filter_app:base_capabilities()
                        ++ [<<"my_domain">>, <<"docs">>]
    }),
    {ok, self()}.

stop(_State) ->
    em_filter:stop_agent(my_elastic_agent).
```

Place `elastic_config.json` in the working directory — see [Configuration](#configuration).

---

## The Filter interface

```erlang
handle(Body :: binary(), Memory :: map()) -> {[Embryo], Memory}
base_capabilities() -> [binary()]
```

`handle/2` is called for every `query` frame from `em_disco`.
- `Body` — raw query string (e.g. `<<"erlang otp">>`) or ES query syntax (e.g. `<<"title:erlang AND date:[2024 TO *]">>`)
- `Memory` — unused (stateless); returned unchanged

### Query auto-detection

| Input | Strategy |
|-------|----------|
| Plain text: `"erlang otp"` | `multi_match` with fuzziness across configured fields |
| ES syntax: `"title:erlang"`, `"a AND b"`, `"date:[2024 TO *]"` | `query_string` passed as-is to Elasticsearch |

### Result format

Each hit is mapped to an Emergence embryo:

| `embryo_type` | Embryo type | Required ES fields |
|---------------|-------------|-------------------|
| `"url"` (default) | `url` | `url_field`, `title_field`, `resume_field` |
| `"text"` | `text` | `content_field` |

---

## Configuration

### `elastic_config.json`

```json
{
  "clusters": [
    {
      "url": "https://my-cluster.es.example.com:9200",
      "auth": {
        "type": "api_key",
        "key": "your_encoded_api_key"
      },
      "indices": [
        {
          "name": "articles",
          "search_fields": ["title", "body", "tags"],
          "url_field":    "url",
          "title_field":  "title",
          "resume_field": "body"
        },
        {
          "name": "logs",
          "embryo_type":   "text",
          "search_fields": ["message", "service"],
          "content_field": "message"
        }
      ]
    }
  ],
  "timeout": 10,
  "result_size": 10
}
```

### Authentication

| `auth.type` | Required fields | Header sent |
|-------------|-----------------|-------------|
| `"api_key"` | `key` (pre-encoded Elastic API key) | `Authorization: ApiKey <key>` |
| `"basic"` | `username`, `password` | `Authorization: Basic <base64(user:pass)>` |
| _(absent)_ | — | No auth header |

### Index options

| Key | Default | Description |
|-----|---------|-------------|
| `name` | — | Elasticsearch index name (required) |
| `search_fields` | `["title", "body"]` | Fields searched by `multi_match` |
| `embryo_type` | `"url"` | `"url"` or `"text"` |
| `url_field` | `"url"` | ES field mapped to `url` property |
| `title_field` | `"title"` | ES field mapped to `title` property |
| `resume_field` | `"body"` | ES field mapped to `resume` property (truncated at 300 chars) |
| `content_field` | `"content"` | ES field mapped to `content` property (text embryo only) |

### Top-level options

| Key | Default | Description |
|-----|---------|-------------|
| `timeout` | `10` | Per-query timeout in seconds |
| `result_size` | `10` | Max hits per index (`_search` `size`) |

---

## Multi-cluster

The library fans out across all clusters in parallel using `spawn`. Each cluster is searched independently and results are merged. Clusters that timeout or error return an empty list — they never block the other clusters.

---

## License

[Apache-2.0](LICENSE.md)
