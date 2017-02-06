
(* This file is free software, part of Zipperposition. See file "license" for more details. *)

(** {1 Literal} *)

open Libzipperposition

module Fmt = CCFormat
module T = FOTerm
module P = Position
module PW = Position.With
module S = Subst

type ty = Type.t
type term = T.t

type t =
  | Bool of bool
  | Atom of term * bool
  | Eq of term * term * bool
type lit = t

let true_ = Bool true
let false_ = Bool false
let bool b = Bool b
let atom ?(sign=true) t = Atom (t, sign)

let eq ?(sign=true) t u =
  if T.equal t u then bool sign
  else (
    (* canonical order *)
    let left, right = if T.compare t u < 0 then t, u else u, t in
    Eq (left, right, sign)
  )

let sign = function
  | Atom (_, b)
  | Eq (_,_,b)
  | Bool b -> b

let equal a b: bool = match a, b with
  | Bool b1, Bool b2 -> b1=b2
  | Atom (t1,sign1), Atom (t2,sign2) -> T.equal t1 t2 && sign1=sign2
  | Eq (t1,u1,sign1), Eq (t2,u2,sign2) ->
    sign1=sign2 &&
    T.equal t1 t2 && T.equal u1 u2
  | Bool _, _
  | Atom _, _
  | Eq _, _
    -> false

let hash = function
  | Bool b -> Hash.combine2 10 (Hash.bool b)
  | Atom (t,sign) -> Hash.combine3 20 (T.hash t) (Hash.bool sign)
  | Eq (t,u,sign) -> Hash.combine4 30 (T.hash t) (T.hash u) (Hash.bool sign)

let compare a b: int =
  let to_int = function Bool _ -> 0 | Atom _ -> 1 | Eq _ -> 2 in
  begin match a, b with
    | Bool b1, Bool b2 -> CCOrd.bool_ b1 b2
    | Atom (t1,sign1), Atom (t2,sign2) ->
      CCOrd.( T.compare t1 t2 <?> (bool_, sign1, sign2))
    | Eq (t1,u1,sign1), Eq (t2,u2,sign2) ->
      CCOrd.( T.compare t1 t2
        <?> (T.compare, u1, u2)
        <?> (bool_, sign1, sign2))
    | Bool _, _
    | Atom _, _
    | Eq _, _
      -> CCInt.compare (to_int a)(to_int b)
  end

let pp out t: unit = match t with
  | Bool b -> Fmt.bool out b
  | Atom (t, true) -> T.pp out t
  | Atom (t, false) -> Fmt.fprintf out "@[@<1>¬@[%a@]@]" T.pp t
  | Eq (t,u,true) -> Fmt.fprintf out "@[%a@ = %a@]" T.pp t T.pp u
  | Eq (t,u,false) -> Fmt.fprintf out "@[%a@ @<1>≠ %a@]" T.pp t T.pp u

let to_string = Fmt.to_string pp

(** {2 Helpers} *)

let neg lit = match lit with
  | Eq (l,r,sign) -> Eq (l,r,not sign)
  | Atom (p, sign) -> Atom (p, not sign)
  | Bool b -> Bool (not b)

let vars_seq = function
  | Bool _ -> Sequence.empty
  | Atom (t,_) -> T.Seq.vars t
  | Eq (t,u,_) -> Sequence.append (T.Seq.vars t) (T.Seq.vars u)

let vars_list l = vars_seq l |> Sequence.to_rev_list

let vars_set l =
  vars_seq l
  |> Sequence.to_rev_list
  |> CCList.sort_uniq ~cmp:(HVar.compare Type.compare)

let is_ground t : bool = vars_seq t |> Sequence.is_empty

let weight = function
  | Bool _ -> 0
  | Atom (t, _) -> T.weight t
  | Eq (t,u,_) -> T.weight t + T.weight u

let hash_mod_alpha = function
  | Bool b -> Hash.combine2 10 (Hash.bool b)
  | Atom (t,sign) -> Hash.combine3 20 (T.hash_mod_alpha t) (Hash.bool sign)
  | Eq (t,u,sign) ->
    let h_t = T.hash_mod_alpha t in
    let h_u = T.hash_mod_alpha u in
    let h1 = min h_t h_u in
    let h2 = max h_t h_u in
    Hash.combine4 30 h1 h2 (Hash.bool sign)

module As_key = struct
  type t = lit
  let compare = compare
end

