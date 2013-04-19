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

open Basic
open Symbols

(** A partial ordering on symbols *)

(** the partial order is the adjacency matrix of a DAG *)
type t = {
  num : int SHashtbl.t;           (** symbol -> index *)
  symbols : symbol array;         (** num -> symbol *)
  mutable total : bool;           (** is the order total? *)
  size : int;                     (** number of symbols in the table *)
  cmp : bool array array;         (** adjacency matrix *)
}

(** Compute the symbols from the symbol table *)
let compute_symbols num =
  let symbols = Array.make (SHashtbl.length num) (Obj.magic None) in
  SHashtbl.iter (fun s i -> symbols.(i) <- s) num;
  symbols

(** build an empty partial order for the list of symbols *)
let mk_partial_order symbs =
  let num = SHashtbl.create (List.length symbs) in
  let size = ref 0 in
  List.iter
    (fun s ->
      if SHashtbl.mem num s then ()
      else begin
        SHashtbl.replace num s !size;
        incr size;
      end)
    symbs;
  (* the symbols (num -> symbol) *)
  let symbols = compute_symbols num in
  (* the adjacency matrix *)
  let cmp = Array.make_matrix !size !size false in
  { num; size= !size; total=false; cmp; symbols; }

(** check whether the ordering is total *)
let check_is_total po =
  let n = po.size in
  try
    for i = 0 to n-1 do
      for j = i+1 to n-1 do
        if (not po.cmp.(i).(j)) && (not po.cmp.(j).(i))
          then raise Exit  (* pair of incomparable symbols *)
      done;
    done;
    true
  with Exit -> false

(** is the ordering total? *)
let is_total po =
  po.total ||
  (let res = check_is_total po in (if res then po.total <- true); res)

(** pretty print the partial order as a boolean matrix *)
let pp formatter po =
  let n = po.size in
  (* print num -> symbol *)
  Format.fprintf formatter "@[<v>total %B;@;" (is_total po);
  for i = 0 to n-1 do
    Format.fprintf formatter " @[<h>%2d: %s@]@;" i (name_symbol po.symbols.(i))
  done;
  (* print the matrix *)
  for i = 0 to n-1 do
    Format.fprintf formatter "@[<h>";
    for j = 0 to n-1 do
      Format.fprintf formatter " %d" (if po.cmp.(i).(j) then 1 else 0)
    done;
    Format.fprintf formatter "@]@;";
  done;
  Format.fprintf formatter "@]@;"

(** Compute the transitive closure where i>j has just been added. *)
let propagate po i j =
  assert (i <> j);
  let n = po.size in
  let cmp = po.cmp in
  (* propagate recursively *)
  let rec propagate i j =
    if cmp.(i).(j) then () (* stop *)
    else begin
      cmp.(i).(j) <- true;
      (* k > i and i > j -> k -> j *)
      for k = 0 to n-1 do
        if k <> i && cmp.(k).(i)
          then propagate k j
      done;
      (* i > j and j > k -> i -> k *)
      for k = 0 to n-1 do
        if k <> j && cmp.(j).(k)
          then propagate i k
      done;
    end
  in propagate i j

(** complete the partial order using the given order on
    symbols to compare unordered pairs. If the given comparison
    function is not total, the ordering may still not be
    complete. *)
let complete po cmp_fun =
  if po.total then ()
  else begin
    let n = po.size in
    let cmp = po.cmp in
    (* look for pairs that are not ordered *)
    for i = 0 to n - 1 do
      for j = i + 1 to n - 1 do
        if (not cmp.(i).(j)) && (not cmp.(j).(i)) then
          (* elements i and j not ordered, order them by cmp_fun
             and then re-compute the transitive closure *)
          (match cmp_fun po.symbols.(i) po.symbols.(j) with
          | n when n < 0 -> propagate po j i
          | n when n > 0 -> propagate po i j
          | _ -> ());
      done;
    done;
    po.total <- check_is_total po
  end

(** compare two symbols in the partial ordering *)
let compare po s t =
  assert (is_total po);
  let ns = SHashtbl.find po.num s
  and nt = SHashtbl.find po.num t in
  match po.cmp.(ns).(nt), po.cmp.(nt).(ns) with
  | true, false -> 1
  | false, true -> -1
  | false, false when s == t -> 0
  | _ ->
    Format.printf "symbs %a %d %a %d@." Symbols.pp_symbol s ns Symbols.pp_symbol t nt;
    Format.printf "PO: @[<v>%a@]@." pp po;
    assert false  (* non-total ordering *)

(** symbols, in decreasing order (assuming the ordering is total) *)
let symbols po =
  assert (is_total po);
  let s = Array.sub po.symbols 0 po.size in
  (* sort by decreasing order *)
  Array.fast_sort (fun x y -> - (compare po x y)) s;
  Array.to_list s

