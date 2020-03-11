
(* This file is free software, part of Zipperposition. See file "license" for more details. *)

(** {1 boolean subterms} *)

open Logtk
open Libzipperposition

module T = Term
module Pos = Position
module US = Unif_subst

type selection_setting = Any | Minimal | Large
type reasoning_kind    = 
    BoolReasoningDisabled | BoolCasesInference | BoolCasesSimplification | BoolCasesKeepParent
  | BoolCasesEagerFar | BoolCasesEagerNear

let section = Util.Section.make ~parent:Const.section "booleans"


let k_bool_reasoning = Flex_state.create_key ()
let k_cased_term_selection = Flex_state.create_key ()
let k_quant_rename = Flex_state.create_key ()
let k_interpret_bool_funs = Flex_state.create_key ()
let k_cnf_non_simpl = Flex_state.create_key ()
let k_norm_bools = Flex_state.create_key () 
let k_solve_formulas = Flex_state.create_key ()
let k_filter_literals = Flex_state.create_key ()
let k_nnf = Flex_state.create_key ()
let k_elim_bvars = Flex_state.create_key ()


let selection_to_str = function
  | Any -> "any"
  | Minimal -> "minimal"
  | Large -> "large"

module type S = sig
  module Env : Env.S
  module C : module type of Env.C

  (** {6 Registration} *)

  val setup : unit -> unit
  (** Register rules in the environment *)
end