module Set = CCSet.Make(As_key)

(** {2 Positions} *)

module With_pos = struct
  type t = lit Position.With.t

  let pp = PW.pp pp
  let compare = PW.compare compare
  let to_string = Fmt.to_string pp
end

let direction ord = function
  | Bool _ -> None
  | Atom _ -> None
  | Eq (t,u,_) -> Ordering.compare ord t u |> CCOpt.return

let at_pos_exn pos lit = match lit, pos with
  | Bool b, P.Stop -> if b then T.true_ else T.false_
  | Atom (t,_), _ -> T.Pos.at t pos
  | Eq (t,_,_), P.Left pos' -> T.Pos.at t pos'
  | Eq (_,u,_), P.Right pos' -> T.Pos.at u pos'
  | _, _ -> raise Not_found

let active_terms ord lit =
  let yield_term t pos = PW.make t pos in
  match lit with
  | Atom (t,true) ->
    T.all_positions ~vars:false ~ty_args:false t
    |> Sequence.map PW.of_pair
  | Eq (t,u,true) ->
    begin match Ordering.compare ord t u with
      | Comparison.Eq -> Sequence.empty (* trivial *)
      | Comparison.Incomparable ->
        Sequence.doubleton
          (yield_term t (P.left P.stop)) (yield_term u (P.right P.stop))
      | Comparison.Gt -> Sequence.return (yield_term t (P.left P.stop))
      | Comparison.Lt -> Sequence.return (yield_term u (P.right P.stop))
    end
  | Bool _
  | Atom (_,false)
  | Eq (_,_,false) -> Sequence.empty

let passive_terms ord lit =
  let explore_term t pos =
    T.all_positions ~pos ~vars:false ~ty_args:false t
    |> Sequence.map PW.of_pair
  in
  match lit with
  | Atom (t,_) ->
    T.all_positions ~vars:false ~ty_args:false t
    |> Sequence.map PW.of_pair
  | Eq (t,u,_) ->
    begin match Ordering.compare ord t u with
      | Comparison.Eq -> Sequence.empty (* trivial *)
      | Comparison.Incomparable ->
        Sequence.append
          (explore_term t (P.left P.stop))
          (explore_term u (P.right P.stop))
      | Comparison.Gt -> explore_term t (P.left P.stop)
      | Comparison.Lt -> explore_term u (P.right P.stop)
    end
  | Bool _ -> Sequence.empty

(** {2 Unif} *)

(** Unification-like operation on components of a literal. *)
module Unif_gen = struct
  type op = {
    term : subst:Subst.t -> term Scoped.t -> term Scoped.t ->
      Subst.t Sequence.t;
  }

  let op_matching : op = {
    term=(fun ~subst t1 t2 k ->
      try k (Unif.FO.matching_adapt_scope ~subst ~pattern:t1 t2)
      with Unif.Fail -> ());
  }

  let op_variant : op = {
    term=(fun ~subst t1 t2 k ->
      try k (Unif.FO.variant ~subst t1 t2)
      with Unif.Fail -> ());
  }

  let op_unif : op = {
    term=(fun ~subst t1 t2 k ->
      try k (Unif.FO.unification ~subst t1 t2)
      with Unif.Fail -> ());
  }

  (* match {x1,y1} in scope 1, with {x2,y2} with scope2 *)
  let unif4 f ~subst x1 y1 sc1 x2 y2 sc2 k =
    f ~subst (Scoped.make x1 sc1) (Scoped.make x2 sc2)
      (fun subst -> f ~subst (Scoped.make y1 sc1) (Scoped.make y2 sc2) k);
    f ~subst (Scoped.make y1 sc1) (Scoped.make x2 sc2)
      (fun subst -> f ~subst (Scoped.make x1 sc1) (Scoped.make y2 sc2) k);
    ()

  (* generic unification structure *)
  let unif_lits (op:op) ~subst (lit1,sc1) (lit2,sc2) k =
    begin match lit1, lit2 with
      | Atom (p1, sign1), Atom (p2, sign2) when sign1 = sign2 ->
        op.term ~subst (p1,sc1) (p2,sc2) k
      | Bool b1, Bool b2 -> if b1=b2 then k subst
      | Eq (l1, r1, sign1), Eq (l2, r2, sign2) when sign1 = sign2 ->
        unif4 op.term ~subst l1 r1 sc1 l2 r2 sc2 k
      | _, _ -> ()
    end
