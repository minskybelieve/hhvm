(**
 * Copyright (c) 2014, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the "hack" directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *
 *)


(** Module used to suggest type annotations when they are missing
*)
open Utils
open Typing_defs

let compare_types x y =
  let tenv = Typing_env.empty "" in
  String.compare
    (Typing_print.full tenv x) (Typing_print.full tenv y)

type hint_kind =
  | Kmember of string
  | Kparam of string
  | Kreturn

let string_of_kind = function
  | Kmember s -> "Kmember:"^s
  | Kparam s -> "Kparam:"^s
  | Kreturn -> "Kreturn"

module Env = Typing_env
module TUtils = Typing_utils

(*****************************************************************************)
(* List of types found in a file. *)
(*****************************************************************************)

let (types: (Env.env * Pos.t * hint_kind * Typing_defs.ty) list ref) = ref []
let (initalized_members: (SSet.t SMap.t) ref) = ref SMap.empty

let add_type env pos k type_ =
  let new_type = (
    (* Some stuff in env isn't serializable, which we need so that we can infer
     * types part of the codebase at a time in worker threads. Fortunately we
     * don't actually need the whole env, so just keep the parts we do need for
     * typing, which *are* serializable. *)
    {(Env.empty "") with Env.tenv = env.Env.tenv; Env.subst = env.Env.subst},
    pos,
    k,
    type_
  ) in
  types := new_type :: !types

(*****************************************************************************)
(* Primitives used to save types (cf typing.ml). *)
(*****************************************************************************)

let save_type hint_kind env x arg =
  if !is_suggest_mode then begin
    match Typing_expand.fully_expand env x with
    | r, Tany ->
        let earg = Typing_expand.fully_expand env arg in
        (match earg with
        | _, Tany -> ()
        | _  ->
            let x_pos = Reason.to_pos (fst x) in
            add_type env x_pos hint_kind arg;
        )
    | _ -> ()
  end

let save_return env x arg = save_type Kreturn env x arg
let save_member name env x arg = save_type (Kmember name) env x arg
let save_param name env x arg = save_type (Kparam name) env x arg

(* Called when a member variable doesn't have a static initalizer, such as:
 *
 * class C {
 *   private $x;
 *   // As opposed to:
 *   // private $x = 42;
 * }
 *
 *)
let uninitalized_member cname mname env x arg = if !is_suggest_mode then begin
  match SMap.get cname !initalized_members with
    (* No static initalizer and no initalization in the constructor means that
     * this variable can be used before it's written to, and thus must be
     * nullable. *)
    | Some inits ->
      if not (SSet.mem mname inits)
      then save_member mname env x (fst x, Toption arg)

    (* Some constructions, such as traits, don't calculate initalized members.
     * TODO: this will suggest wrong types for some member variables defined in
     * traits, since they might be nullable, but that depends on the constructor
     * of the class that includes the trait (!). Not sure how to deal with this
     * right now, will just let the "revert bad patch" logic take care of it. *)
    | None -> ()
end

let save_initalized_members cname inits = if !is_suggest_mode then begin
  initalized_members := SMap.add cname inits !initalized_members
end

(* Normally, when we unify ?int and int, we don't want
 * them to be compatible, but here things are different,
 * we are trying to guess what the type should be.
*)
let rec my_unify depth env ty1 ty2 =
  let my_unify = my_unify (depth+1) in
  if depth > 10 then fst ty1, Tunresolved [ty1; ty2] else
  match ty1, ty2 with
  | (r, Tmixed), _
  | _, (r, Tmixed) -> r, Tmixed
  | (_, Tunresolved [ty1]), ty2
  | ty2, (_, Tunresolved [ty1]) ->
     my_unify env ty1 ty2
  | (r, Toption ty1), (_, Toption ty2) ->
      r, Toption (my_unify env ty1 ty2)
  | (r, Toption ty1), ty2
  | ty2, (r, Toption ty1) ->
      r, Toption (my_unify env ty1 ty2)
  | (r, Tarray _), (_, Tarray _) ->
      (try snd (Typing_ops.unify Pos.none Typing_reason.URnone env ty1 ty2)
      with _ -> (r, Tarray (false, None, None)))
  | (_, Tunresolved tyl), ty2
  | ty2, (_, Tunresolved tyl) ->
      List.fold_left (my_unify env) ty2 tyl
  | (r, _), _ -> snd (TUtils.fold_unresolved env (r, Tunresolved [ty1; ty2]))