module Make(E : Env.S) : S with module Env = E = struct
  module Env = E
  module C = Env.C
  module Ctx = Env.Ctx
  module Fool = Fool.Make(Env)

  let (=~),(/~) = Literal.mk_eq, Literal.mk_neq
  let (@:) = T.app_builtin ~ty:Type.prop
  let no a = a =~ T.false_
  let yes a = a =~ T.true_
  
  let find_bools c =
    let found = ref false in
    let subterm_selection = Env.flex_get k_cased_term_selection in

    let rec find_in_term ~top t k =
      match T.view t with 
      | T.Const _ when Type.is_prop (T.ty t) -> k t
      | T.App(_, args)
      | T.AppBuiltin(_, args) ->
        let take_subterm =
          not top &&
          Type.is_prop (T.ty t) && 
          not (T.is_true_or_false t) &&
          T.DB.is_closed t &&
          (subterm_selection != Minimal ||
           Iter.is_empty 
            (Iter.flat_map (find_in_term ~top:false) 
              (CCList.to_seq args))) in
        let continue =
          (subterm_selection = Any || not take_subterm) in
        if take_subterm then k t;
        if continue then (
          List.iter (fun arg -> 
            find_in_term ~top:false arg k 
          ) args)
      | T.Fun (_,body) ->
        find_in_term ~top:false body k
      | _ -> () in

    let eligible = 
      match Env.flex_get k_filter_literals with
      | `All -> C.Eligible.always
      | `Max -> (
          match subterm_selection with 
          | Any -> C.Eligible.res c
          | _ -> (fun i lit -> 
            (* found gives us the leftmost match! *)
            not (!found) && C.Eligible.res c i lit)) in
    
    Literals.fold_terms ~which:`All
      ~subterms:false ~eligible ~ord:(C.Ctx.ord ()) (C.lits c)
    |> Iter.flat_map (fun (t,_) ->
      let res = find_in_term ~top:true t in
      if not (Iter.is_empty res) then found := true;
      res
    )
    |> T.Set.of_seq
    |> T.Set.to_list
  
  let mk_res ~proof ~old ~repl new_lit c =
    C.create ~trail:(C.trail c) ~penalty:(C.penalty c)
      (new_lit :: Array.to_list( C.lits c |> Literals.map (T.replace ~old ~by:repl)))
    proof

  let bool_case_inf (c: C.t) : C.t list =    
    let proof = Proof.Step.inference [C.proof_parent c]
                ~rule:(Proof.Rule.mk"bool_inf") ~tags:[Proof.Tag.T_ho] in

    Util.debugf 1 ~section "bci(@[%a@])=@." (fun k -> k C.pp c);

    find_bools c
    |> CCList.fold_left (fun acc old ->
      let neg_lit, repl = 
        if Builtin.compare Builtin.True Builtin.False > 0 then (no old, T.true_)
        else (yes old, T.false_) in
      (mk_res ~proof ~old ~repl neg_lit c) :: acc
    ) []

  let bool_case_simp (c: C.t) : C.t list option =
    let proof = Proof.Step.simp [C.proof_parent c]
                ~rule:(Proof.Rule.mk"bool_simp") ~tags:[Proof.Tag.T_ho] in

    let bool_subterms = find_bools c in
    if CCList.is_empty bool_subterms then None
    else (
      CCOpt.return @@ CCList.fold_left (fun acc old ->
        let neg_lit, repl_neg = no old, T.true_ in
        let pos_lit, repl_pos = yes old, T.false_ in
        (mk_res ~proof ~old ~repl:repl_neg neg_lit c) ::
        (mk_res ~proof ~old ~repl:repl_pos pos_lit c) :: acc
    ) [] bool_subterms)

  let simplify_bools t =
    let simplify_and_or t b l =
      let open Term in
      let compl_in_l l =
        let pos, neg = 
          CCList.partition_map (fun t -> 
              match view t with 
              | AppBuiltin(Builtin.Not, [s]) -> `Right s
              | _ -> `Left t) l
          |> CCPair.map_same Set.of_list in
        not (Set.is_empty (Set.inter pos neg)) in
      
      let res = 
        assert(b = Builtin.And || b = Builtin.Or);
        let netural_el, absorbing_el = 
          if b = Builtin.And then true_,false_ else (false_,true_) in

        let l' = CCList.sort_uniq ~cmp:compare l in

        if compl_in_l l || List.exists (equal absorbing_el) l then absorbing_el
        else (
          let l' = List.filter (fun s -> not (equal s netural_el)) l' in
          if List.length l = List.length l' then t
          else (
            if CCList.is_empty l' then netural_el
            else (if List.length l' = 1 then List.hd l'
                  else app_builtin ~ty:(Type.prop) b l')
          )) 
      in
      res 
    in

  let rec aux t =
    match T.view t with 
    | DB _ | Const _ | Var _ -> t
    | Fun(ty, body) ->
      let body' = aux body in
      if T.equal body body' then t
      else T.fun_ ty body'
    | App(hd, args) ->
      let hd' = aux hd and  args' = List.map aux args in
      if T.equal hd hd' && T.same_l args args' then t
      else T.app hd' args'
    | AppBuiltin(Builtin.And, [x]) 
        when T.is_true_or_false x && List.length (Type.expected_args (T.ty t)) = 1 ->
      if T.equal x T.true_ then (
        T.fun_ Type.prop (T.bvar ~ty:Type.prop 0)
      ) else (
        assert (T.equal x T.false_);
        T.fun_ Type.prop T.false_
      )
    | AppBuiltin(Builtin.Or, [x]) 
        when T.is_true_or_false x && List.length (Type.expected_args (T.ty t)) = 1 ->
      let prop = Type.prop in
      if T.equal x T.true_ then (
        T.fun_ prop (T.true_)
      ) else (
        assert (T.equal x T.false_);
        T.fun_ prop (T.bvar ~ty:prop 0)
      )
    | AppBuiltin(Builtin.And, l) when List.length l > 1 ->
      let l' = List.map aux l in
      let t = if T.same_l l l' then t 
        else T.app_builtin ~ty:(Type.prop) Builtin.And l' in
      simplify_and_or t Builtin.And l'
    | AppBuiltin(Builtin.Or, l) when List.length l > 1 ->
      let l' = List.map aux l in
      let t = if T.same_l l l' then t 
        else T.app_builtin ~ty:(Type.prop) Builtin.Or l' in
      simplify_and_or t Builtin.Or l'
    | AppBuiltin(Builtin.Not, [s]) ->
      if T.equal s T.true_ then T.false_
      else 
      if T.equal s T.false_ then T.true_
      else (
        match T.view s with 
        | AppBuiltin(Builtin.Not, [s']) -> aux s'
        | _ ->  
          let s' = aux s in
          if T.equal s s' then t else
            T.app_builtin ~ty:(Type.prop) Builtin.Not [s'] 
      )
    | AppBuiltin(Builtin.Imply, [p;c]) ->
      if T.equal p T.true_ then aux c
      else if T.equal p T.false_ then T.true_
      else if T.equal c T.false_ then aux (T.Form.not_ p)
      else if T.equal c T.true_ then T.true_
      else if T.equal p c then T.true_
      else (
        let p',c' = aux p, aux c in
        if T.equal p p' && T.equal c c' then t 
        else T.app_builtin ~ty:(T.ty t) Builtin.Imply [p';c'])
    | AppBuiltin(hd, ([a;b]|[_;a;b])) 
        when hd = Builtin.Eq || hd = Builtin.Equiv ->
      if T.equal a b then T.true_ 
      else if T.equal a T.true_ then aux b
      else if T.equal b T.true_ then aux a
      else if T.equal a T.false_ then aux (T.Form.not_ b)
      else if T.equal b T.false_ then aux (T.Form.not_ a)
      else (
        let a',b' = aux a, aux b in
        if T.equal a a' && T.equal b b' then t 
        else T.app_builtin ~ty:(T.ty t) hd [a';b']
      )
    | AppBuiltin(hd, ([a;b]|[_;a;b]))
        when hd = Builtin.Neq || hd = Builtin.Xor ->
      if T.equal a b then T.false_ else (
        let a',b' = aux a, aux b in
        if T.equal a a' && T.equal b b' then t 
        else T.app_builtin ~ty:(T.ty t) hd [a';b']
      )
    | AppBuiltin((ExistsConst|ForallConst) as b, [g]) ->
      let g' = aux g in
      let exp_g = Lambda.eta_expand g' in
      let _, body = T.open_fun exp_g in
      assert(Type.is_prop (T.ty body));
      if (T.Seq.subterms ~include_builtin:true body
          |> Iter.exists T.is_bvar) then (
        if T.equal g g' then t
        else T.app_builtin ~ty:(T.ty t) b [g']
      ) else body
    | AppBuiltin(hd, args) ->
      let args' = List.map aux args in
      if T.same_l args args' then t
      else T.app_builtin ~ty:(T.ty t) hd args' in  
  let res = aux t in
  if not (T.DB.is_closed res) then (
    CCFormat.printf "t:@[%a@]@." T.pp t;
    CCFormat.printf "res:@[%a@]@." T.pp res;
    assert false;
  );
  res

  let simpl_bool_subterms c =
    let new_lits = Literals.map simplify_bools (C.lits c) in
    if Literals.equal (C.lits c) new_lits then (
      SimplM.return_same c
    ) else (
      let proof = Proof.Step.simp [C.proof_parent c] 
          ~rule:(Proof.Rule.mk "simplify boolean subterms") in
      let new_ = C.create ~trail:(C.trail c) ~penalty:(C.penalty c) 
          (Array.to_list new_lits) proof in
      SimplM.return_new new_
    )

  let nnf_bools t =
    let module F = T.Form in
    let rec aux t =
      match T.view t with 
      | Const _ | DB _ | Var _ -> t
      | Fun _ ->
        let tyargs, body = T.open_fun t in
        let body' = aux body in
        if T.equal body body' then t
        else T.fun_l tyargs body'
      | App(hd, l) ->
        let hd' = aux hd and l' = List.map aux l in
        if T.equal hd hd' && T.same_l l l' then t
        else T.app hd' l'
      | AppBuiltin (Builtin.Not, [f]) ->
        begin match T.view f with 
        | AppBuiltin(Not, [g]) -> aux g
        | AppBuiltin( ((And|Or) as b), l) when List.length l >= 2 ->
          let flipped = if b = Builtin.And then F.or_l else F.and_l in
          flipped (List.map (fun t -> aux (F.not_ t))  l)
        | AppBuiltin( ((ForallConst|ExistsConst) as b), ([g]|[_;g]) ) ->
          let flipped = 
            if b = Builtin.ForallConst then Builtin.ExistsConst
            else Builtin.ForallConst in
          let g_ty_args, g_body = T.open_fun (Lambda.eta_expand g)  in
          let g_body' = aux @@ F.not_ g_body in
          let g' = Lambda.eta_reduce (T.fun_l g_ty_args g_body') in
          T.app_builtin ~ty:(T.ty t) flipped [g']
        | AppBuiltin( Imply, [g;h] ) ->
          F.and_ (aux g) (aux @@ F.not_ h)
        | AppBuiltin( ((Equiv|Xor) as b), [g;h] ) ->
          let flipped = if b = Equiv then Builtin.Xor else Builtin.Equiv in
          aux (T.app_builtin ~ty:(T.ty t) flipped [g;h])
        | AppBuiltin(((Eq|Neq) as b), ([_;s;t]|[s;t])) ->
          let flipped = if b = Eq then F.neq else F.eq in
          flipped (aux s) (aux t)
        | _ -> F.not_ (aux f)
        end
      | AppBuiltin(Imply, [f;g]) -> aux (F.or_ (F.not_ f) g)
      | AppBuiltin(Equiv, [f;g]) ->
        aux (F.and_ (F.imply f g) (F.imply g f))
      | AppBuiltin(Xor, [f;g]) ->
        aux (F.and_ (F.or_ f g) (F.or_ (F.not_ f)  (F.not_ g)))
      | AppBuiltin(b, l) ->
        let l' = List.map aux l in
        if T.same_l l l' then t
        else T.app_builtin ~ty:(T.ty t) b l' in
    aux t


  let nnf_bool_subters c =
    let new_lits = Literals.map nnf_bools (C.lits c) in
    if Literals.equal (C.lits c) new_lits then (
      SimplM.return_same c
    ) else (
      let proof = Proof.Step.simp [C.proof_parent c] 
          ~rule:(Proof.Rule.mk "nnf boolean subterms") in
      let new_ = C.create ~trail:(C.trail c) ~penalty:(C.penalty c) 
          (Array.to_list new_lits) proof in
      SimplM.return_new new_
    )

  let normalize_bool_terms c =
    let new_lits = Literals.map T.normalize_bools (C.lits c) in
    if Literals.equal (C.lits c) new_lits then (
      SimplM.return_same c
    ) else (
      let proof = Proof.Step.simp [C.proof_parent c] 
          ~rule:(Proof.Rule.mk "normalize subterms") in
      let new_ = C.create ~trail:(C.trail c) ~penalty:(C.penalty c) 
          (Array.to_list new_lits) proof in
      SimplM.return_new new_
    )

  let normalize_equalities c =
    let lits = Array.to_list (C.lits c) in
    let normalized = List.map Literal.normalize_eq lits in
    if List.exists CCOpt.is_some normalized then (
      let new_lits = List.mapi (fun i l_opt -> 
          CCOpt.get_or ~default:(Array.get (C.lits c) i) l_opt) normalized in
      let proof = Proof.Step.inference [C.proof_parent c] 
          ~rule:(Proof.Rule.mk "simplify nested equalities")  in
      let new_c = C.create ~trail:(C.trail c) ~penalty:(C.penalty c) new_lits proof in
      SimplM.return_new new_c
    ) 
    else (
      SimplM.return_same c 
    )

  let solve_bool_formulas c =
    let module PUnif = 
      PUnif.Make(struct 
        let st = 
          Env.flex_state ()
          |> Flex_state.add PragUnifParams.k_fixpoint_decider true
          |> Flex_state.add PragUnifParams.k_pattern_decider true
          |> Flex_state.add PragUnifParams.k_solid_decider true
          |> Flex_state.add PragUnifParams.k_max_inferences 1
          |> Flex_state.add PragUnifParams.k_max_depth 2
          |> Flex_state.add PragUnifParams.k_max_app_projections 2
          |> Flex_state.add PragUnifParams.k_max_rigid_imitations 2
          |> Flex_state.add PragUnifParams.k_max_elims 2
          |> Flex_state.add PragUnifParams.k_max_identifications 2
        end) in
    
    let normalize_not t =
      let rec aux t = 
        match T.view t with
        | T.AppBuiltin(Not, [f]) ->
          begin match T.view f with
          | T.AppBuiltin(Not, [g]) -> aux g
          | T.AppBuiltin( ((Eq|Equiv) as b), l ) ->
            let flipped = 
              if b = Builtin.Eq then Builtin.Neq else Builtin.Xor in
            T.app_builtin flipped l ~ty:(T.ty f)
          | T.AppBuiltin( ((Neq|Xor) as b), l ) ->
            let flipped = 
              if b = Builtin.Neq then Builtin.Eq else Builtin.Equiv in
            T.app_builtin flipped l ~ty:(T.ty f)
          | _ -> t end
        | _ -> t in
      aux t in

    let find_resolvable_form lit =
      match (Literal.View.as_eqn lit) with 
      | Some (l,r,sign) ->
        if not sign && not (T.is_true_or_false r) && Type.is_prop (T.ty l) then (
          Some (l,r)
        ) else if T.is_true_or_false r then (
          let neg = if T.equal r T.true_ then CCFun.id else T.Form.not_ in
          match T.view (normalize_not (neg l)) with 
          | T.AppBuiltin((Neq|Xor), ([f;g]|[_;f;g])) when Type.is_prop (T.ty f) ->
            assert(Type.equal (T.ty f) (T.ty g));
            Some (f,g)
          | _ -> None
        ) else None
      | None -> None in
    
    C.lits c
    |> CCArray.mapi (fun i lit -> 
      match find_resolvable_form lit with 
      | None -> None
      | Some (l,r) ->
        try
          let subst = 
            PUnif.unify_scoped (l,0) (r,0)
            |> OSeq.nth 0
            |> CCOpt.get_exn in
          assert(not @@ Unif_subst.has_constr subst);
          let new_lits = 
            CCArray.except_idx (C.lits c) i
            |> CCArray.of_list
            |> (fun l -> 
                Literals.apply_subst 
                  (Subst.Renaming.create ()) (US.subst subst) (l,0))
            |> CCArray.to_list in
          let proof = 
            Proof.Step.inference ~tags:[Proof.Tag.T_ho]
              ~rule:(Proof.Rule.mk "solve_formulas")
              [C.proof_parent c] in
          Some (C.create ~penalty:(C.penalty c) ~trail:(C.trail c) new_lits proof)
        with _ -> None)
      |> CCArray.filter_map CCFun.id
      |> CCArray.to_list
      |> (fun l -> if CCList.is_empty l then None else Some l)


  let cnf_otf c : C.t list option =
    let idx = CCArray.find_idx (fun l -> 
        let eq = Literal.View.as_eqn l in
        match eq with 
        | Some (l,r,sign) -> 
          Type.is_prop (T.ty l) &&
          not (T.equal l r) &&
          ((not (T.equal r T.true_) && not (T.equal r T.false_))
           || T.is_formula l || T.is_formula r)
        | None            -> false 
      ) (C.lits c) in

    let renaming_weight = 40 in
    let max_formula_weight = 
      C.Seq.terms c 
      |> Iter.filter T.is_formula
      |> Iter.map T.size
      |> Iter.max in
    let opts = 
      match max_formula_weight with
      | None -> [Cnf.DisableRenaming]
      | Some m -> if m < renaming_weight then [Cnf.DisableRenaming] else [] in

    match idx with 
    | Some _ ->
      let f = Literals.Conv.to_tst (C.lits c) in
      let proof = Proof.Step.simp ~rule:(Proof.Rule.mk "cnf_otf") ~tags:[Proof.Tag.T_ho] [C.proof_parent c] in
      let trail = C.trail c and penalty = C.penalty c in
      let stmt = Statement.assert_ ~proof f in
      let cnf_vec = Cnf.convert @@ CCVector.to_seq @@ 
        Cnf.cnf_of ~opts ~ctx:(Ctx.sk_ctx ()) stmt in
      CCVector.iter (fun cl -> 
          Statement.Seq.ty_decls cl
          |> Iter.iter (fun (id,ty) -> Ctx.declare id ty)) cnf_vec;
      let solved = 
        if Env.flex_get k_solve_formulas then (
          CCOpt.get_or ~default:[] (solve_bool_formulas c))
        else [] in

      begin try 
        let clauses = CCVector.map (C.of_statement ~convert_defs:true) cnf_vec
                      |> CCVector.to_list 
                      |> CCList.flatten
                      |> List.map (fun c -> 
                          C.create ~penalty  ~trail (CCArray.to_list (C.lits c)) proof) in
        List.iteri (fun i new_c -> 
            assert((C.proof_depth c) <= C.proof_depth new_c);) clauses;
        Some (solved @clauses)
      with Type.ApplyError err ->
        CCFormat.printf "cnf(@[%a@])@.err:@[%s@]@." C.pp c err;
        CCFormat.printf "result:@[%a@]@." (CCVector.pp ~sep:";\n" (Statement.pp_clause_in Output_format.O_tptp)) cnf_vec;
        CCFormat.printf "proof:@[%a@]@." Proof.S.pp_tstp (C.proof c);
        assert false; end
    | None -> None

  let cnf_infer cl = 
    CCOpt.get_or ~default:[] (cnf_otf cl)

  let elim_bvars c =
    C.Seq.vars c
    |> T.VarSet.of_seq |> T.VarSet.to_seq
    |> Iter.filter (fun v -> Type.is_prop (HVar.ty v))
    |> Iter.flat_map_l (fun v ->
        let subst_true = 
          Subst.FO.bind' Subst.empty (v, 0) (T.true_, 0) in
        let subst_false = 
          Subst.FO.bind' Subst.empty (v, 0) (T.false_, 0) in
        [subst_true; subst_false])
    |> Iter.map (fun subst ->
        let proof =
          Some (Proof.Step.simp 
            ~tags:[Proof.Tag.T_ho] ~rule:(Proof.Rule.mk "elim_bool_vars")
            [C.proof_parent c]) in
        C.apply_subst ~proof (c,0) subst)
    |> (fun iter -> 
        if Iter.is_empty iter then None
        else Some (Iter.to_list iter))


  let interpret_boolean_functions c =
    (* Collects boolean functions only at top level, 
       and not the ones that are already a part of the quantifier *)
    let collect_tl_bool_funcs t k = 
      let rec aux t =
        match T.view t with
        | Var _  | Const _  | DB _ -> ()
        | Fun _ -> if Type.is_prop (Term.ty (snd @@ Term.open_fun t)) then k t
        | App (f, l) ->
          aux f;
          List.iter aux l
        | AppBuiltin (b,l) -> 
          if not @@ Builtin.is_quantifier b then List.iter aux l 
      in
      aux t in
    let interpret t i = 
      let ty_args, body = T.open_fun t in
      assert(Type.is_prop (Term.ty body));
      T.fun_l ty_args i 
    in
    let negate_bool_fun bool_fun =
      let ty_args, body = T.open_fun bool_fun in
      assert(Type.is_prop (Term.ty body));
      T.fun_l ty_args (T.Form.not_ body)
    in

    Iter.flat_map collect_tl_bool_funcs 
      (C.Seq.terms c
       |> Iter.filter (fun t -> not @@ T.is_fun t))
    |> Iter.sort_uniq ~cmp:Term.compare
    |> Iter.filter (fun t ->  
        let cached_t = Subst.FO.canonize_all_vars t in
        not (Term.Set.mem cached_t !Higher_order.prim_enum_terms))
    |> Iter.fold (fun res t -> 
        assert(T.DB.is_closed t);
        let proof = Proof.Step.inference[C.proof_parent c]
            ~rule:(Proof.Rule.mk"interpret boolean function") ~tags:[Proof.Tag.T_ho]
        in
        let as_forall = Literal.mk_prop (T.Form.forall t) false in
        let as_neg_forall = Literal.mk_prop (T.Form.forall (negate_bool_fun t)) false in
        let forall_cl = 
          C.create ~trail:(C.trail c) ~penalty:(C.penalty c)
            (as_forall :: Array.to_list(C.lits c |> Literals.map(T.replace ~old:t ~by:(interpret t T.true_))))
            proof in
        let forall_neg_cl = 
          C.create ~trail:(C.trail c) ~penalty:(C.penalty c)
            (as_neg_forall :: Array.to_list(C.lits c |> Literals.map(T.replace ~old:t ~by:(interpret t T.false_))))
            proof in

        Util.debugf ~section  1 "interpret bool: %a !!> %a.\n"  (fun k -> k C.pp c C.pp forall_cl);
        Util.debugf ~section  1 "interpret bool: %a !!~> %a.\n" (fun k -> k C.pp c C.pp forall_neg_cl);

        forall_cl :: forall_neg_cl :: res
      ) []

  let setup () =
    match Env.flex_get k_bool_reasoning with 
    | BoolReasoningDisabled -> ()
    | _ -> 
      (* Env.ProofState.PassiveSet.add (create_clauses ()); *)
      Env.add_basic_simplify simpl_bool_subterms;
      Env.add_basic_simplify normalize_equalities;
      if Env.flex_get k_nnf then (
        E.add_basic_simplify nnf_bool_subters;
      );
      if Env.flex_get k_norm_bools then (
        Env.add_basic_simplify normalize_bool_terms
      );
      Env.add_multi_simpl_rule Fool.rw_bool_lits;
      if Env.flex_get k_elim_bvars then (
        Env.add_multi_simpl_rule elim_bvars
      );
      if Env.flex_get k_cnf_non_simpl then (
        Env.add_unary_inf "cnf otf inf" cnf_infer;
      ) else  Env.add_multi_simpl_rule cnf_otf;
      if (Env.flex_get k_interpret_bool_funs) then (
        Env.add_unary_inf "interpret boolean functions" interpret_boolean_functions;
      );

      if Env.flex_get k_bool_reasoning = BoolCasesInference then (
        Env.add_unary_inf "bool_cases" bool_case_inf;
      )
      else if Env.flex_get k_bool_reasoning = BoolCasesSimplification then (
        Env.set_single_step_multi_simpl_rule bool_case_simp;
      ) else if Env.flex_get k_bool_reasoning = BoolCasesKeepParent then (
        let keep_parent c  = CCOpt.get_or ~default:[] (bool_case_simp c) in
        Env.add_unary_inf "bool_cases_keep_parent" keep_parent;
      )
end


open CCFun
open Builtin
open Statement
open TypedSTerm
open CCList


let if_changed proof (mk: ?attrs:Logtk.Statement.attrs -> 'r) s f p =
  let fp = f s p in
  if fp == [p] then [s] else map(fun x -> mk ~proof:(proof s) x) fp
(* match fp with 
   | [ x ] when TypedSTerm.equal x p -> [s]
   | _ -> map(fun x -> mk ~proof:(proof s) x) fp *)

let map_propositions ~proof f =
  CCVector.flat_map_list(fun s -> match Statement.view s with
      | Assert p	-> if_changed proof assert_ s f p
      | Lemma ps	-> if_changed proof lemma s (map%f) ps
      | Goal p	-> if_changed proof goal s f p
      | NegatedGoal(ts, ps)	-> if_changed proof (neg_goal ~skolems:ts) s (map%f) ps
      | _ -> [s]
    )


let is_bool t = CCOpt.equal Ty.equal (Some prop) (ty t)
let is_T_F t = match view t with AppBuiltin((True|False),[]) -> true | _ -> false

(* Modify every subterm of t by f except those at the "top". Here top is true if subterm occures under a quantifier Æ in a context where it could participate to the clausification if the surrounding context of Æ was ignored. *)
let rec replaceTST f top t =
  let re = replaceTST f in
  let ty = ty_exn t in
  let transformer = if top then id else f in
  transformer 
    (match view t with
     | App(t,ts) -> 
       app_whnf ~ty (re false t) (map (re false) ts)
     | Ite(c,x,y) -> 
       ite (re false c) (re false x) (re false y)
     | Match(t, cases) -> 
       match_ (re false t) (map (fun (c,vs,e) -> (c,vs, re false e)) cases)
     | Let(binds, expr) -> 
       let_ (map(CCPair.map2 (re false)) binds) (re false expr)
     | Bind(b,x,t) -> 
       let top = Binder.equal b Binder.Forall || Binder.equal b Binder.Exists in
       bind ~ty b x (re top t)
     | AppBuiltin(b,ts) ->
       let logical = for_all is_bool ts in
       app_builtin ~ty b (map (re(top && logical)) ts)
     | Multiset ts -> 
       multiset ~ty (map (re false) ts)
     | _ -> t)


let name_quantifiers stmts =
  let proof s = Proof.Step.esa [Proof.Parent.from(Statement.as_proof_i s)]
      ~rule:(Proof.Rule.mk "Quantifier naming")
  in
  let new_stmts = CCVector.create() in
  let changed = ref false in
  let if_changed (mk: ?attrs:Logtk.Statement.attrs -> 'r) s r = 
    if !changed then (changed := false; mk ~proof:(proof s) r) else s in
  let if_changed_list (mk: ?attrs:Logtk.Statement.attrs -> 'l) s r = 
    if !changed then (changed := false; mk ~proof:(proof s) r) else s in
  let name_prop_Qs s = replaceTST(fun t -> match TypedSTerm.view t with
      | Bind(Binder.Forall,_,_) | Bind(Binder.Exists, _, _) ->
        changed := true;
        let vars = Var.Set.of_seq (TypedSTerm.Seq.free_vars t) |> Var.Set.to_list in
        let qid = ID.gensym() in
        let ty = app_builtin ~ty:tType Arrow (prop :: map Var.ty vars) in
        let q = const ~ty qid in
        let q_vars = app ~ty:prop q (map var vars) in
        let proof = Proof.Step.define_internal qid [Proof.Parent.from(Statement.as_proof_i s)] in
        let q_typedecl = ty_decl ~proof qid ty in
        let definition = 
          (* ∀ vars: q[vars] ⇔ t, where t is a quantifier formula and q is a new name for it. *)
          bind_list ~ty:prop Binder.Forall vars 
            (app_builtin ~ty:prop Builtin.Equiv [q_vars; t]) 
        in
        CCVector.push new_stmts q_typedecl;
        CCVector.push new_stmts (assert_ ~proof definition);
        q_vars
      | _ -> t) true
  in
  stmts |> CCVector.map(fun s ->
      match Statement.view s with
      | TyDecl(id,t)	-> s
      | Data ts	-> s
      | Def defs	-> s
      | Rewrite _	-> s
      | Assert p	-> if_changed assert_ s (name_prop_Qs s p)
      | Lemma ps	-> if_changed_list lemma s (map (name_prop_Qs s) ps)
      | Goal p	-> if_changed goal s (name_prop_Qs s p)
      | NegatedGoal(ts, ps)	-> if_changed_list (neg_goal ~skolems:ts) s (map (name_prop_Qs s) ps)
    ) |> CCVector.append new_stmts;
  CCVector.freeze new_stmts


let rec replace old by t =
  let r = replace old by in
  let ty = ty_exn t in
  if TypedSTerm.equal t old then by
  else match view t with
    | App(f,ps) -> app_whnf ~ty (r f) (map r ps)
    | AppBuiltin(f,ps) -> app_builtin ~ty f (map r ps)
    | Ite(c,x,y) -> ite (r c) (r x) (r y)
    | Let(bs,e) -> let_ (map (CCPair.map2 r) bs) (r e)
    | Bind(b,v,e) -> bind ~ty b v (r e)
    | _ -> t


exception Return of TypedSTerm.t
(* If f _ s = Some r for a subterm s of t, then r else t. *)
let with_subterm_or_id t f = try
    (Seq.subterms_with_bound t (fun(s, var_ctx) ->
         match f var_ctx s with
         | None -> ()
         | Some r -> raise(Return r)));
    t
  with Return r -> r


(* If p is non-constant subproposition closed wrt variables vs, then (p ⇒ c[p:=⊤]) ∧ (p ∨ c[p:=⊥]) or else c unmodified. *)
let case_bool vs c p =
  if is_bool p && not(is_T_F p) && not (TypedSTerm.equal p c) && Var.Set.is_empty(Var.Set.diff (free_vars_set p) vs) then
    let ty = prop in
    app_builtin ~ty And [
      app_builtin ~ty Imply [p; replace p Form.true_ c];
      app_builtin ~ty Or [p; replace p Form.false_ c];
    ]
  else c


(* Apply repeatedly the transformation t[p] ↦ (p ⇒ t[⊤]) ∧ (¬p ⇒ t[⊥]) for each boolean parameter p≠⊤,⊥ that is closed in context where variables vs are bound. *)
let rec case_bools_wrt vs t =
  with_subterm_or_id t (fun _ s -> 
      match view s with
      | App(f,ps) ->
        let t' = fold_left (case_bool vs) t ps in
        if TypedSTerm.equal t t' then None else Some(case_bools_wrt vs t')
      | _ -> None
    )

let eager_cases_far stms =
  let proof s = Proof.Step.esa [Proof.Parent.from(Statement.as_proof_i s)]
      ~rule:(Proof.Rule.mk "eager_cases_far")
  in
  map_propositions ~proof (fun _ t ->
      [with_subterm_or_id t (fun vs s -> match view s with
           | Bind((Forall|Exists) as q, v, b) ->
             let b' = case_bools_wrt (Var.Set.add vs v) b in
             if TypedSTerm.equal b b' then None else Some(replace s (bind ~ty:prop q v b') t)
           | _ -> None)
       |> case_bools_wrt Var.Set.empty]) stms


let eager_cases_near stms =
  let proof s = Proof.Step.esa [Proof.Parent.from(Statement.as_proof_i s)]
      ~rule:(Proof.Rule.mk "eager_cases_near")
  in
  let rec case_near t =
    with_subterm_or_id t (fun vs s ->
        match view s with
        | AppBuiltin((And|Or|Imply|Not|Equiv|Xor|ForallConst|ExistsConst),_)
        | Bind((Forall|Exists),_,_) -> None
        | AppBuiltin((Eq|Neq), [x;y]) when is_bool x -> None
        | _ when is_bool s ->
          (* Case split a maximal boolean strict subterm of s which by selection of s isn't a direct subterm. *)
          let s' = case_bool vs s (with_subterm_or_id s (fun _ -> CCOpt.if_(fun x -> not (TypedSTerm.equal x s) && is_bool x && not(is_T_F x)))) in
          if TypedSTerm.equal s s' then None else Some(case_near(replace s s' t))
        | _ -> None)
  in
  map_propositions ~proof (fun _ p -> [case_near p]) stms



open Term

let post_eager_cases =
  let proof s = Proof.Step.esa [Proof.Parent.from(Statement.as_proof_c s)]
      ~rule:(Proof.Rule.mk "post_eager_cases")
  in
  map_propositions ~proof (fun _ c ->
      let cased = ref Set.empty in
      fold_left(SLiteral.fold(fun res -> (* Loop over subterms of terms of literals of a clause. *)
          Seq.subterms_depth %> Iter.fold(fun res (s,d) ->
              if d = 0 || not(Type.is_prop(ty s)) || is_true_or_false s || is_var s || Set.mem s !cased
                       || not (T.DB.is_closed s)
              then
                res
              else(
                cased := Set.add s !cased;
                let replace_s_by by = map(SLiteral.map ~f:(replace ~old:s ~by)) in
                flatten(map(fun c -> [
                      SLiteral.atom_true s :: replace_s_by false_ c; 
                      SLiteral.atom_false s :: replace_s_by true_ c
                    ]) res))
            ) res
        )) [c] c)

let _bool_reasoning = ref BoolReasoningDisabled
let _quant_rename = ref false


(* These two options run before CNF, 
   so (for now it is impossible to move them to Env
   since it is not even made at the moment) *)
let preprocess_booleans stmts = (match !_bool_reasoning with
    | BoolCasesEagerFar -> eager_cases_far
    | BoolCasesEagerNear -> eager_cases_near
    | _ -> id
  ) (if !_quant_rename then name_quantifiers stmts else stmts)

let preprocess_cnf_booleans stmts = match !_bool_reasoning with
  | BoolCasesEagerFar | BoolCasesEagerNear -> post_eager_cases stmts
  | _ -> stmts


let _cased_term_selection = ref Large
let _interpret_bool_funs = ref false
let _cnf_non_simpl = ref false
let _norm_bools = ref false 
let _solve_formulas = ref false
let _filter_literals = ref `Max
let _nnf = ref false
let _elim_bvars = ref false


