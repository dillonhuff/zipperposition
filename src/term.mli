(*
Copyright (c) 2013, Simon Cruanes
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

Redistributions of source code must retain the above copyright notice, this
list of conditions and the following disclaimer.  Redistributions in binary
form must reproduce the above copyright notice, this list of conditions and the
following disclaimer in the documentation and/or other materials provided with
the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
*)

(** {1 First-order terms} *)

(** term *)
type t = private {
  term : term_cell;             (** the term itself *)
  type_ : Type.t option;        (** optional type *)
  mutable tsize : int;          (** size (number of subterms) *)
  mutable flags : int;          (** boolean flags about the term *)
  mutable tag : int;            (** hashconsing tag *)
}
(** content of the term *)
and term_cell = private
  | Var of int                  (** variable *)
  | BoundVar of int             (** bound variable (De Bruijn index) *)
  | Bind of Symbol.t * t        (** bind one variable (of given sort), with the symbol *)
  | Node of Symbol.t * t list   (** term application *)
  | At of t * t                 (** HO application (curried) *)
and sourced_term =
  t * string * string           (** Term + file,name *)

type term = t

(** list of variables *)
type varlist = t list            

(** {2 Comparison, equality, containers} *)

val subterm : sub:t -> t -> bool    (** checks whether [sub] is a (non-strict) subterm of [t] *)
val eq : t -> t -> bool             (** standard equality on terms *)
val compare : t -> t -> int         (** a simple order on terms *)
val hash : t -> int
val hash_novar : t -> int           (** Hash that does not depend on variables *)

val has_type : t -> bool              (** Has a known type *)
val compatible_type : t -> t -> bool  (** Unifiable types? false if type missing *)
val same_type : t -> t -> bool        (** Alpha-equiv types? false if type missing *)
val compare_type : t -> t -> int      (** Comparison of types *)

module THashtbl : Hashtbl.S with type key = t
module TSet : Sequence.Set.S with type elt = t
module TMap : Sequence.Map.S with type key = t

module TCache : Cache.S with type key = t
module T2Cache : Cache.S2 with type key1 = t and type key2 = t

(** {2 Hashset of terms} *)
module THashSet : sig
  type t
  val create : ?size:int -> unit -> t
  val cardinal : t -> int
  val member : t -> term -> bool
  val iter : t -> (term -> unit) -> unit
  val add : t -> term -> unit
  val remove : t -> term -> unit
  val merge : t -> t -> unit              (** [merge s1 s2] adds elements of s2 to s1 *)
  val to_list : t -> term list            (** build a list from the set *)
  val from_list : term list -> t          (** build a set from the list *)
end

(** {2 Global terms table (hashconsing)} *)

module H : Hashcons.S with type elt = t

(** {2 Boolean flags} *)

val flag_db_closed : int
val flag_simplified : int
val flag_normal_form : int
val flag_ground : int
val flag_db_closed_computed : int

val set_flag : int -> t -> bool -> unit
  (** set or reset the given flag of the term to bool *)

val get_flag : int -> t -> bool
  (** read the flag *)

val new_flag : unit -> int
  (** New flag, different from all other flags *)

(** {2 Smart constructors} *)

val mk_var : ?ty:Type.t -> int -> t        (** Create a variable. The index must be >= 0 *)
val mk_bound_var : ?ty:Type.t -> int -> t  (** De Bruijn index, must be >= 0 *)

val mk_bind : Symbol.t -> t -> t
  (** [mk_bind s t] binds the De Bruijn 0 in [t]. *)

val mk_node : Symbol.t -> t list -> t
val mk_const : Symbol.t -> t

val mk_at : t -> t -> t
val mk_at_list : t -> t list -> t

val true_term : t                        (** tautology symbol *)
val false_term : t                       (** antilogy symbol *)

val mk_not : t -> t
val mk_and : t -> t -> t
val mk_or : t -> t -> t
val mk_imply : t -> t -> t
val mk_equiv : t -> t -> t
val mk_xor : t -> t -> t
val mk_eq : t -> t -> t
val mk_neq : t -> t -> t
val mk_lambda : t -> t
val mk_forall : t -> t
val mk_exists : t -> t

val mk_and_list : t list -> t
val mk_or_list : t list -> t

(** {2 Typing} *)

val is_bool : t -> bool               (** Boolean typed? *)
val cast : t -> Type.t -> t           (** Set the type *)
val arity : t -> int                  (** Arity, or 0 if it makes no sense *)

(** {2 Subterms and positions} *)

val is_var : t -> bool
val is_bound_var : t -> bool
val is_node : t -> bool
val is_const : t -> bool
val is_at : t -> bool
val is_bind : t -> bool

val at_pos : t -> Position.t -> t 
  (** retrieve subterm at pos, or raise Invalid_argument*)

val replace_pos : t -> Position.t -> t -> t
  (** replace t|_p by the second term *)

val replace : t -> old:term -> by:term -> t
  (** [replace t ~old ~by] syntactically replaces all occurrences of [old]
      in [t] by the term [by]. *)

val at_cpos : term -> int -> term
  (** retrieve subterm at the compact pos, or raise Invalid_argument*)

