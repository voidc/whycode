open Util
open Why3
open Whycode.Notifications
open Whycode.Why3_api
open Controller_itp

let warn loc message =
  Lsp.Types.Diagnostic.create () ~range:(loc_to_range loc) ~severity:Warning ~source:"Why3" ~message

let error loc message =
  Lsp.Types.Diagnostic.create () ~range:(loc_to_range loc) ~severity:Error ~source:"Why3" ~message
(* TODO
   1. Kill whole server when one of the various async tasks dies
   2. Reduce the need to spawn as much?
*)

open Linol_lwt

let log_info n msg = n#send_log_msg ~type_:MessageType.Info msg

(* TODO: An Lwt Scheduler *)
(* module S = Unix_scheduler.Unix_scheduler *)

(* Custom strategy runner with a final callback *)

module SessionManager = struct
  type manager = {
    path_to_id : (string, string) Hashtbl.t;
    id_to_controller : (string, controller) Hashtbl.t;
  }

  let create () : manager = { path_to_id = Hashtbl.create 32; id_to_controller = Hashtbl.create 32 }

  let find_or_create_controller (m : manager) config env (id : string) : controller =
    try
      let session = Hashtbl.find m.path_to_id id in
      Hashtbl.find m.id_to_controller session
    with Not_found ->
      let files = Queue.create () in
      Queue.push id files;
      let dir = Server_utils.get_session_dir ~allow_mkdir:true files in
      let ses = Session_itp.load_session dir in
      let cont = Controller_itp.create_controller config env ses in
      Server_utils.load_strategies cont;
      (* HACK: add mlcfg *)
      let why_file =
        if Filename.check_suffix id "rs" then Filename.chop_suffix id "rs" ^ "mlcfg" else id
      in
      add_file_to_session cont why_file;

      Hashtbl.replace m.path_to_id id dir;
      Hashtbl.replace m.id_to_controller dir cont;
      cont

  let find_controller (m : manager) id : controller =
    let session = Hashtbl.find m.path_to_id id in
    Hashtbl.find m.id_to_controller session
end

let relativize session_dir f =
  let f = if Filename.is_relative f then Filename.concat session_dir f else f in
  let path = Sysutil.relativize_filename session_dir f in
  let g = Sysutil.system_dependent_absolute_path session_dir path in
  g

let get_goal_loc (task : Task.task) : Loc.position =
  let location = try (Task.task_goal_fmla task).t_loc with Task.GoalNotFound -> None in
  let location =
    match location with Some l -> l | None -> Option.get (Task.task_goal task).pr_name.id_loc
  in

  location

let unproved_leaf_nodes (c : controller) : Session_itp.proofNodeID list =
  let open Session_itp in
  let session = c.controller_session in
  Session_itp.fold_all_session session
    (fun acc any ->
      match any with
      | Session_itp.APn id ->
          if get_transformations session id = [] && not (pn_proved session id) then id :: acc
          else acc
      | _ -> acc)
    []

let gather_diagnostics_list (c : controller) : (string, Diagnostic.t list) Hashtbl.t =
  let open Session_itp in
  let session = c.controller_session in
  let tbl = Hashtbl.create 17 in
  List.iter
    (fun id ->
      let task = get_task session id in
      let location = get_goal_loc task in
      let file, _, _, _, _ = Loc.get location in
      let file = relativize (get_dir session) file in
      let msg = get_proof_expl session id in
      let msg = if msg = "" then
        (get_proof_name session id).id_string
      else msg in
      let diag = error location msg in
      let old = Option.value ~default:[] (Hashtbl.find_opt tbl file) in
      Hashtbl.replace tbl file (diag :: old))
    (unproved_leaf_nodes c);
  tbl

let find_unproved_nodes_at (c : controller) (rng : Range.t) : Session_itp.proofNodeID list =
  let open Session_itp in
  let session = c.controller_session in

  List.filter
    (fun id ->
      if not (pn_proved session id) then
        let task = get_task session id in
        let location = get_goal_loc task in
        let _, l1, c1, l2, c2 = Loc.get location in
        rng.start.line + 1 = l1
        && rng.end_.line + 1 = l2
        && c1 <= rng.start.character && rng.end_.character <= c2
      else false)
    (unproved_leaf_nodes c)