end

let variant ?(subst=S.empty) lit1 lit2 k =
  Unif_gen.unif_lits Unif_gen.op_variant ~subst lit1 lit2 k

let are_variant lit1 lit2 =
  not (Sequence.is_empty (variant (Scoped.make lit1 0) (Scoped.make lit2 1)))

let matching ?(subst=Subst.empty) ~pattern:lit1 lit2 k =
  let op = Unif_gen.op_matching in
  Unif_gen.unif_lits op ~subst lit1 lit2 k

(* find substitutions such that subst(l1=r1) implies l2=r2 *)
let eq_subsumes_ ~subst l1 r1 sc1 l2 r2 sc2 k =
  (* make l2 and r2 equal using l1 = r2 (possibly several times) *)
  let rec equate_terms ~subst l2 r2 k =
    (* try to make the terms themselves equal *)
    equate_root ~subst l2 r2 k;
    (* decompose *)
    match T.view l2, T.view r2 with
      | _ when T.equal l2 r2 -> k subst
      | T.App (f, ss), T.App (g, ts) when List.length ss = List.length ts ->
        equate_terms ~subst f g
          (fun subst -> equate_lists ~subst ss ts k)
      | _ -> ()
  and equate_lists ~subst l2s r2s k = match l2s, r2s with
    | [], [] -> k subst
    | [], _
    | _, [] -> ()
    | l2::l2s', r2::r2s' ->
      equate_terms ~subst l2 r2 (fun subst -> equate_lists ~subst l2s' r2s' k)
  (* make l2=r2 by a direct application of l1=r1, if possible. This can
      enrich [subst] *)
  and equate_root ~subst l2 r2 k =
    begin try
        let subst = Unif.FO.matching_adapt_scope
            ~subst ~pattern:(Scoped.make l1 sc1) (Scoped.make l2 sc2) in
        let subst = Unif.FO.matching_adapt_scope
            ~subst ~pattern:(Scoped.make r1 sc1) (Scoped.make r2 sc2) in
        k subst
      with Unif.Fail -> ()
    end;
    begin try
        let subst = Unif.FO.matching_adapt_scope
            ~subst ~pattern:(Scoped.make l1 sc1) (Scoped.make r2 sc2) in
        let subst = Unif.FO.matching_adapt_scope
            ~subst ~pattern:(Scoped.make r1 sc1) (Scoped.make l2 sc2) in
        k subst
      with Unif.Fail -> ()
    end;
    ()
  in
  equate_terms ~subst l2 r2 k

let subsumes ?(subst=Subst.empty) (lit1,sc1) (lit2,sc2) k =
  match lit1, lit2 with
    | Eq (l1, r1, true), Eq (l2, r2, true) ->
      eq_subsumes_ ~subst l1 r1 sc1 l2 r2 sc2 k
    | _ -> matching ~subst ~pattern:(lit1,sc1) (lit2,sc2) k

let unify ?(subst=Subst.empty) lit1 lit2 k =
  let op = Unif_gen.op_unif in
  Unif_gen.unif_lits op ~subst lit1 lit2 k

let map f = function
  | Eq (left, right, sign) ->
    let new_left = f left
    and new_right = f right in
    eq ~sign new_left new_right
  | Atom (p, sign) ->
    let p' = f p in
    atom ~sign p'
  | Bool b -> bool b

let apply_subst_ ~f_term subst (lit,sc) = match lit with
  | Eq (l,r,sign) ->
    let new_l = f_term subst (l,sc) in
    let new_r = f_term subst (r,sc) in
    eq ~sign new_l new_r
  | Atom (p, sign) ->
    let p' = f_term subst (p,sc) in
    atom ~sign p'
  | Bool _ -> lit

let apply_subst ~renaming subst (lit,sc) =
  apply_subst_ subst (lit,sc)
    ~f_term:(S.FO.apply ~renaming)

let apply_subst_no_renaming subst (lit,sc) =
  apply_subst_ subst (lit,sc)
    ~f_term:S.FO.apply_no_renaming

let apply_subst_no_simp ~renaming subst (lit,sc) = match lit with
  | Eq (l,r,sign) ->
    Eq (
      S.FO.apply ~renaming subst (l,sc),
      S.FO.apply ~renaming subst (r,sc),
      sign)
  | Atom (p, sign) ->
    Atom (S.FO.apply ~renaming subst (p,sc), sign)
  | Bool _ -> lit