
(* This file is free software, part of Zipperposition. See file "license" for more details. *)

(** {1 Induction through Cut} *)

open Libzipperposition

module Lits = Literals
module T = FOTerm
module Su = Substs
module Ty = Type
module IH = Induction_helpers

module type S = sig
  module Env : Env.S
  module Ctx : module type of Env.Ctx

  val register : unit -> unit
end

let section = Util.Section.make ~parent:Const.section "ind"

module Make(E : Env.S)(Avatar : Avatar_intf.S) = struct
  module Env = E
  module Ctx = E.Ctx
  module C = E.C

  module BoolLit = Ctx.BoolLit

  module IH_ctx = IH.Make(Ctx)
  module IHA = IH.MakeAvatar(Avatar)

  module Meta = struct
    let declare_inductive p ity =
      let module CI = E.Ctx.Induction in
      let ity = Induction.make ity.CI.pattern ity.CI.constructors in
      Util.debugf ~section 2 "@[<hv2>declare inductive type@ %a@]" (fun k->k Induction.print ity);
      let fact = Induction.t#to_fact ity in
      add_fact_ p fact

      (* declare inductive types *)
      E.Ctx.Induction.inductive_ty_seq
        (fun ity -> ignore (declare_inductive p ity));
      Signal.on E.Ctx.Induction.on_new_inductive_ty
        (fun ity ->
           ignore (declare_inductive p ity);
           Signal.ContinueListening
        );
  end

  type constructor = ID.t * Type.t
  (** constructor + its type *)

  type bool_lit = Bool_lit.t

  type inductive_type = {
    pattern : Type.t;
    constructors : constructor list;
  }

  let _failwith fmt = CCFormat.ksprintf fmt ~f:failwith
  let _invalid_arg fmt = CCFormat.ksprintf fmt ~f:invalid_arg

  let _tbl_ty : inductive_type ID.Tbl.t = ID.Tbl.create 16

  let _extract_hd ty =
    match Type.view (snd (Type.open_fun ty)) with
    | Type.App (s, _) -> s
    | _ ->
        _invalid_arg "expected function type, got %a" Type.pp ty

  let on_new_inductive_ty = Signal.create()

  let declare_ty ty constructors =
    let name = _extract_hd ty in
    if constructors = []
    then invalid_arg "InductiveCst.declare_ty: no constructors provided";
    try
      ID.Tbl.find _tbl_ty name
    with Not_found ->
      let ity = { pattern=ty; constructors; } in
      ID.Tbl.add _tbl_ty name ity;
      Signal.send on_new_inductive_ty ity;
      ity

  let inductive_ty_seq yield =
    ID.Tbl.iter (fun _ ity -> yield ity) _tbl_ty

  let is_inductive_type ty =
    inductive_ty_seq
    |> Sequence.exists (fun ity -> Unif.Ty.matches ~pattern:ity.pattern ty)

  let is_constructor_sym s =
    inductive_ty_seq
    |> Sequence.flat_map (fun ity -> Sequence.of_list ity.constructors)
    |> Sequence.exists (fun (s', _) -> ID.equal s s')

  let contains_inductive_types t =
    T.Seq.subterms t
    |> Sequence.exists (fun t -> is_inductive_type (T.ty t))

  let _get_ity ty =
    let s = _extract_hd ty in
    try ID.Tbl.find _tbl_ty s
    with Not_found ->
      failwith (CCFormat.sprintf "type %a is not inductive" Type.pp ty)

  type cst = T.t

  module Cst = TermArg

  module IMap = Sequence.Map.Make(CCInt)

  type case = T.t

  module Case = TermArg

  type sub_cst = T.t

  module SubCstSet = T.Set

  type cover_set = {
    cases : case list;
    rec_cases : case list;  (* recursive cases *)
    base_cases : case list;  (* base cases *)
    sub_constants : SubCstSet.t;  (* all sub-constants *)
  }

  type cst_data = {
    cst : cst;
    ty : inductive_type;
    subst : Substs.t; (* matched against [ty.pattern] *)
    dominates : unit ID.Tbl.t;
    mutable coversets : cover_set IMap.t;
    (* depth-> exhaustive decomposition of given depth  *)
  }

  let on_new_inductive = Signal.create()

  (* cst -> cst_data *)
  let _tbl : cst_data T.Tbl.t = T.Tbl.create 16
  let _tbl_sym : cst_data ID.Tbl.t = ID.Tbl.create 16

  (* case -> cst * coverset *)
  let _tbl_case : (cst * cover_set) T.Tbl.t = T.Tbl.create 16

  (* sub_constants -> cst * set * case in which the sub_constant occurs *)
  let _tbl_sub_cst : (cst * cover_set * T.t) T.Tbl.t = T.Tbl.create 16

  let _blocked = ref T.Set.empty

  let is_sub_constant t = T.Tbl.mem _tbl_sub_cst t

  let as_sub_constant t =
    if is_sub_constant t then Some t else None

  let is_blocked t =
    is_sub_constant t || T.Set.mem t !_blocked

  let set_blocked t =
    _blocked := T.Set.add t !_blocked

  let declare t =
    if T.is_ground t
    then
      if T.Tbl.mem _tbl t then ()
      else try
          Util.debugf 2 "declare new inductive constant %a" (fun k->k T.pp t);
          (* check that the type of [t] is inductive *)
          let ty = T.ty t in
          let name = _extract_hd ty in
          let ity = ID.Tbl.find _tbl_ty name in
          let subst = Unif.Ty.matching
              ~pattern:(Scoped.make ity.pattern 1) (Scoped.make ty 0) in
          let cst_data = {
            cst=t; ty=ity;
            subst;
            dominates=ID.Tbl.create 16;
            coversets=IMap.empty
          } in
          T.Tbl.add _tbl t cst_data;
          let s = T.head_exn t in
          ID.Tbl.replace _tbl_sym s cst_data;
          Signal.send on_new_inductive t;
          ()
        with Unif.Fail | Not_found ->
          _invalid_arg "term %a doesn't have an inductive type" T.pp t
    else _invalid_arg
        "term %a is not ground, cannot be an inductive constant" T.pp t

  (* monad over "lazy" values *)
  module FunM = CCFun.Monad(struct type t = unit end)
  module FunT = CCList.Traverse(FunM)

  (* coverset of given depth for this type and constant *)
  let _make_coverset ~depth ity cst =
    let cst_data = T.Tbl.find _tbl cst in
    (* list of generators of:
        - member of the coverset (one of the t such that cst=t)
        - set of sub-constants of this term *)
    let rec make depth =
      (* leaves: fresh constants *)
      if depth=0 then [fun () ->
          let ty = ity.pattern in
          let name = CCFormat.sprintf "#%a" ID.pp (_extract_hd ty) in
          let c = ID.make name in
          let t = T.const ~ty c in
          ID.Tbl.replace cst_data.dominates c ();
          _declare_symb c ty;
          set_blocked t;
          t, T.Set.singleton t
        ]
      (* inner nodes or base cases: constructors *)
      else CCList.flat_map
          (fun (f, ty_f) ->
             match Type.arity ty_f with
             | Type.NoArity ->
                 _failwith "invalid constructor %a for inductive type %a"
                   ID.pp f Type.pp ity.pattern
             | Type.Arity (0, 0) ->
                 if depth > 0
                 then  (* only one answer : f *)
                   [fun () -> T.const ~ty:ty_f f, T.Set.empty]
                 else []
             | Type.Arity (0, _) ->
                 let ty_args = Type.expected_args ty_f in
                 CCList.(
                   make_list (depth-1) ty_args >>= fun mk_args ->
                   return (fun () ->
                       let args, set = mk_args () in
                       T.app (T.const f ~ty:ty_f) args, set)
                 )
             | Type.Arity (m,_) ->
                 _failwith
                   ("inductive constructor %a requires %d type " ^^
                    "parameters, expected 0")
                   ID.pp f m
          ) ity.constructors
    (* given a list of types [l], yield all lists of cover terms
        that have types [l] *)
    and make_list depth l
      : (T.t list * T.Set.t) FunM.t list
      = match l with
      | [] -> [FunM.return ([], T.Set.empty)]
      | ty :: tail ->
          let t_builders = if Unif.Ty.matches ~pattern:ity.pattern ty
            then make depth
            else [fun () ->
                (* not an inductive sub-case, just create a skolem symbol *)
                let name = CCFormat.sprintf "#%a" ID.pp (_extract_hd ty) in
                let c = ID.make name in
                let t = T.const ~ty c in
                ID.Tbl.replace cst_data.dominates c ();
                _declare_symb c ty;
                t, T.Set.empty
              ] in
          let tail_builders = make_list depth tail in
          CCList.(
            t_builders >>= fun mk_t ->
            tail_builders >>= fun mk_tail ->
            [FunM.(mk_t >>= fun (t,set) ->
                   mk_tail >>= fun (tail,set') ->
                   return (t::tail, T.Set.union set set'))]
          )
    in
    assert (depth>0);
    (* make the cover set's cases, tagged with `Base or `Rec depending
       on whether they contain sub-cases *)
    let cases_and_subs = List.map
        (fun gen ->
           let t, set = gen() in
           (* remember whether [t] is base or recursive case *)
           if T.Set.is_empty set then (t, `Base), set else (t, `Rec), set
        ) (make depth)
    in
    let cases, sub_constants = List.split cases_and_subs in
    let cases, rec_cases, base_cases = List.fold_left
        (fun (c,r,b) (t,is_base) -> match is_base with
           | `Base -> t::c, r, t::b
           | `Rec -> t::c, t::r, b
        ) ([],[],[]) cases
    in
    let sub_constants =
      List.fold_left T.Set.union T.Set.empty sub_constants in
    let coverset = {cases; rec_cases; base_cases; sub_constants; } in
    (* declare sub-constants as such. They won't be candidate for induction
       and will be smaller than [t] *)
    List.iter
      (fun ((t, _), set) ->
         T.Tbl.add _tbl_case t (cst, coverset);
         T.Set.iter
           (fun sub_cst ->
              T.Tbl.replace _tbl_sub_cst sub_cst (cst, coverset, t)
           ) set
      ) cases_and_subs;
    coverset

  let inductive_cst_of_sub_cst t : cst * case =
    let cst, _set, case = T.Tbl.find _tbl_sub_cst t in
    cst, case

  let on_new_cover_set = Signal.create ()

  let cover_set ?(depth=1) t =
    try
      let cst = T.Tbl.find _tbl t in
      begin try
          (* is there already a cover set at this depth? *)
          IMap.find depth cst.coversets, `Old
        with Not_found ->
          (* create a new cover set *)
          let ity = _get_ity (T.ty t) in
          let coverset = _make_coverset ~depth ity t in
          (* save coverset *)
          cst.coversets <- IMap.add depth coverset cst.coversets;
          Util.debugf 2 "@[<2>new coverset for @[%a@]:@ {@[%a@]}@]"
            (fun k->k T.pp t (Util.pp_list T.pp) coverset.cases);
          Signal.send on_new_cover_set (t, coverset);
          coverset, `New
      end
    with Not_found ->
      _failwith "term %a is not an inductive constant, no coverset" T.pp t

  let is_inductive cst = T.Tbl.mem _tbl cst

  let as_inductive cst =
    if is_inductive cst then Some cst else None

  let is_inductive_symbol s = ID.Tbl.mem _tbl_sym s

  let cover_sets t =
    try
      let cst = T.Tbl.find _tbl t in
      IMap.to_seq cst.coversets |> Sequence.map snd
    with Not_found -> Sequence.empty

  let is_sub_constant_of t cst =
    let cst', _ = inductive_cst_of_sub_cst t in
    T.equal cst cst'

  let as_sub_constant_of t cst =
    if is_sub_constant_of t cst
    then Some t
    else None

  let is_case t = T.Tbl.mem _tbl_case t

  let as_case t = if is_case t then Some t else None

  let cases ?(which=`All) set = match which with
    | `All -> CCList.to_seq set.cases
    | `Base -> CCList.to_seq set.base_cases
    | `Rec -> CCList.to_seq set.rec_cases

  let sub_constants set = SubCstSet.to_seq set.sub_constants

  let sub_constants_case (t:case) =
    let _, set = T.Tbl.find _tbl_case t in
    sub_constants set
    |> Sequence.filter
      (fun sub -> Case.equal t (snd (inductive_cst_of_sub_cst sub)))

  (* true iff s2 is one of the sub-cases of s1 *)
  let dominates s1 s2 =
    assert (is_inductive_symbol s1);
    let cst_data = ID.Tbl.find _tbl_sym s1 in
    ID.Tbl.mem cst_data.dominates s2

  let _seq_inductive_cst yield =
    T.Tbl.iter (fun t _ -> yield t) _tbl

  module Set = T.Set

  module Seq = struct
    let ty = inductive_ty_seq
    let cst = _seq_inductive_cst

    let constructors =
      inductive_ty_seq
      |> Sequence.flat_map (fun ity -> Sequence.of_list ity.constructors)
      |> Sequence.map fst
  end

  (* scan clauses for ground terms of an inductive type,
     and declare those terms *)
  let scan seq : CI.cst list =
    Sequence.map C.lits seq
    |> Sequence.flat_map IH_ctx.find_inductive_cst
    |> Sequence.map
      (fun c ->
         CI.declare c;
         CCOpt.get_exn (CI.as_inductive c)
      )
    |> Sequence.to_rev_list
    |> CCList.sort_uniq ~cmp:CI.Cst.compare

  let is_eq_ (t1:CI.cst) (t2:CI.case) = BoolLit.inject_case t1 t2

  (* TODO (similar to Avatar.introduce_lemma, should factorize this)
     - gather vars of c
     - make a fresh constant for each variable
     - replace variables by constants
     - for each lit, negate it and add [not lit <- trail] *)

  (* [cst] is the minimal term for which [ctx] holds, returns clauses
     expressing that (prepended to [acc]), and a boolean literal. *)
  let assert_min acc c ctx (cst:CI.cst) =
    match CI.cover_set ~depth:(IH.cover_set_depth()) cst with
    | _, `Old -> acc  (* already declared constant *)
    | set, `New ->
        (* for each member [t] of the cover set:
           - add ctx[t] <- [cst=t]
           - for each [t' subterm t] of same type, add ~[ctx[t']] <- [cst=t]
        *)
        let acc, b_lits =
          Sequence.fold
            (fun (acc, b_lits) (case:CI.case) ->
               let b_lit = is_eq_ cst case in
               (* ctx[case] <- b_lit *)
               let c_case = C.create_a ~parents:[c]
                   ~trail:Trail.(singleton b_lit)
                   (ClauseContext.apply ctx (case:>T.t))
                   (fun cc -> Proof.mk_c_inference ~theories:["ind"]
                       ~rule:"split" cc [C.proof c]
                   )
               in
               (* ~ctx[t'] <- b_lit for each t' subterm case *)
               let c_sub =
                 Sequence.fold
                   (fun c_sub (sub:CI.sub_cst) ->
                      (* ~[ctx[sub]] <- b_lit *)
                      let clauses = assert false
                      (* FIXME
                         let lits = ClauseContext.apply ctx (sub:>T.t) in
                         let f =
                         lits
                         |> Literals.to_form
                         |> F.close_forall
                         |> F.Base.not_
                         in
                         let proof = Proof.mk_f_inference ~theories:["ind"]
                          ~rule:"min" f [C.proof c]
                         in
                         PFormula.create f proof
                         |> PFormula.Set.singleton
                         |> Env.cnf
                         |> C.CSet.to_list
                         |> List.map (C.update_trail (C.Trail.add b_lit))
                      *)
                      in
                      clauses @ c_sub
                   ) [] (CI.sub_constants_case case)
               in
               Util.debugf ~section 2
                 "@[<2>minimality of %a@ in case %a:@ @[<hv>%a@]@]"
                 (fun k->k ClauseContext.pp ctx CI.Case.pp case
                     (Util.pp_list C.pp) (c_case :: c_sub));
               (* return new clauses and b_lit *)
               c_case :: c_sub @ acc, b_lit :: b_lits
            ) (acc, []) (CI.cases set)
        in
        (* boolean constraint *)
        (* FIXME: generate boolean clause(s) instead
           let qform = (QF.imply
                       (qform_of_trail (C.get_trail c))
                       (QF.xor_l (List.map QF.atom b_lits))
                    ) in

           Util.debugf ~section 2 "@[<2>add boolean constr@ @[%a@]@]"
           (fun k->k (QF.print_with ~pp_lit:BoolLit.print) qform);
           Solver.add_form ~tag:(C.id c) qform;
        *)
        Avatar.save_clause ~tag:(C.id c) c;
        acc

  (* checks whether the trail of [c] is trivial, that is:
     - contains two literals [i = t1] and [i = t2] with [t1], [t2]
        distinct cover set members, or
     - two literals [loop(i) minimal by a] and [loop(i) minimal by b], or
     - two literals [C in loop(i)], [D in loop(j)] if i,j do not depend
        on one another *)
  let has_trivial_trail c =
    let trail = C.get_trail c |> Trail.to_seq in
    (* all i=t where i is inductive *)
    let relevant_cases =
      trail
      |> Sequence.filter_map
        (fun blit ->
           match BoolLit.extract (Bool_lit.abs blit) with
           | None -> None
           | Some (BoolLit.Case (l, r)) -> Some (`Case (l, r))
           | Some _ -> None
        )
    in
    (* is there i such that   i=t1 and i=t2 can be found in the trail? *)
    Sequence.product relevant_cases relevant_cases
    |> Sequence.exists
      (function
        | (`Case (i1, t1), `Case (i2, t2)) ->
            let res = not (CI.Cst.equal i1 i2)
                      || (CI.Cst.equal i1 i2 && not (CI.Case.equal t1 t2)) in
            if res
            then (
              Util.debugf ~section 4
                "@[<2>clause@ @[%a@]@ redundant because of @[%a={%a,%a}@] in trail@]"
                (fun k->k C.pp c CI.Cst.pp i1 CI.Case.pp t1 CI.Case.pp t2)
            );
            res
        | _ -> false
      )

  exception FoundInductiveLit of int * (T.t * T.t) list

  (* if c is  f(t1,...,tn) != f(t1',...,tn') or d, with f inductive symbol, then
      replace c with    t1 != t1' or ... or tn != tn' or d *)
  let injectivity_destruct c =
    try
      let eligible = C.Eligible.(filter Literal.is_neq) in
      Lits.fold_lits ~eligible (C.lits c)
      |> Sequence.iter
        (fun (lit, i) -> match lit with
           | Literal.Equation (l, r, false) ->
               begin match T.Classic.view l, T.Classic.view r with
                 | T.Classic.App (s1, l1), T.Classic.App (s2, l2)
                   when ID.equal s1 s2
                     && CI.is_constructor_sym s1
                   ->
                     (* destruct *)
                     assert (List.length l1 = List.length l2);
                     let pairs = List.combine l1 l2 in
                     raise (FoundInductiveLit (i, pairs))
                 | _ -> ()
               end
           | _ -> ()
        );
      c (* nothing happened *)
    with FoundInductiveLit (idx, pairs) ->
      let lits = CCArray.except_idx (C.lits c) idx in
      let new_lits = List.map (fun (t1,t2) -> Literal.mk_neq t1 t2) pairs in
      let proof cc = Proof.mk_c_inference ~theories:["induction"]
          ~rule:"injectivity_destruct" cc [C.proof c]
      in
      let c' = C.create ~trail:(C.get_trail c) ~parents:[c] (new_lits @ lits) proof in
      Util.debugf ~section 3 "@[<hv2>injectivity:@ simplify @[%a@]@ into @[%a@]@]"
        (fun k->k C.pp c C.pp c');
      c'

  (* when a clause contains new inductive constants, assert minimality
     of the clause for all those constants independently *)
  let inf_assert_minimal c =
    let consts = scan (Sequence.singleton c) in
    let clauses = List.fold_left
        (fun acc cst ->
           let ctx = ClauseContext.extract_exn (C.lits c) (cst:CI.cst:>T.t) in
           assert_min acc c ctx cst
        ) [] consts
    in
    clauses

  let register () =
    Util.debug ~section 2 "register induction_lemmas";
    IH_ctx.declare_types ();
    Avatar.register (); (* avatar inferences, too *)
    (* FIXME: move to Extension, probably, so it can be added
       to {!Compute_prec} before computing precedence
       Ctx.add_constr 20 IH_ctx.constr_sub_cst;  (* enforce new constraint *)
    *)
    Env.add_unary_inf "induction_lemmas.cut" IHA.inf_introduce_lemmas;
    Env.add_unary_inf "induction_lemmas.ind" inf_assert_minimal;
    Env.add_is_trivial has_trivial_trail;
    Env.add_simplify injectivity_destruct;
    ()
end

(* FIXME: do not duplicate Avatar *)

let extension =
  let action (module E : Env.S) =
    E.Ctx.lost_completeness ();
    let module Solver = Sat_solver.Make(struct end) in
    let module A = Make(E)(Solver) in
    A.register();
    (* add an ordering constraint: ensure that constructors are smaller
       than other terms *)
  and add_constr c = Compute_prec.add_constr c 15 IH.constr_cstors in
  Extensions.(
    {default with
     name="induction_simple";
     actions=[Do action];
     prec_actions=[Prec_do add_constr];
    })

let () =
  Signal.on IH.on_enable
    (fun () ->
      Extensions.register extension;
      Signal.ContinueListening)