(* Publish a batch of diagnostics for a set of files *)
let send_all_diags (notify_back : Jsonrpc2.notify_back)
    (diags : (string, Diagnostic.t list) Hashtbl.t) =
  let* _ =
    log_info notify_back
      (Format.asprintf "sending %d tasks"
         (Hashtbl.fold (fun _ l acc -> acc + List.length l) diags 0))
  in
  Hashtbl.fold
    (fun file diags lwt ->
      notify_back#set_uri (DocumentUri.of_path file);
      Lwt.( <&> ) lwt (notify_back#send_diagnostic diags))
    diags Lwt.return_unit

class why_lsp_server () =
  let cli_opts = [] in
  let usage_str = "" in
  let config', env' = Whyconf.Args.initialize cli_opts (fun _ -> ()) usage_str in
  let _ = Controller_itp.set_session_max_tasks (Whyconf.running_provers_max (Whyconf.get_main config')) in

  object (self)
    inherit Linol_lwt.Jsonrpc2.server
    val mutable config = config'
    val mutable env = env'
    val manager = SessionManager.create ()

    (* A set of files for which we have outstanding diagnostics *)
    val mutable outstanding_diag : (string, unit) Hashtbl.t = Hashtbl.create 17
    method! private config_code_action_provider = `CodeActionOptions (CodeActionOptions.create ())

    method private _on_doc ~(notify_back : Linol_lwt.Jsonrpc2.notify_back)
        (uri : Lsp.Types.DocumentUri.t) (_contents : string) =
      try
        let cont = SessionManager.find_controller manager (DocumentUri.to_path uri) in
        let _, _ = Controller_itp.reload_files cont in
        self#publish_diagnostics notify_back (gather_diagnostics_list cont)
      with
      | Controller_itp.Errors_list _ ->
          notify_back#send_diagnostic
            [
              Lsp.Types.Diagnostic.create ()
                ~range:
                  (Range.create
                     ~start:(Position.create ~line:0 ~character:0)
                     ~end_:(Position.create ~line:0 ~character:0))
                ~severity:Error ~source:"Why3" ~message:"An error occured";
            ]
      | Not_found -> return ()

    method on_notif_doc_did_open ~notify_back d ~content = self#_on_doc ~notify_back d.uri content

    method on_notif_doc_did_change ~notify_back d _c ~old_content:_old ~new_content =
      self#_on_doc ~notify_back d.uri new_content

    (* TODO: keey a mapping of which files are related to which sessions and use that here *)
    method on_notif_doc_did_close ~notify_back:_ _ = return ()

    method! on_req_code_action ~notify_back:_ ~id:_ c =
      try
        let cont =
          SessionManager.find_controller manager (DocumentUri.to_path c.textDocument.uri)
        in
        let ids = find_unproved_nodes_at cont c.range in

        let open Wstdlib in
        let mk_command trans id =
          Command.create ~title:trans ~command:"whycode.run_transformation"
            ~arguments:
              [ DocumentUri.yojson_of_t c.textDocument.uri; Range.yojson_of_t id; `String trans ]
            ()
        in
        if List.length ids > 0 then
          let s = cont.controller_strategies in
          let actions =
            [
              `Command
                (Command.create ~title:"Show Task" ~command:"whycode.show_task"
                   ~arguments:
                     [ DocumentUri.yojson_of_t c.textDocument.uri; Range.yojson_of_t c.range ]
                   ());
            ]
          in
          let actions =
            Hstr.fold (fun s _ acc -> `Command (mk_command s c.range) :: acc) s actions
          in
          return (Some actions)
        else return None
      with Not_found -> return None

    method private on_start_proof_notif ~notify_back (n : StartProofNotification.t) =
      let cont =
        SessionManager.find_or_create_controller manager config env (DocumentUri.to_path n.uri)
      in
      let _, _ = Controller_itp.reload_files cont in
      self#publish_diagnostics notify_back (gather_diagnostics_list cont)

    method private on_run_command_req ~notify_back (n : RunTransformationRequest.t)
        : Yojson.Safe.t t =
      try
        let open Wstdlib in
        let* _ = log_info notify_back "Running command" in
        let cont = SessionManager.find_controller manager (DocumentUri.to_path n.uri) in

        let* _, _, _, strat =
          try return (Hstr.find cont.controller_strategies n.command)
          with Not_found -> failwith (Format.sprintf "Could not find strategy: %s" n.command)
        in
        let ids =
          match n.target with
          | `Range r -> find_unproved_nodes_at cont r
          | `Node i -> [ Obj.magic i ]
        in
        let ids =
          List.map
            (fun id ->
              let promise, resolver = Lwt.wait () in
              ((id, resolver), promise))
            ids
        in
        let ids, promises = List.split ids in
        List.iter
          (fun (id, resolver) ->
            run_strategy_on_goal cont id
              (* EVIL EVIL EVIL: Use a hashmap to convert from proofNodeID to int (sadly, probably just the identity function but oh well *)
              strat
              ~notification:(fun _ -> ())
              ~finalize:(fun _ -> Lwt.wakeup resolver ()))
          ids;

        let* _ = log_info notify_back "Waiting on..." in
        let* _ = Lwt.join promises in
        let* _ = log_info notify_back "Done running!" in

        let* _ = self#publish_diagnostics notify_back (gather_diagnostics_list cont) in

        return `Null
      with Not_found -> return `Null

    method private on_did_save_notif ~notify_back (n : DidSaveTextDocumentParams.t) =
      try
        let cont =
          SessionManager.find_controller manager (DocumentUri.to_path n.textDocument.uri)
        in
        let* _ = log_info notify_back "Saving session" in
        Session_itp.save_session cont.controller_session;
        return ()
      with Not_found -> return ()


    method private publish_diagnostics notify (diags : (string, Diagnostic.t list) Hashtbl.t) =
      (* Figure out if we had diagnostics for a file which we no longer have any for *)
      let cleared =
        Hashtbl.fold
          (fun s _ acc -> if not (Hashtbl.mem diags s) then s :: acc else acc)
          outstanding_diag []
      in
      (* diags = outstanding *)
      let outstanding = Hashtbl.of_seq (Hashtbl.to_seq diags |> Seq.map (fun (s, _) -> (s, ()))) in

      (* Clear diagnostics for any files which have been solved *)
      let* _ =
        send_all_diags notify (List.map (fun s -> (s, [])) cleared |> List.to_seq |> Hashtbl.of_seq)
      in
      (* Send the outstanding diagnostics *)
      let* _ = send_all_diags notify diags in
      outstanding_diag <- outstanding;
      return ()

    method private on_reset_session ~notify_back (reset : ResetSessionNotification.t) =
      try
        let cont = SessionManager.find_controller manager (DocumentUri.to_path reset.uri) in
        C.reset_proofs cont ~notification:(fun _ -> ()) ~removed:(fun _ -> ()) None;
        let* _ = self#publish_diagnostics notify_back (gather_diagnostics_list cont) in
        return `Null
      with Not_found -> return `Null

    method private on_reload_session ~notify_back (reset : ReloadSessionNotification.t) =
      try
        let cont = SessionManager.find_controller manager (DocumentUri.to_path reset.uri) in
        let _, _ = Controller_itp.reload_files cont in
        let* _ = self#publish_diagnostics notify_back (gather_diagnostics_list cont) in
        return ()
      with Not_found -> return ()

    method private on_replay_session ~notify_back (reset : ReplaySessionNotification.t) =
      try
        let cont = SessionManager.find_controller manager (DocumentUri.to_path reset.uri) in
        C.replay ~valid_only:true ~obsolete_only:true cont
          ~callback:(fun _ _ -> ())
          ~notification:(fun _ -> ())
          ~final_callback:(fun _ _ -> ())
          ~any:None;
        let* _ = self#publish_diagnostics notify_back (gather_diagnostics_list cont) in
        return ()
      with Not_found -> return ()

    method private on_show_task ~notify_back:_ (req : ShowTaskRequest.t) =
      let cont = SessionManager.find_controller manager (DocumentUri.to_path req.uri) in
      let ids =
        match req.target with
        | `Node i -> [ Obj.magic i ]
        | `Range r -> find_unproved_nodes_at cont r
      in
      let task, tables = Session_itp.get_task_name_table cont.controller_session (List.hd ids) in
      let str = string_of_task task tables in
      return (`String str)

    method private on_unknown_request ~(notify_back : Jsonrpc2.notify_back) ~id:_ name req
        : Yojson.Safe.t t =
      let open Lsp.Import in
      let open Lwt.Infix in
      let parse f p =
        let params = Json.read_json_params f (Option.get p) |> Result.join in
        match params with Error e -> failwith e | Ok p -> return p
      in
      match name with
      | "proof/runTransformation" -> begin
          let params = parse RunTransformationRequest.of_yojson req in
          params >>= self#on_run_command_req ~notify_back
        end
      | "proof/resetSession" -> begin
          let params = parse ResetSessionNotification.of_yojson req in
          params >>= self#on_reset_session ~notify_back
        end
      | "proof/showTask" -> begin
          let params = parse ShowTaskRequest.of_yojson req in
          params >>= self#on_show_task ~notify_back
        end
      | _ -> failwith "Unhandled custom request"

    method private on_unknown_notification ~notify_back (notif : Jsonrpc.Notification.t) =
      let open Lsp.Import in
      let open Lwt.Infix in
      let parse f (p : Jsonrpc.Notification.t) =
        let a = Json.message_params p.params f |> Result.join in
        match a with Error e -> failwith e | Ok p -> return p
      in
      match notif.method_ with
      | "proof/start" ->
          let params = parse StartProofNotification.of_yojson notif in
          params >>= self#on_start_proof_notif ~notify_back
      | "proof/reloadSession" -> begin
          let params = parse ReloadSessionNotification.of_yojson notif in
          params >>= self#on_reload_session ~notify_back
        end
      | "proof/replaySession" -> begin
          let params = parse ReplaySessionNotification.of_yojson notif in
          params >>= self#on_replay_session ~notify_back
        end
      | _ -> return ()

    method! on_request_unhandled (type r) ~(notify_back : Jsonrpc2.notify_back)
        ~(id : Linol.Server.Req_id.t) (req : r Lsp.Client_request.t) : r t =
      match req with
      | Lsp.Client_request.UnknownRequest r ->
          self#on_unknown_request ~notify_back ~id r.meth r.params
      | _ -> assert false

    method! on_notification_unhandled ~notify_back notif =
      match notif with
      | Lsp.Client_notification.DidSaveTextDocument n -> self#on_did_save_notif ~notify_back n
      | Lsp.Client_notification.UnknownNotification n -> self#on_unknown_notification ~notify_back n
      | _ -> return ()
  end
