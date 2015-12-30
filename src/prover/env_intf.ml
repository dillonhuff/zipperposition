
(* This file is free software, part of Zipperposition. See file "license" for more details. *)

open Libzipperposition

module type S = sig
  module Ctx : Ctx.S
  module C : Clause.S with module Ctx = Ctx
  module ProofState : ProofState.S with module C = C and module Ctx = Ctx

  type inf_rule = C.t -> C.t list
  (** An inference returns a list of conclusions *)

  type generate_rule = unit -> C.t list
  (** Generation of clauses regardless of current clause *)

  type binary_inf_rule = inf_rule
  type unary_inf_rule = inf_rule

  type simplify_rule = C.t -> C.t SimplM.t
  (** Simplify the clause structurally (basic simplifications),
      in the simplification monad.
      [(c, `Same)] means the clause has not been simplified;
      [(c, `New)] means the clause has been simplified at least once *)

  type active_simplify_rule = simplify_rule
  type rw_simplify_rule = simplify_rule

  type backward_simplify_rule = C.t -> C.CSet.t
  (** backward simplification by a unit clause. It returns a set of
      active clauses that can potentially be simplified by the given clause.
      [backward_simplify c] therefore returns a subset of
      [ProofState.ActiveSet.clauses ()] *)

  type redundant_rule = C.t -> bool
  (** check whether the clause is redundant w.r.t the set *)

  type backward_redundant_rule = C.CSet.t -> C.t -> C.CSet.t
  (** find redundant clauses in [ProofState.ActiveSet] w.r.t the clause.
       first param is the set of already known redundant clause, the rule
       should add clauses to it *)

  type is_trivial_rule = C.t -> bool
  (** Rule that checks whether the clause is trivial (a tautology) *)

  type term_rewrite_rule = FOTerm.t -> FOTerm.t option
  (** Rewrite rule on terms *)

  type lit_rewrite_rule = Literal.t -> Literal.t
  (** Rewrite rule on literals *)

  type multi_simpl_rule = C.t -> C.t list option
  (** (maybe) rewrite a clause to a set of clauses.
      Must return [None] if the clause is unmodified *)

  (** {2 Modify the Env} *)

  val add_passive : C.t Sequence.t -> unit
  (** Add passive clauses *)

  val add_active : C.t Sequence.t -> unit
  (** Add active clauses *)

  val add_simpl : C.t Sequence.t -> unit
  (** Add simplification clauses *)

  val remove_passive : C.t Sequence.t -> unit
  (** Remove passive clauses *)

  val remove_passive_id : int Sequence.t -> unit
  (** Remove passive clauses by their ID *)

  val remove_active : C.t Sequence.t -> unit
  (** Remove active clauses *)

  val remove_simpl  : C.t Sequence.t -> unit
  (** Remove simplification clauses *)

  val clean_passive : unit  -> unit
  (** Clean passive set (remove old clauses from clause queues) *)

  val get_passive : unit -> C.t Sequence.t
  (** Passive clauses *)

  val get_active : unit -> C.t Sequence.t
  (** Active clauses *)

  val add_binary_inf : string -> binary_inf_rule -> unit
  (** Add a binary inference rule *)

  val add_unary_inf : string -> unary_inf_rule -> unit
  (** Add a unary inference rule *)

  val add_rw_simplify : rw_simplify_rule -> unit
  (** Add forward rewriting rule *)

  val add_active_simplify : active_simplify_rule -> unit
  (** Add simplification w.r.t active set *)

  val add_backward_simplify : backward_simplify_rule -> unit
  (** Add simplification of the active set *)

  val add_redundant : redundant_rule -> unit
  (** Add redundancy criterion w.r.t. the active set *)

  val add_backward_redundant : backward_redundant_rule -> unit
  (** Add rule that finds redundant clauses within active set *)

  val add_simplify : simplify_rule -> unit
  (** Add basic simplification rule *)

  val add_multi_simpl_rule : multi_simpl_rule -> unit
  (** Add a multi-clause simplification rule *)

  val add_is_trivial : is_trivial_rule -> unit
  (** Add tautology detection rule *)

  val add_rewrite_rule : string -> term_rewrite_rule -> unit
  (** Add a term rewrite rule *)

  val add_lit_rule : string -> lit_rewrite_rule -> unit
  (** Add a literal rewrite rule *)

  val add_generate : string -> generate_rule -> unit

  val add_step_init : (unit -> unit) -> unit
  (** add a function to call before each saturation step *)

  (** {2 Use the Env} *)

  val multi_simplify : C.t -> C.t list option
  (** Can we simplify the clause into a List of simplified clauses? *)

  val params : Params.t

  val get_empty_clauses : unit -> C.CSet.t
  (** Set of known empty clauses *)

  val get_some_empty_clause : unit -> C.t option
  (** Some empty clause, if present, otherwise None *)

  val has_empty_clause : unit -> bool
  (** Is there an empty clause? *)

  val on_start : unit Signal.t
  (** Triggered before starting saturation *)

  val on_empty_clause : C.t Signal.t
  (** Signal triggered when an empty clause is found *)

  val ord : unit -> Ordering.t
  val precedence : unit -> Precedence.t
  val signature : unit -> Signature.t

  val pp : unit CCFormat.printer
  val pp_full : unit CCFormat.printer

  (** {2 High level operations} *)

  type stats = int * int * int
  (** statistics on clauses : num active, num passive, num simplification *)

  val stats : unit -> stats
  (** Compute stats *)

  val cnf : PFormula.t Sequence.t -> C.CSet.t
  (** Reduce formulas to CNF *)

  val next_passive : unit  -> C.t option
  (** Extract next passive clause *)

  val do_binary_inferences : C.t -> C.t Sequence.t
  (** do binary inferences that involve the given clause *)

  val do_unary_inferences : C.t -> C.t Sequence.t
  (** do unary inferences for the given clause *)

  val do_generate : unit -> C.t Sequence.t
  (** do generating inferences *)

  val is_trivial : C.t -> bool
  (** Check whether the clause is trivial *)

  val is_active : C.t -> bool
  (** Is the clause in the active set *)

  val is_passive : C.t -> bool
  (** Is the clause a passive clause? *)

  val simplify : simplify_rule
  (** Simplify the clause. *)

  val backward_simplify : C.t -> C.CSet.t * C.t Sequence.t
  (** Perform backward simplification with the given clause. It returns the
      CSet of clauses that become redundant, and the sequence of those
      very same clauses after simplification. *)

  val simplify_active_with : (C.t -> C.t list option) -> unit
  (** Can be called when a simplification relation becomes stronger,
      with the strengthened relation.
      (e.g. new axioms should be declared because a theory was detected).
      This will go through the whole active set, trying to simplify clauses
      with the given function. Simplified clauses will be put back in the
      passive set. *)

  val forward_simplify : simplify_rule
  (** Simplify the clause w.r.t to the active set and experts *)

  val generate : C.t -> C.t Sequence.t
  (** Perform all generating inferences *)

  val is_redundant : C.t -> bool
  (** Is the given clause redundant w.r.t the active set? *)

  val subsumed_by : C.t -> C.CSet.t
  (** List of active clauses subsumed by the given clause *)

  val all_simplify : C.t -> C.t list SimplM.t
  (** Use all simplification rules to convert a clause into a set
      of maximally simplified clause (or [[]] if they are all trivial). *)

  val step_init : unit -> unit
  (** call all functions registered with {!add_step_init} *)

  (** {2 Misc} *)

  val mixtbl : string CCMixtbl.t
  (** Global hashtable of "stuff" for this particular env *)
end
