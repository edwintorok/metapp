include Metapp_preutils

let attr_name (attribute : Parsetree.attribute) : string Location.loc =
  [%meta if Sys.ocaml_version < "4.08.0" then
    [%e fst attribute]
  else
    [%e attribute.attr_name]]

let attr_payload (attribute : Parsetree.attribute) : Parsetree.payload =
  [%meta if Sys.ocaml_version < "4.08.0" then
    [%e snd attribute]
  else
    [%e attribute.attr_payload]]

let attr_loc (attribute : Parsetree.attribute) : Location.t =
  [%meta if Sys.ocaml_version < "4.08.0" then
    [%e (fst attribute).loc]
  else
    [%e attribute.attr_loc]]

let find_attr (name : string) (attributes : Parsetree.attributes)
    : Parsetree.attribute option =
  Stdcompat.List.find_opt (fun attribute ->
    String.equal (attr_name attribute).txt name) attributes

let rec extract_first (p : 'a -> 'b option) (l : 'a list)
    : ('b * 'a list) option =
  match l with
  | [] -> None
  | hd :: tl ->
      match p hd with
      | Some b -> Some (b, tl)
      | None ->
          match extract_first p tl with
          | Some (b, tl) -> Some (b, hd :: tl)
          | None -> None

let filter : Ast_mapper.mapper =
  let check_attr (attributes : Parsetree.attributes) =
    match find_attr "when" attributes with
    | None -> true
    | Some attr -> bool_of_payload (attr_payload attr) in
  let rec check_pat (p : Parsetree.pattern) =
    begin match p.ppat_desc with
    | Ppat_constraint (p, _) -> check_pat p
    | _ -> false
    end ||
    check_attr p.ppat_attributes in
  let check_value_binding (binding : Parsetree.value_binding) =
    check_attr binding.pvb_attributes in
  let check_value_description (description : Parsetree.value_description) =
    check_attr description.pval_attributes in
  let check_case (case : Parsetree.case) =
    check_pat case.pc_lhs in
  let check_expr (e : Parsetree.expression) =
    check_attr e.pexp_attributes in
  let check_pat_snd (type a) (arg : a * Parsetree.pattern) =
    check_pat (snd arg) in
  let check_expr_snd (type a) (arg : a * Parsetree.expression) =
    check_expr (snd arg) in
  let check_type_declaration (declaration : Parsetree.type_declaration) =
    check_attr declaration.ptype_attributes in
  let pat (mapper : Ast_mapper.mapper) (p : Parsetree.pattern)
      : Parsetree.pattern =
    let p = Ast_mapper.default_mapper.pat mapper p in
    match p.ppat_desc with
    | Ppat_tuple args ->
        begin match List.filter check_pat args with
        | [] -> Pat.of_unit ()
        | [singleton] -> singleton
        | args -> { p with ppat_desc = Ppat_tuple args }
        end
    | Ppat_construct (lid, Some arg) ->
        if check_pat arg then
          p
        else
          { p with ppat_desc = Ppat_construct (lid, None)}
    | Ppat_variant (label, Some arg) ->
        if check_pat arg then
          p
        else
          { p with ppat_desc = Ppat_variant (label, None)}
    | Ppat_record (fields, closed_flag) ->
        begin match List.filter check_pat_snd fields with
        | [] -> { p with ppat_desc = Ppat_any }
        | fields -> { p with ppat_desc = Ppat_record (fields, closed_flag)}
        end
    | Ppat_array args ->
        { p with ppat_desc = Ppat_array (List.filter check_pat args)}
    | Ppat_or (a, b) when not (check_pat a) -> b
    | Ppat_or (a, b) when not (check_pat b) -> a
    | _ -> p in
  let expr (mapper : Ast_mapper.mapper) (e : Parsetree.expression)
      : Parsetree.expression =
    Ast_helper.with_default_loc e.pexp_loc @@ fun () ->
    let e = Ast_mapper.default_mapper.expr mapper e in
    match e.pexp_desc with
    | Pexp_let (rec_flag, bindings, body) ->
        begin match List.filter check_value_binding bindings with
        | [] -> body
        | bindings -> { e with pexp_desc = Pexp_let (rec_flag, bindings, body) }
        end
    | Pexp_fun (_label, _default, pat, body) when not (check_pat pat) ->
        body
    | Pexp_function cases ->
        { e with pexp_desc = Pexp_function (List.filter check_case cases)}
    | Pexp_apply (f, args) ->
        let items =
          List.filter check_expr_snd ((Asttypes.Nolabel, f) :: args) in
        begin match
          extract_first (function (Asttypes.Nolabel, f) -> Some f | _ -> None)
            items
        with
        | None ->
            Location.raise_errorf ~loc:!Ast_helper.default_loc
              "No function left in this application"
        | Some (e, []) -> e
        | Some (f, args) ->
            { e with pexp_desc = Pexp_apply (f, args)}
        end
    | Pexp_match (e, cases) ->
        { e with pexp_desc = Pexp_match (e, List.filter check_case cases)}
    | Pexp_try (e, cases) ->
        { e with pexp_desc = Pexp_try (e, List.filter check_case cases)}
    | Pexp_tuple args ->
        begin match List.filter check_expr args with
        | [] -> Exp.of_unit ()
        | [singleton] -> singleton
        | args -> { e with pexp_desc = Pexp_tuple args }
        end
    | Pexp_construct (lid, Some arg) ->
        if check_expr arg then
          e
        else
          { e with pexp_desc = Pexp_construct (lid, None)}
    | Pexp_variant (label, Some arg) ->
        if check_expr arg then
          e
        else
          { e with pexp_desc = Pexp_variant (label, None)}
    | Pexp_record (fields, base) ->
        let base =
          match base with
          | Some expr when check_expr expr -> base
          | _ -> None in
        let fields = List.filter check_expr_snd fields in
        if fields = [] then
          Location.raise_errorf ~loc:!Ast_helper.default_loc
            "Cannot construct an empty record";
        { e with pexp_desc = Pexp_record (fields, base)}
    | Pexp_array args ->
        { e with pexp_desc = Pexp_array (List.filter check_expr args)}
    | Pexp_sequence (a, b) when not (check_expr a) -> b
    | Pexp_sequence (a, b) when not (check_expr b) -> a
    | _ -> e in
  let structure_item (mapper : Ast_mapper.mapper)
      (item : Parsetree.structure_item) : Parsetree.structure_item =
    let item = Ast_mapper.default_mapper.structure_item mapper item in
    match item.pstr_desc with
    | Pstr_value (rec_flag, bindings) ->
        begin match List.filter check_value_binding bindings with
        | [] -> include_structure []
        | bindings -> { item with pstr_desc = Pstr_value (rec_flag, bindings)}
        end
    | Pstr_primitive description
      when not (check_value_description description) ->
        include_structure []
    | Pstr_type (rec_flag, declarations) ->
        { item with pstr_desc =
          Pstr_type (rec_flag, List.filter check_type_declaration declarations)}
    | _ -> item in
  let signature_item (mapper : Ast_mapper.mapper)
      (item : Parsetree.signature_item) : Parsetree.signature_item =
    let item = Ast_mapper.default_mapper.signature_item mapper item in
    match item.psig_desc with
    | Psig_value description  when not (check_value_description description) ->
        include_signature []
    | Psig_type (rec_flag, declarations) ->
        { item with psig_desc =
          Psig_type (rec_flag, List.filter check_type_declaration declarations)}
    | _ -> item in
  { Ast_mapper.default_mapper with pat; expr; structure_item; signature_item }

[%%meta Metapp_preutils.include_structure (
  if Sys.ocaml_version >= "4.08.0" then [%str
type sig_type = {
    id : Ident.t;
    decl : Types.type_declaration;
    rec_status : Types.rec_status;
    visibility : Types.visibility;
  }

let destruct_sig_type (item : Types.signature_item) : sig_type option =
  match item with
  | Sig_type (id, decl, rec_status, visibility) ->
      Some { id; decl; rec_status; visibility }
  | _ -> None]
else [%str
type sig_type = {
    id : Ident.t;
    decl : Types.type_declaration;
    rec_status : Types.rec_status;
  }

let destruct_sig_type (item : Types.signature_item) : sig_type option =
  match item with
  | Sig_type (id, decl, rec_status ) ->
      Some { id; decl; rec_status }
  | _ -> None])]

module Typ = struct
  let poly names ty =
    let names =
      [%meta if Sys.ocaml_version >= "4.05.0" then [%e
        List.map loc names]
      else [%e
        names]] in
    Ast_helper.Typ.poly names ty
end