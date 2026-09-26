# howdy openapi example

The user API from `examples/simple`, written with `howdy_openapi`: every
endpoint reads its inputs through schemas, and the app serves the OpenAPI
documents built from them. It has two API versions, chosen by the path:
v2 changes only the user list, and falls back to v1 for everything else.

```sh
cd examples/openapi
gleam run
```

Then open <http://localhost:8787/docs> for the API reference, or fetch the
document itself:

```sh
curl http://localhost:8787/openapi.json          # v1, the default version
curl http://localhost:8787/openapi/v2.json
curl http://localhost:8787/user?min_age=30          # v1
curl http://localhost:8787/v2/user?min_age=30       # v2 wraps the list
curl -X POST http://localhost:8787/user -d '{"name":"Linus","email":"linus@example.com","age":28}'
curl -i -X POST http://localhost:8787/user -d '{"name":" ","email":"nope","age":"5"}'   # 422 listing every field
curl -i http://localhost:8787/user/abc                                                    # 400
curl -i -X DELETE http://localhost:8787/user/2 -H 'x-api-key: secret'                     # 204
```

Or run the same requests as tests, without a server:

```sh
gleam test
```
