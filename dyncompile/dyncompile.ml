module Options = Options

let output_structure (channel : out_channel) (s : Parsetree.structure) =
  let fmt = Format.formatter_of_out_channel channel in
  Pprintast.structure fmt s;
  Format.pp_print_flush fmt ()

type compiler = {
    command : string;
    archive_option : string;
    archive_suffix : string;
  }

let compiler : compiler =
  if Dynlink.is_native then {
    command = "ocamlopt";
    archive_option = "-shared";
    archive_suffix = ".cmxs";
  }
  else {
    command = "ocamlc";
    archive_option = "-a";
    archive_suffix = ".cma";
  }

let format_process_status fmt (ps : Unix.process_status) =
  match ps with
  | WEXITED return_code ->
      Format.fprintf fmt "return code %d" return_code
  | WSIGNALED signal ->
      Format.fprintf fmt "signal %d" signal
  | WSTOPPED signal ->
      Format.fprintf fmt "stopped %d" signal

let fix_compiler_env env =
  let channels = Unix.open_process_full "as --version" env in
  let (as_stdout, _, as_stderr) = channels in
  let _as_stdout = In_channel.input_all as_stdout in
  let _as_stderr = In_channel.input_all as_stderr in
  match Unix.close_process_full channels with
  | WEXITED 0 -> ()
  | process_status ->
      if not (Sys.file_exists "/usr/bin/as") then
        failwith "No 'as' in /usr/bin!";
      let index, path =
        let exception Result of { index: int; path: string } in
        try
          env |> Array.iteri (fun index path ->
            if String.starts_with ~prefix:"PATH=" path then
              raise (Result { index; path }));
          failwith "No PATH in env"
        with Result { index; path } -> index, path in
      env.(index) <- Printf.sprintf "%s:/usr/bin" path

let rec try_commands ~verbose list =
  match list with
  | [] -> assert false
  | (command, args) :: tl ->
      let command_line = Filename.quote_command command args in
      if verbose then
        prerr_endline command_line;
      let env = Unix.environment () in
      if not Sys.win32 then fix_compiler_env env;
      let channels = Unix.open_process_full command_line env in
      let (compiler_stdout, _, compiler_stderr) = channels in
      let compiler_stdout = In_channel.input_all compiler_stdout in
      let compiler_stderr = In_channel.input_all compiler_stderr in
      match Unix.close_process_full channels with
      | WEXITED 0 -> ()
      | WEXITED 127 when tl <> [] -> try_commands ~verbose tl
      | process_status ->
          Location.raise_errorf ~loc:!Ast_helper.default_loc
            "@[Unable@ to@ compile@ preprocessor:@ command-line@ \"%s\"@ \
              failed@ with@ %a@]@,@[stdout: %s@]@,@[stderr: %s@]."
            (String.escaped command_line) format_process_status
            process_status compiler_stdout compiler_stderr

let compile (options : Options.t) (source_filename : string)
    (object_filename : string) : unit =
  let flags =
    options.flags @
    List.concat_map (fun directory -> ["-I"; directory])
      options.directories @
    ["-I"; "+compiler-libs"; "-w"; "-40"; compiler.archive_option;
      source_filename; "-o"; object_filename] in
  let preutils_cmi = "metapp_preutils.cmi" in
  let api_cmi = "metapp_api.cmi" in
  let dune_preutils_path = "preutils/.metapp_preutils.objs/byte/" in
  let dune_api_path = "api/.metapp_api.objs/byte/" in
  let (flags, packages) =
    if Sys.file_exists preutils_cmi && Sys.file_exists api_cmi then
      (flags, options.packages)
    else if Sys.file_exists (Filename.concat dune_preutils_path preutils_cmi) &&
      Sys.file_exists (Filename.concat dune_api_path api_cmi) then
      (["-I"; dune_preutils_path; "-I"; dune_api_path] @ flags,
        options.packages)
    else
      (flags, ["metapp.preutils"; "metapp.api"] @ options.packages) in
  let commands =
    match packages with
    | [] ->
        [(compiler.command ^ ".opt", flags); (compiler.command, flags)]
    | _ ->
        [("ocamlfind",
          [compiler.command; "-package"; String.concat "," packages] @
          flags)] in
  try_commands ~verbose:options.verbose commands

(* Code taken from pparse.ml (adapted for a channel instead of a filename to use
   open_temp_file), because Pparse.write_ast is introduced in OCaml 4.04.0. *)
let write_ast (plainsource : bool) (channel : out_channel)
    (structure : Parsetree.structure) : unit =
  if plainsource then
    output_structure channel structure
  else
    begin
      output_string channel Config.ast_impl_magic_number;
      output_value channel !Location.input_name;
      output_value channel structure
    end

let compile_and_load (options : Options.t) (structure : Parsetree.structure)
  : unit =
  let (source_filename, channel) =
    Filename.open_temp_file ~mode:[Open_binary] "metapp" ".ml" in
  Fun.protect (fun () ->
    Fun.protect (fun () ->
      write_ast options.plainsource channel structure)
      ~finally:(fun () -> close_out channel);
    let object_filename =
      Filename.remove_extension source_filename ^
      compiler.archive_suffix in
    compile options source_filename object_filename;
    Unix.chmod object_filename 0o640;
    Fun.protect (fun () -> Dynlink.loadfile object_filename)
      ~finally:(fun () ->
        (* Windows is an OS that does not let deletes occur when the file
           is still open. Dynlink.loadfile opens the file and does not close
           it even in [at_exit]. It is probably an OCaml bug that there is
           not way to close after Dynlink.loadfile, so we mitigate by just
           keeping the file around. [dune build] will remove the temporary
           directory (ex. build_3d445b_dune) regardless, so no resource leak
           when using Dune. *)
        if not Sys.win32 then Sys.remove object_filename))
    ~finally:(fun () -> (*Sys.remove source_filename*)())
