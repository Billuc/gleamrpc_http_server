# gleamrpc_http_server

[![Package Version](https://img.shields.io/hexpm/v/gleamrpc_http_server)](https://hex.pm/packages/gleamrpc_http_server)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/gleamrpc_http_server/)

**HTTP server for GleamRPC**

Receive your GleamRPC procedures via HTTP. Should be used with [gleamrpc_http_client](https://hexdocs.pm/gleamrpc_http_client).

Query data is sent in the request query while the Mutation's data is sent in the body in Json.

This package uses Mist under the hood.

## Installation

```sh
gleam add gleamrpc_http_server@1
```

## Usage

```gleam
import gleamrpc/http/server as rpchttp
import gleamrpc
import mist

pub fn main() {
  gleamrpc.with_server(rpchttp.http_server())
  |> gleamrpc.with_context(create_context)
  |> gleamrpc.with_implementation(create_user_procedure, create_user)
  |> gleamrpc.with_implementation(get_user_procedure, get_user)
  |> rpchttp.init_mist(8080)
  |> mist.start_http()
}
```

Further documentation can be found at <https://hexdocs.pm/gleamrpc_http_server>.

## Development

```sh
gleam run   # Run the project
gleam test  # Run the tests
```