(** returns the classes/interfaces implemented by a class
 * we are only interested in the non-parametric ones, infering
 * the parameter would be too hard anyway.
 *)
let get_implements (_, x) =
  match Env.Classes.get x with
  | None -> SSet.empty
  | Some { tc_ancestors = tyl; _ } ->
      SMap.fold begin fun _ ty set ->
        match ty with
        | _, Tapply ((_, x), []) -> SSet.add x set
        | _ -> raise Exit
      end tyl SSet.empty

(** normalizes a "guessed" type. We basically want to bailout whenever
 * the inferred type doesn't resolve to a type hint.
 *)
let rec normalize (r, ty) = r, normalize_ ty
and normalize_ = function
  | Tunresolved [x] -> snd (normalize x)
  | Tunresolved tyl
    when List.exists (function _, Toption _ -> true | _ -> false) tyl ->
      let tyl = List.map (function r, Toption ty -> ty | x -> x) tyl in
      normalize_ (Toption (Reason.Rnone, Tunresolved tyl))
  | Tunresolved tyl
    when List.exists (function _, (Tany | Tunresolved []) -> true | _ -> false) tyl ->
      let tyl = List.filter begin function
        |  _, (Tany |  Tunresolved []) -> false
        | _ -> true
      end tyl in
      normalize_ (Tunresolved tyl)
  | Tunresolved ((r, Tapply (x, [])) :: rl) ->
      (* If we have A & B & C where all the elements are classes
       * we try to find a unique common ancestor.
       *)
      let rl = List.map begin function
        | _, Tapply (x, []) -> x
        | _ -> raise Exit
      end rl in
      let x_imp = get_implements x in
      let set = List.fold_left begin fun x_imp x ->
        SSet.inter x_imp (get_implements x)
      end x_imp rl in
      (* is it unique? *)
      if SSet.cardinal set = 1
      then Tapply ((Pos.none, SSet.choose set), [])
      else raise Exit
  | Tunresolved (x :: (y :: _ as rl)) when compare_types x y = 0 ->
      normalize_ (Tunresolved rl)
  | Tunresolved _ | Tany -> raise Exit
  | Tmixed -> Tmixed                       (* ' with Nothing (mixed type) *)
  | Tarray (is_local, k, v) -> begin
    try Tarray (is_local, normalize_opt k, normalize_opt v)
    with Exit -> Tarray (false, None, None)
  end
  | Tgeneric _ as x -> x
  | Toption (_, (Toption (_, _) as ty)) -> normalize_ ty
  | Toption (_, Tprim Nast.Tvoid) -> raise Exit
  | Toption ty -> Toption (normalize ty)
  | Tprim _ as ty -> ty
  | Tvar _ -> raise Exit
  | Tfun _ -> raise Exit
  | Tapply ((pos1, "Awaitable"), [(_, Toption (pos2, Tprim Nast.Tvoid))]) ->
      (* Special case: Awaitable<?void> is nonsensical, but often
       * Awaitable<void> works. *)
      Tapply ((pos1, "Awaitable"), [(pos2, Tprim Nast.Tvoid)])
  | Tapply ((pos, name), tyl) ->
      (* Handling xhp names *)
      let name =
        if String.contains name ':' && name.[0] <> ':'
        then ":"^name
        else name
      in
      Tapply ((pos, name), List.map normalize tyl)
  | Ttuple tyl -> Ttuple (List.map normalize tyl)
  | Tanon _ -> raise Exit
  | Tobject -> raise Exit
  | Tabstract _ -> raise Exit
  | Tshape _ -> raise Exit

and normalize_opt = function None -> None | Some x -> Some (normalize x)

let normalize ty =
  try
    Some (normalize ty)
  with Exit -> None

(* Function called when we found a missing ? *)
let save_qm p =
  (*
  if !save_types
  then save_qms := PSet.add p !save_qms
  else ()
*)
  ()
