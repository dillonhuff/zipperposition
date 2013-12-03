
(*
Zipperposition: a functional superposition prover for prototyping
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

(** {1 Global environment for an instance of the prover} *)

open Logtk

type binary_inf_rule = ProofState.ActiveSet.t -> Clause.t -> Clause.t list
  (** binary inferences. An inference returns a list of conclusions *)

type unary_inf_rule = Clause.t -> Clause.t list
  (** unary infererences *)

type rw_simplify_rule = ProofState.SimplSet.t -> Clause.t -> Clause.t 
  (** Simplify a clause w.r.t. a simplification set *)

type active_simplify_rule = ProofState.ActiveSet.t -> Clause.t -> Clause.t
  (** Simplify the given clause using clauses from the active set. *)

type backward_simplify_rule = ProofState.ActiveSet.t -> Clause.t -> Clause.CSet.t
  (** backward simplification by a unit clause. It returns a set of
      active clauses that can potentially be simplified by the given clause.
      [backward_simplify active c] therefore returns a subset of [active]. *)

type redundant_rule = ProofState.ActiveSet.t -> Clause.t -> bool
  (** check whether the clause is redundant w.r.t the set *)

type backward_redundant_rule = ProofState.ActiveSet.t -> Clause.t -> Clause.CSet.t
  (** find redundant clauses in set w.r.t the clause *)

type simplify_rule = Clause.t -> Clause.t
  (** Simplify the clause structurally (basic simplifications) *)

type is_trivial_rule = Clause.t -> bool
  (** Rule that checks whether the clause is trivial (a tautology) *)

type term_rewrite_rule = FOTerm.t -> FOTerm.t
  (** Rewrite rule on terms *)

type lit_rewrite_rule = ctx:Ctx.t -> Literal.t -> Literal.t
  (** Rewrite rule on literals *)

type t
  (** Global context for a superposition proof. It contains the inference
      rules, the context, the proof state... *)

(** {2 Modify the Env} *)

val create : ?meta:MetaProverState.t -> ctx:Ctx.t -> Params.t ->
             Signature.t -> t
  (** Create an environment (initially empty) *)

val add_passive : env:t -> Clause.t Sequence.t -> unit
  (** Add passive clauses *)

val add_active : env:t -> Clause.t Sequence.t -> unit
  (** Add active clauses *)

val add_simpl : env:t -> Clause.t Sequence.t -> unit
  (** Add simplification clauses *)

val remove_passive : env:t -> Clause.t Sequence.t -> unit
  (** Remove passive clauses *)

val remove_passive_id : env:t -> int Sequence.t -> unit
  (** Remove passive clauses by their ID *)

val remove_active : env:t -> Clause.t Sequence.t -> unit
  (** Remove active clauses *)

val remove_simpl  : env:t -> Clause.t Sequence.t -> unit
  (** Remove simplification clauses *)

val clean_passive : env:t -> unit
  (** Clean passive set (remove old clauses from clause queues) *)

val get_passive : env:t -> Clause.t Sequence.t
  (** Passive clauses *)

val get_active : env:t -> Clause.t Sequence.t
  (** Active clauses *)

val get_simpl : env:t -> Clause.t Sequence.t
  (** Clauses that can be used for simplification (unit clauses, mostly) *)

val add_binary_inf : env:t -> string -> binary_inf_rule -> unit
  (** Add a binary inference rule *)

val add_unary_inf : env:t -> string -> unary_inf_rule -> unit
  (** Add a unary inference rule *)

val add_rw_simplify : env:t -> rw_simplify_rule -> unit
  (** Add forward rewriting rule *)

val add_active_simplify : env:t -> active_simplify_rule -> unit
  (** Add simplification w.r.t active set *)

val add_backward_simplify : env:t -> backward_simplify_rule -> unit
  (** Add simplification of the active set *)

val add_redundant : env:t -> redundant_rule -> unit
  (** Add redundancy criterion w.r.t. the active set *)

val add_backward_redundant : env:t -> backward_redundant_rule -> unit
  (** Add rule that finds redundant clauses within active set *)

val add_simplify : env:t -> simplify_rule -> unit
  (** Add basic simplification rule *)

val add_is_trivial : env:t -> is_trivial_rule -> unit
  (** Add tautology detection rule *)

val add_expert : env:t -> Experts.t -> unit
  (** Add an expert structure *)

val add_rewrite_rule : env:t -> string -> term_rewrite_rule -> unit
  (** Add a term rewrite rule *)

val add_lit_rule : env:t -> string -> lit_rewrite_rule -> unit
  (** Add a literal rewrite rule *)

val interpret_symbol : env:t -> Symbol.t -> Evaluator.FO.eval_fun -> unit
  (** Add an evaluation function for a symbol. The evaluation
      function will be used by {!simplify}. *)

val interpret_symbols : env:t -> (Symbol.t * Evaluator.FO.eval_fun) list -> unit

(** {2 Use the Env} *)

val simplify : env:t -> Clause.t -> Clause.t
  (** Simplify the clause w.r.t the proof state. It uses many simplification
      rules and rewriting rules. *)

val get_experts : env:t -> Experts.Set.t

val get_meta : env:t -> MetaProverState.t option

val get_params : env:t -> Params.t

val get_empty_clauses : env:t -> Clause.CSet.t
  (** Set of known empty clauses *)

val get_some_empty_clause : env:t -> Clause.t option
  (** Some empty clause, if present, otherwise None *)

val add_on_empty : env:t -> (Clause.t -> unit) -> unit
  (** Callback, that will be called when an empty clause is added to the
      active or passive set *)

val ctx : t -> Ctx.t
val ord : t -> Ordering.t
val precedence : t -> Precedence.t
val signature : t -> Signature.t

val state : t -> ProofState.t

val pp : Buffer.t -> t -> unit
val fmt : Format.formatter -> t -> unit

(** {2 High level operations} *)

type stats = int * int * int
  (** statistics on clauses : num active, num passive, num simplification *)

val cnf : env:t -> PFormula.Set.t -> Clause.CSet.t
  (** Reduce formulas to CNF *)

val stats : env:t -> stats
  (** Compute stats *)

val next_passive : env:t -> Clause.t option
  (** Extract next passive clause *)

val do_binary_inferences : env:t -> Clause.t -> Clause.t Sequence.t
  (** do binary inferences that involve the given clause *)

val do_unary_inferences : env:t -> Clause.t -> Clause.t Sequence.t
  (** do unary inferences for the given clause *)

val is_trivial : env:t -> Clause.t -> bool
  (** Check whether the clause is trivial (also with Experts) *)

val is_active : env:t -> Clause.t -> bool
  (** Is the clause in the active set *)

val is_passive : env:t -> Clause.t -> bool
  (** Is the clause a passive clause? *)

val simplify : env:t -> Clause.t -> Clause.t * Clause.t
  (** Simplify the hclause. Returns both the hclause and its simplification. *)

val backward_simplify : env:t -> Clause.t -> Clause.CSet.t * Clause.t Sequence.t
  (** Perform backward simplification with the given clause. It returns the
      CSet of clauses that become redundant, and the sequence of those
      very same clauses after simplification. *)

val forward_simplify : env:t -> Clause.t -> Clause.t
  (** Simplify the clause w.r.t to the active set and experts *)

val remove_orphans : env:t -> Clause.t Sequence.t -> unit
  (** remove orphans of the (now redundant) clauses *)

val generate : env:t -> Clause.t -> Clause.t Sequence.t
  (** Perform all generating inferences *)

val is_redundant : env:t -> Clause.t -> bool
  (** Is the given clause redundant w.r.t the active set? *)

val subsumed_by : env:t -> Clause.t -> Clause.CSet.t
  (** List of active clauses subsumed by the given clause *)

val all_simplify : env:t -> Clause.t -> Clause.t option
  (** Use all simplification rules to convert a clause into a maximally
      simplified clause (or None, if trivial). *)

val meta_step : env:t -> Clause.t -> Clause.t Sequence.t
  (** Do one step of the meta-prover with the current given clause. New clauses
      (lemmas) are returned. *)

