open Lwt.Infix
open Websocket
open Websocket_lwt_unix

let write_failed_response oc =
  let body = "403 Forbidden" in
  let body_len = String.length body |> Int64.of_int in
  let response = Cohttp.Response.make
      ~status:`Forbidden
      ~encoding:(Cohttp.Transfer.Fixed body_len)
      ()
  in
  let open Response in
  write
    ~flush:true
    (fun writer -> write_body writer body)
    response oc

let section = Lwt_log.Section.make "websocket_lwt_unix"
exception HTTP_Error of string

let set_tcp_nodelay flow =
  let open Conduit_lwt_unix in
  match flow with
  | TCP { fd; _ } -> Lwt_unix.setsockopt fd Lwt_unix.TCP_NODELAY true
  | _ -> ()

module ComparableConnected_client = struct
  let compare _ _ = -1
  include Connected_client
end
module CS = Set.Make(ComparableConnected_client)
let clients = ref CS.empty

let establish_chat_server
    ?read_buf ?write_buf
    ?timeout ?stop
    ?(on_exn=(fun exn -> !Lwt.async_exception_hook exn))
    ?(check_request=check_origin_with_host)
    ?(ctx=Conduit_lwt_unix.default_ctx) ~mode react =
  let module C = Cohttp in
  let server_fun flow ic oc =
    (Request.read ic >>= function
      | `Ok r -> Lwt.return r
      | `Eof ->
        (* Remote endpoint closed connection. No further action necessary here. *)
        Lwt_log.info ~section "Remote endpoint closed connection" >>= fun () ->
        Lwt.fail End_of_file
      | `Invalid reason ->
        Lwt_log.info_f ~section "Invalid input from remote endpoint: %s" reason >>= fun () ->
        Lwt.fail @@ HTTP_Error reason) >>= fun request ->
    let meth    = C.Request.meth request in
    let version = C.Request.version request in
    let headers = C.Request.headers request in
    let key = C.Header.get headers "sec-websocket-key" in
    begin match version, meth, C.Header.get headers "upgrade",
                key, upgrade_present headers, check_request request with
    | `HTTP_1_1, `GET, Some up, Some key, true, true
      when Astring.String.Ascii.lowercase up = "websocket" ->
      Lwt.return key
    | _ ->
      write_failed_response oc >>= fun () ->
      Lwt.fail (Protocol_error "Bad headers")
    end >>= fun key ->
    let hash = key ^ websocket_uuid |> b64_encoded_sha1sum in
    let response_headers = C.Header.of_list
        ["Upgrade", "websocket";
         "Connection", "Upgrade";
         "Sec-WebSocket-Accept", hash] in
    let response = C.Response.make
        ~status:`Switching_protocols
        ~encoding:C.Transfer.Unknown
        ~headers:response_headers () in
    Response.write (fun _writer -> Lwt.return_unit) response oc >>= fun () ->
    let client =
      Connected_client.create ?read_buf ?write_buf request flow ic oc in
    clients := CS.add client !clients;
    react client
  in
  Conduit_lwt_unix.serve ~on_exn ?timeout ?stop ~ctx ~mode begin fun flow ic oc ->
    set_tcp_nodelay flow;
    server_fun (Conduit_lwt_unix.endp_of_flow flow) ic oc
  end

let section = Lwt_log.Section.make "reynir"

let handler id client =
  incr id;
  let id = !id in
  let send = Connected_client.send client in
  let send_all content = Lwt_list.iter_p (fun client -> Connected_client.send client content) (CS.elements !clients) in
  Lwt_log.ign_info_f ~section "New connection (id = %d)" id;
  Lwt.async (fun () ->
      Lwt_unix.sleep 1.0 >>= fun () ->
      send @@ Frame.create ~content:"Delayed message" ()
    );
  let rec recv_forever () =
    let open Frame in
    let react fr =
      Lwt_log.debug_f ~section "<- %s" (Frame.show fr) >>= fun () ->
      match fr.opcode with
      | Opcode.Ping ->
        send @@ Frame.create ~opcode:Opcode.Pong ~content:fr.content ()

      | Opcode.Close ->
        Lwt_log.info_f ~section "Client %d sent a close frame" id >>= fun () ->
        (* Immediately echo and pass this last message to the user *)
        (if String.length fr.content >= 2 then
           send @@ Frame.create ~opcode:Opcode.Close
             ~content:(String.sub fr.content 0 2) ()
         else send @@ Frame.close 1000) >>= fun () ->
        Lwt.fail Exit

      | Opcode.Pong -> Lwt.return_unit

      | Opcode.Text
      | Opcode.Binary -> send_all @@ Frame.create ~content:fr.content ()

      | _ ->
        send @@ Frame.close 1002 >>= fun () ->
        Lwt.fail Exit
    in
    Connected_client.recv client >>= react >>= recv_forever
  in
  Lwt.catch
    recv_forever
    (fun exn ->
       Lwt_log.info_f ~section "Connection to client %d lost" id >>= fun () ->
       Lwt.fail exn)

let main uri =
  Resolver_lwt.resolve_uri ~uri Resolver_lwt_unix.system >>= fun endp ->
  let open Conduit_lwt_unix in
  endp_to_server ~ctx:default_ctx endp >>= fun server ->
  establish_chat_server ~ctx:default_ctx ~mode:server (handler @@ ref (-1))

let () =
  let uri = ref "http://localhost:9001" in

  let speclist = Arg.align
      [
        "-v", Arg.String (fun s -> Lwt_log.(add_rule s Info)), "<section> Put <section> to Info level";
        "-vv", Arg.String (fun s -> Lwt_log.(add_rule s Debug)), "<section> Put <section> to Debug level"
      ]
  in
  let anon_fun s = uri := s in
  let usage_msg = "Usage: " ^ Sys.argv.(0) ^ " <options> uri\nOptions are:" in
  Arg.parse speclist anon_fun usage_msg;

  ignore @@ main @@ Uri.of_string !uri;
  Lwt_main.run (fst (Lwt.wait ()))
