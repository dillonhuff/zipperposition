(*
Zipperposition: a functional superposition prover for prototyping
Copyright (C) 2012 Simon Cruanes

This is free software; you can redistribute it and/or
modify it under the terms of the GNU General Public License
as published by the Free Software Foundation; either version 2
of the License, or (at your option) any later version.

This is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA
02110-1301 USA.
*)

(** Some common things for superposition calculi *)

open Basic
open Symbols

(** binary inferences. An inference returns a list of conclusions *)
type binary_inf_rule = ProofState.active_set -> clause -> hclause list

(** unary infererences *)
type unary_inf_rule = hclause -> hclause list

(** The type of a calculus for first order reasoning with equality *) 
class type calculus =
  object
    method binary_rules : (string * binary_inf_rule) list
      (** the binary inference rules *)

    method unary_rules : (string * unary_inf_rule) list
      (** the unary inference rules *)

    method basic_simplify : hclause -> hclause
      (** how to simplify a clause *)

    method rw_simplify : ProofState.simpl_set -> hclause -> hclause
      (** how to simplify a clause w.r.t a set of unit clauses *)

    method active_simplify : ProofState.active_set -> hclause -> hclause
      (** how to simplify a clause w.r.t an active set of clauses *)

    method backward_simplify : ProofState.active_set -> hclause -> Clauses.CSet.t
      (** backward simplification by a unit clause. It returns a set of
          active clauses that can potentially be simplified by the given clause *)

    method redundant : ProofState.active_set -> hclause -> bool
      (** check whether the clause is redundant w.r.t the set *)

    method backward_redundant : ProofState.active_set -> hclause -> hclause list
      (** find redundant clauses in set w.r.t the clause *)

    method list_simplify : hclause -> hclause list
      (** how to simplify a clause into a (possibly empty) list
          of clauses. This subsumes the notion of trivial clauses (that
          are simplified into the empty list of clauses) *)

    method is_trivial : hclause -> bool
      (** single test to detect trivial clauses *)

    method axioms : hclause list
      (** a list of axioms to add to the problem *)

    method constr : hclause list -> precedence_constraint list
      (** some constraints on the precedence *)

    method preprocess : ctx:context -> hclause list -> hclause list
      (** how to preprocess the initial list of clauses *)
  end

(** do binary inferences that involve the given clause *)
val do_binary_inferences : ProofState.active_set ->
                          (string * binary_inf_rule) list -> (** named rules *)
                          hclause -> hclause list

(** do unary inferences for the given clause *)
val do_unary_inferences : (string * unary_inf_rule) list ->
                          hclause -> hclause list

(** fold on equation sides of literals that satisfy predicate *)
val fold_lits : ?both:bool -> (int -> literal -> bool) ->
                ('a -> term -> term -> bool -> position -> 'a) -> 'a ->
                literal array -> 'a

(** get the term l at given position in clause, and r such that l ?= r
    is the literal at the given position *)
val get_equations_sides : clause -> position -> term * term * bool

(** Perform backward simplification with the given clause. It returns the CSet of
    clauses that become redundant, and the list of those clauses after simplification. *)
val backward_simplify : calculus:calculus ->
                        ProofState.active_set -> ProofState.simpl_set -> hclause ->
                        Clauses.CSet.t * hclause list