let extension =
  let register env =
    let module E = (val env : Env.S) in
    let module ET = Make(E) in
    E.flex_add k_bool_reasoning !_bool_reasoning;
    E.flex_add k_cased_term_selection !_cased_term_selection;
    E.flex_add k_quant_rename !_quant_rename;
    E.flex_add k_interpret_bool_funs !_interpret_bool_funs;
    E.flex_add k_cnf_non_simpl !_cnf_non_simpl;
    E.flex_add k_norm_bools !_norm_bools;
    E.flex_add k_solve_formulas !_solve_formulas;
    E.flex_add k_filter_literals !_filter_literals;
    E.flex_add k_nnf !_nnf;
    E.flex_add k_elim_bvars !_elim_bvars;


    ET.setup ()
  in
  { Extensions.default with
    Extensions.name = "bool";
    env_actions=[register];
  }

let () =
  Options.add_opts
    [ "--boolean-reasoning", Arg.Symbol (["off"; "cases-inf"; "cases-simpl"; "cases-simpl-kp"; "cases-eager"; "cases-eager-near"], 
                                         fun s -> _bool_reasoning := 
                                             match s with 
                                             | "off" -> BoolReasoningDisabled
                                             | "cases-inf" -> BoolCasesInference
                                             | "cases-simpl" -> BoolCasesSimplification
                                             | "cases-simpl-kp" -> BoolCasesKeepParent
                                             | "cases-eager" -> BoolCasesEagerFar
                                             | "cases-eager-near" -> BoolCasesEagerNear
                                             | _ -> assert false), 
      " enable/disable boolean axioms";
      "--bool-subterm-selection",
      Arg.Symbol(["A"; "M"; "L"], (fun opt -> _cased_term_selection := 
                                      match opt with "A"->Any | "M"->Minimal | "L"->Large
                                                   | _ -> assert false)), 
      " select boolean subterm selection criterion: A for any, M for minimal and L for large";
      "--quantifier-renaming"
    , Arg.Bool (fun v -> _quant_rename := v)
    , " turn the quantifier renaming on or off";
      "--disable-simplifying-cnf",
      Arg.Set _cnf_non_simpl,
      " implement cnf on-the-fly as an inference rule";
      "--interpret-bool-funs"
    , Arg.Bool (fun v -> _interpret_bool_funs := v)
    , " turn interpretation of boolean functions as forall or negation of forall on or off";
      "--normalize-bool-terms", Arg.Bool((fun v -> _norm_bools := v)),
      " normalize boolean subterms using their weight.";
    "--solve-formulas"
    , Arg.Bool (fun v -> _solve_formulas := v)
    , " solve phi != psi eagerly using unification, where phi and psi are formulas";
    "--nnf-nested-formulas"
    , Arg.Bool (fun v -> _nnf := v)
    , " convert nested formulas into negation normal form";
    "--elim-bvars"
    , Arg.Bool ((:=) _elim_bvars)
    , " replace boolean variables by T and F";
    "--boolean-reasoning-filter-literals"
    , Arg.Symbol(["all"; "max"], (fun v ->
        match v with 
        | "all" -> _filter_literals:=`All
        | "max" -> _filter_literals:= `Max
        | _ -> assert false;))
    , " select on which literals to apply bool reasoning rules"
    ];
  Params.add_to_modes ["ho-complete-basic";
                       "ho-pragmatic";
                       "lambda-free-intensional";
                       "lambda-free-purify-intensional";
                       "lambda-free-extensional";
                       "lambda-free-purify-extensional";
                       "fo-complete-basic"] (fun () ->
      _bool_reasoning := BoolReasoningDisabled
  );
  Extensions.register extension
