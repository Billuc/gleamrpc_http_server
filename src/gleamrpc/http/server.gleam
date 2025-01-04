import convert
import convert/http/query
import convert/json as cjson
import gleam/bytes_tree
import gleam/dynamic
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/json
import gleam/list
import gleam/option
import gleam/result
import gleam/string
import gleamrpc
import mist

pub type HttpServerError {
  MethodUnsupported(method: http.Method)
  NoNameError
  WrongPrefix(path: String)
}

pub fn http_server() -> gleamrpc.ProcedureServer(
  request.Request(mist.Connection),
  response.Response(mist.ResponseData),
  HttpServerError,
) {
  gleamrpc.ProcedureServer(
    get_identity:,
    get_params:,
    recover_error:,
    encode_result:,
  )
}

fn get_identity(
  in_request: request.Request(_),
) -> Result(
  gleamrpc.ProcedureIdentity,
  gleamrpc.GleamRPCServerError(HttpServerError),
) {
  use type_ <- result.try(extract_procedure_type(in_request))
  use #(name, router) <- result.try(extract_procedure_name_and_router(
    in_request,
  ))
  Ok(gleamrpc.ProcedureIdentity(name, router, type_))
}

fn extract_procedure_type(
  in_request: request.Request(_),
) -> Result(
  gleamrpc.ProcedureType,
  gleamrpc.GleamRPCServerError(HttpServerError),
) {
  case in_request.method {
    http.Get -> Ok(gleamrpc.Query)
    http.Post -> Ok(gleamrpc.Mutation)
    _ as method -> Error(gleamrpc.GetIdentityError(MethodUnsupported(method)))
  }
}

fn extract_procedure_name_and_router(
  in_request: request.Request(_),
) -> Result(
  #(String, option.Option(gleamrpc.Router)),
  gleamrpc.GleamRPCServerError(HttpServerError),
) {
  case in_request |> request.path_segments {
    ["api", "gleamRPC", ..rest] -> build_name_and_router(rest, option.None)
    _ -> Error(gleamrpc.GetIdentityError(WrongPrefix(in_request.path)))
  }
}