val max_cpos : term -> int
  (** maximum compact position in the term *)

val var_occurs : t -> t -> bool          (** [var_occurs x t] true iff x in t *)
val is_ground : t -> bool                (** is the term ground? (no free vars) *)
val max_var : varlist -> int             (** find the maximum variable index, >= 0 *)
val min_var : varlist -> int
val add_vars : THashSet.t -> t -> unit   (** add variables of the term to the set *)
val vars : t -> varlist                  (** compute variables of the term *)
val vars_list : t list -> varlist        (** variables of terms in the list *)
val vars_seq : t Sequence.t -> varlist   (** variables of terms in the sequence *)
val vars_prefix_order : t -> varlist     (** variables of the term in prefix traversal order *)
val depth : t -> int                     (** depth of the term *)
val head : t -> Symbol.t                  (** head symbol (or Invalid_argument) *)
val size : t -> int

(** {2 De Bruijn indexes} *)

val atomic : t -> bool                   (** atomic proposition, or term, at root *)
val atomic_rec : t -> bool               (** does not contain connectives/quantifiers *)

val db_closed : ?depth:int -> t -> bool
  (** check whether the term is closed (all DB vars are bound within the term) *)

val db_contains : t -> int -> bool
  (** Does t contains the De Bruijn variable of index n? *)

val db_replace : ?depth:int -> into:t -> by:t -> t
  (** Substitution of De Bruijn symbol by a term. [db_replace ~into ~by]
      replaces the De Bruijn symbol 0 by [by] in [into]. *)

val db_type : t -> int -> Type.t option
  (** [db_type t n] returns the type of the [n]-th De Bruijn index in [t] *)

val db_lift : ?depth:int -> int -> t -> t
  (** lift the non-captured De Bruijn indexes in the term by n *)

val db_unlift : ?depth:int -> t -> t
  (** Unlift the term (decrement indices of all free De Bruijn variables
      inside *)

val db_from_term : ?depth:int -> ?ty:Type.t -> t -> t -> t
  (** [db_from_term t t'] Replace [t'] by a fresh De Bruijn index in [t]. *)

val db_from_var : ?depth:int -> t -> t -> t
  (** [db_from_var t v] replace v by a De Bruijn symbol in t.
      Same as db_from_term. *)

(** {2 High-level operations} *)

(** constructors with free variables. The first argument is the
    list of variables that is bound, then the quantified/abstracted
    term. *)

val mk_lambda_var : t list -> t -> t   (** (lambda v1,...,vn. t). *)
val mk_forall_var : t list -> t -> t
val mk_exists_var : t list -> t -> t

val close_forall : t -> t             (** Bind all free variables by 'forall' *)
val close_exists : t -> t             (** Bind all free variables by 'exists' *)

val symbols : t Sequence.t -> Symbol.SSet.t   (** Symbols of the terms (keys of signature) *)
val contains_symbol : Symbol.t -> t -> bool   (** Does the term contain the symbol *)

val db_to_classic : ?varindex:int ref -> t -> t
  (** Transform binders and De Bruijn indexes into regular variables.
      [varindex] is a variable counter used to give fresh variables
      names to De Bruijn indexes. *)

(** {2 Fold} *)

(** High level fold-like combinators *)

val all_positions : ?vars:bool -> ?pos:Position.t -> t -> 'a ->
                    ('a -> t -> Position.t -> 'a) -> 'a
  (** apply f to all non-variable positions in t, accumulating the
      results along.
      [vars] specifies whether variables are folded on (default true). *)

(** {2 Some AC-utils} *)

val flatten_ac : Symbol.t -> t list -> t list
  (** [flatten_ac f l] flattens the list of terms [l] by deconstructing all its
      elements that have [f] as head symbol. For instance, if l=[1+2; 3+(4+5)]
      with f="+", this will return [1;2;3;4;5], perhaps in a different order *)

val ac_normal_form :  ?is_ac:(Symbol.t -> bool) ->
                      ?is_com:(Symbol.t -> bool) ->
                      t -> t
  (** normal form of the term modulo AC *)

val ac_eq : ?is_ac:(Symbol.t -> bool) -> ?is_com:(Symbol.t -> bool) ->
            t -> t -> bool
  (** Check whether the two terms are AC-equal. Optional arguments specify
      which symbols are AC or commutative (by default by looking at
      attr_ac and attr_commut). *)

(** {2 Printing/parsing} *)

(** First, full functions with the amount of surrounding binders; then helpers
    in the case this amount is 0 (for instance in clauses) *)

val pp_depth : int -> Buffer.t -> t -> unit
val pp_tstp_depth : int -> Buffer.t -> t -> unit

val pp_debug : Buffer.t -> t -> unit
val pp_tstp : Buffer.t -> t -> unit

val pp : Buffer.t -> t -> unit
val set_default_pp : (Buffer.t -> t -> unit) -> unit
val to_string : t -> string
val fmt : Format.formatter -> t -> unit

val bij : t Bij.t

val debug : Format.formatter -> t -> unit
  (** debug printing, with sorts *)