fn build_name_and_router(
  segments: List(String),
  router: option.Option(gleamrpc.Router),
) -> Result(
  #(String, option.Option(gleamrpc.Router)),
  gleamrpc.GleamRPCServerError(HttpServerError),
) {
  case segments {
    [name] -> Ok(#(name, router))
    [name, ..rest] -> {
      build_name_and_router(rest, option.Some(gleamrpc.Router(name, router)))
    }
    [] -> Error(gleamrpc.GetIdentityError(NoNameError))
  }
}

fn get_params(
  request: request.Request(mist.Connection),
) -> fn(gleamrpc.ProcedureType, convert.GlitrType) ->
  Result(convert.GlitrValue, gleamrpc.GleamRPCServerError(HttpServerError)) {
  fn(procedure_type: gleamrpc.ProcedureType, params_type: convert.GlitrType) {
    case procedure_type {
      gleamrpc.Mutation -> get_params_mutation(request, params_type)
      gleamrpc.Query -> get_params_query(request, params_type)
    }
  }
}

fn get_params_query(
  request: request.Request(mist.Connection),
  params_type: convert.GlitrType,
) -> Result(convert.GlitrValue, gleamrpc.GleamRPCServerError(HttpServerError)) {
  request.get_query(request)
  |> result.replace_error(
    gleamrpc.GetParamsError([dynamic.DecodeError("A valid query", "", [])]),
  )
  |> result.then(fn(query_value) {
    query_value
    |> query.decode_value(params_type)
    |> result.map_error(gleamrpc.GetParamsError)
  })
}

fn get_params_mutation(
  request: request.Request(mist.Connection),
  params_type: convert.GlitrType,
) -> Result(convert.GlitrValue, gleamrpc.GleamRPCServerError(HttpServerError)) {
  request
  |> mist.read_body(65_000)
  |> result.map_error(mist_read_error_to_get_params_error)
  |> result.then(decode_bit_array_request(_, params_type))
}

fn mist_read_error_to_get_params_error(
  err: mist.ReadError,
) -> gleamrpc.GleamRPCServerError(_) {
  case err {
    mist.ExcessBody ->
      gleamrpc.GetParamsError([
        dynamic.DecodeError("Body size <= 65000", "", []),
      ])
    mist.MalformedBody ->
      gleamrpc.GetParamsError([
        dynamic.DecodeError("A valid body", "Malformed body", []),
      ])
  }
}

fn decode_bit_array_request(
  request: request.Request(BitArray),
  params_type: convert.GlitrType,
) -> Result(convert.GlitrValue, gleamrpc.GleamRPCServerError(HttpServerError)) {
  request.body
  |> json.decode_bits(cjson.decode_value(params_type))
  |> result.map_error(fn(err) {
    case err {
      json.UnableToDecode(decode_err) ->
        decode_err
        |> list.map(fn(err) {
          dynamic.DecodeError(err.expected, err.found, err.path)
        })
        |> gleamrpc.GetParamsError
      json.UnexpectedByte(byte) ->
        gleamrpc.GetParamsError([
          dynamic.DecodeError("A valid JSON", "Unexpected byte : " <> byte, []),
        ])
      json.UnexpectedEndOfInput ->
        gleamrpc.GetParamsError([
          dynamic.DecodeError("A valid JSON", "Unexpected end of input", []),
        ])
      json.UnexpectedFormat(decode_err) -> gleamrpc.GetParamsError(decode_err)
      json.UnexpectedSequence(seq) ->
        gleamrpc.GetParamsError([
          dynamic.DecodeError(
            "A valid JSON",
            "Unexpected sequence : " <> seq,
            [],
          ),
        ])
    }
  })
}

fn recover_error(
  error: gleamrpc.GleamRPCServerError(HttpServerError),
) -> response.Response(mist.ResponseData) {
  case error {
    gleamrpc.GetIdentityError(err) -> recover_http_server_error(err)
    gleamrpc.GetParamsError(errors) -> recover_decode_errors(errors)
    gleamrpc.ProcedureExecError(err) -> response_from_string(500, err.message)
    gleamrpc.WrongProcedure -> response_from_string(404, "Procedure not found")
  }
}

fn recover_http_server_error(
  error: HttpServerError,
) -> response.Response(mist.ResponseData) {
  case error {
    MethodUnsupported(method) ->
      response_from_string(
        405,
        method |> http.method_to_string <> " not allowed",
      )
    NoNameError -> response_from_string(400, "Couldn't extract procedure name")
    WrongPrefix(path) -> response_from_string(400, "Wrong prefix: " <> path)
  }
}

fn recover_decode_errors(
  errors: List(dynamic.DecodeError),
) -> response.Response(mist.ResponseData) {
  errors
  |> list.map(fn(error) {
    "Expected : "
    <> error.expected
    <> ", got : "
    <> error.found
    <> " at "
    <> string.join(error.path, ".")
  })
  |> string.join("\n")
  |> response_from_string(400, _)
}

fn response_from_string(
  response_code: Int,
  body: String,
) -> response.Response(mist.ResponseData) {
  response.Response(
    response_code,
    [],
    mist.Bytes(body |> bytes_tree.from_string),
  )
}

fn encode_result(
  result: convert.GlitrValue,
) -> response.Response(mist.ResponseData) {
  let body =
    cjson.encode_value(result)
    |> json.to_string
    |> bytes_tree.from_string
    |> mist.Bytes

  response.new(200)
  |> response.set_body(body)
}

pub fn start_server(
  server: gleamrpc.ProcedureServerInstance(
    request.Request(mist.Connection),
    response.Response(mist.ResponseData),
    _,
    HttpServerError,
  ),
  port: Int,
) {
  server
  |> gleamrpc.serve()
  |> mist.new()
  |> mist.port(port)
  |> mist.start_http()
}
