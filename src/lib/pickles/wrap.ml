module SC = Scalar_challenge
module P = Proof
open Pickles_types
open Hlist
open Tuple_lib
open Common
open Core_kernel
open Async_kernel
open Import
open Types
open Backend

(* This contains the "wrap" prover *)

module Plonk_checks = struct
  include Plonk_checks
  module Type1 =
    Plonk_checks.Make (Shifted_value.Type1) (Plonk_checks.Scalars.Tick)
  module Type2 =
    Plonk_checks.Make (Shifted_value.Type2) (Plonk_checks.Scalars.Tock)
end

let vector_of_list (type a t)
    (module V : Snarky_intf.Vector.S with type elt = a and type t = t)
    (xs : a list) : t =
  let r = V.create () in
  List.iter xs ~f:(V.emplace_back r) ;
  r

let challenge_polynomial =
  Tick.Field.(Wrap_verifier.challenge_polynomial ~add ~mul ~one)

let tick_rounds = Nat.to_int Tick.Rounds.n

let combined_inner_product (type actual_proofs_verified) ~env ~domain ~ft_eval1
    ~actual_proofs_verified:
      (module AB : Nat.Add.Intf with type n = actual_proofs_verified)
    (e : _ Plonk_types.All_evals.With_public_input.t)
    ~(old_bulletproof_challenges : (_, actual_proofs_verified) Vector.t) ~r
    ~plonk ~xi ~zeta ~zetaw =
  let combined_evals =
    Plonk_checks.evals_of_split_evals ~zeta ~zetaw
      (module Tick.Field)
      ~rounds:tick_rounds e.evals
  in
  let ft_eval0 : Tick.Field.t =
    Plonk_checks.Type1.ft_eval0
      (module Tick.Field)
      ~env ~domain plonk
      (Plonk_types.Evals.to_in_circuit combined_evals)
      (fst e.public_input)
  in
  let T = AB.eq in
  let challenge_polys =
    Vector.map
      ~f:(fun chals -> unstage (challenge_polynomial (Vector.to_array chals)))
      old_bulletproof_challenges
  in
  let a = Plonk_types.Evals.to_list e.evals in
  let combine ~which_eval ~ft pt =
    let f (x, y) = match which_eval with `Fst -> x | `Snd -> y in
    let a = List.map ~f a in
    let v : Tick.Field.t array list =
      List.append
        (List.map (Vector.to_list challenge_polys) ~f:(fun f -> [| f pt |]))
        ([| f e.public_input |] :: [| ft |] :: a)
    in
    let open Tick.Field in
    Pcs_batch.combine_split_evaluations ~xi ~init:Fn.id
      ~mul_and_add:(fun ~acc ~xi fx -> fx + (xi * acc))
      v
  in
  let open Tick.Field in
  combine ~which_eval:`Fst ~ft:ft_eval0 zeta
  + (r * combine ~which_eval:`Snd ~ft:ft_eval1 zetaw)

module Step_acc = Tock.Inner_curve.Affine

(* The prover for wrapping a proof *)
let wrap
    (type actual_proofs_verified max_proofs_verified
    max_local_max_proofs_verifieds )
    ~(max_proofs_verified : max_proofs_verified Nat.t)
    (module Max_local_max_proof_verifieds : Hlist.Maxes.S
      with type ns = max_local_max_proofs_verifieds
       and type length = max_proofs_verified )
    (( module
      Req ) :
      (max_proofs_verified, max_local_max_proofs_verifieds) Requests.Wrap.t )
    ~dlog_plonk_index wrap_main ~(typ : _ Impls.Step.Typ.t) ~step_vk
    ~wrap_domains ~step_plonk_indices pk
    ({ statement = prev_statement; prev_evals; proof; index = which_index } :
      ( _
      , _
      , (_, actual_proofs_verified) Vector.t
      , (_, actual_proofs_verified) Vector.t
      , max_local_max_proofs_verifieds H1.T(P.Base.Me_only.Wrap).t
      , ( (Tock.Field.t, Tock.Field.t array) Plonk_types.All_evals.t
        , max_proofs_verified )
        Vector.t )
      P.Base.Step.t ) =
  let prev_me_only =
    let module M =
      H1.Map (P.Base.Me_only.Wrap) (P.Base.Me_only.Wrap.Prepared)
        (struct
          let f = P.Base.Me_only.Wrap.prepare
        end)
    in
    M.f prev_statement.pass_through
  in
  let prev_statement_with_hashes : _ Types.Step.Statement.t =
    { proof_state =
        { prev_statement.proof_state with
          me_only =
            (let to_field_elements =
               let (Typ typ) = typ in
               fun x -> fst (typ.value_to_fields x)
             in
             (* TODO: Careful here... the length of
                old_buletproof_challenges inside the me_only
                might not be correct *)
             Common.hash_step_me_only ~app_state:to_field_elements
               (P.Base.Me_only.Step.prepare ~dlog_plonk_index
                  prev_statement.proof_state.me_only ) )
        }
    ; pass_through =
        (let module M =
           H1.Map (P.Base.Me_only.Wrap.Prepared) (E01 (Digest.Constant))
             (struct
               let f (type n) (m : n P.Base.Me_only.Wrap.Prepared.t) =
                 Wrap_hack.hash_dlog_me_only
                   (Vector.length m.old_bulletproof_challenges)
                   m
             end)
         in
        let module V = H1.To_vector (Digest.Constant) in
        V.f Max_local_max_proof_verifieds.length (M.f prev_me_only) )
    }
  in
  let handler (Snarky_backendless.Request.With { request; respond }) =
    let open Req in
    let k x = respond (Provide x) in
    match request with
    | Evals ->
        k prev_evals
    | Step_accs ->
        let module M =
          H1.Map (P.Base.Me_only.Wrap.Prepared) (E01 (Step_acc))
            (struct
              let f : type a. a P.Base.Me_only.Wrap.Prepared.t -> Step_acc.t =
               fun t -> t.challenge_polynomial_commitment
            end)
        in
        let module V = H1.To_vector (Step_acc) in
        k (V.f Max_local_max_proof_verifieds.length (M.f prev_me_only))
    | Old_bulletproof_challenges ->
        let module M =
          H1.Map (P.Base.Me_only.Wrap.Prepared) (Challenges_vector.Constant)
            (struct
              let f (t : _ P.Base.Me_only.Wrap.Prepared.t) =
                t.old_bulletproof_challenges
            end)
        in
        k (M.f prev_me_only)
    | Messages ->
        k proof.messages
    | Openings_proof ->
        k proof.openings.proof
    | Proof_state ->
        k prev_statement_with_hashes.proof_state
    | Which_branch ->
        k which_index
    | _ ->
        Snarky_backendless.Request.unhandled
  in
  let module O = Tick.Oracles in
  let public_input =
    tick_public_input_of_statement ~max_proofs_verified
      prev_statement_with_hashes
  in
  let prev_challenges =
    Vector.map ~f:Ipa.Step.compute_challenges
      prev_statement.proof_state.me_only.old_bulletproof_challenges
  in
  let actual_proofs_verified = Vector.length prev_challenges in
  let lte =
    Nat.lte_exn actual_proofs_verified
      (Length.to_nat Max_local_max_proof_verifieds.length)
  in
  let o =
    let sgs =
      let module M =
        H1.Map (P.Base.Me_only.Wrap.Prepared) (E01 (Tick.Curve.Affine))
          (struct
            let f : type n. n P.Base.Me_only.Wrap.Prepared.t -> _ =
             fun t -> t.challenge_polynomial_commitment
          end)
      in
      let module V = H1.To_vector (Tick.Curve.Affine) in
      V.f Max_local_max_proof_verifieds.length (M.f prev_me_only)
    in
    O.create step_vk
      Vector.(
        map2 (Vector.trim sgs lte) prev_challenges ~f:(fun commitment cs ->
            { Tick.Proof.Challenge_polynomial.commitment
            ; challenges = Vector.to_array cs
            } )
        |> to_list)
      public_input proof
  in
  let x_hat = O.(p_eval_1 o, p_eval_2 o) in
  let next_statement : _ Types.Wrap.Statement.In_circuit.t =
    let scalar_chal f =
      Scalar_challenge.map ~f:Challenge.Constant.of_tick_field (f o)
    in
    let sponge_digest_before_evaluations = O.digest_before_evaluations o in
    let plonk0 =
      { Types.Wrap.Proof_state.Deferred_values.Plonk.Minimal.alpha =
          scalar_chal O.alpha
      ; beta = O.beta o
      ; gamma = O.gamma o
      ; zeta = scalar_chal O.zeta
      }
    in
    let r = scalar_chal O.u in
    let xi = scalar_chal O.v in
    let to_field =
      SC.to_field_constant
        (module Tick.Field)
        ~endo:Endo.Wrap_inner_curve.scalar
    in
    let module As_field = struct
      let r = to_field r

      let xi = to_field xi

      let zeta = to_field plonk0.zeta

      let alpha = to_field plonk0.alpha
    end in
    let domain = Domain.Pow_2_roots_of_unity step_vk.domain.log_size_of_group in
    let w = step_vk.domain.group_gen in
    (* Debug *)
    [%test_eq: Tick.Field.t] w
      (Tick.Field.domain_generator ~log2_size:(Domain.log2_size domain)) ;
    let zetaw = Tick.Field.mul As_field.zeta w in
    let tick_plonk_minimal =
      { plonk0 with zeta = As_field.zeta; alpha = As_field.alpha }
    in
    let tick_combined_evals =
      Plonk_checks.evals_of_split_evals
        (module Tick.Field)
        proof.openings.evals ~rounds:(Nat.to_int Tick.Rounds.n)
        ~zeta:As_field.zeta ~zetaw
    in
    let tick_domain =
      Plonk_checks.domain
        (module Tick.Field)
        domain ~shifts:Common.tick_shifts
        ~domain_generator:Backend.Tick.Field.domain_generator
    in
    let tick_combined_evals =
      Plonk_types.Evals.to_in_circuit tick_combined_evals
    in
    let tick_env =
      Plonk_checks.scalars_env
        (module Tick.Field)
        ~endo:Endo.Step_inner_curve.base ~mds:Tick_field_sponge.params.mds
        ~srs_length_log2:Common.Max_degree.step_log2
        ~field_of_hex:(fun s ->
          Kimchi_pasta.Pasta.Bigint256.of_hex_string s
          |> Kimchi_pasta.Pasta.Fp.of_bigint )
        ~domain:tick_domain tick_plonk_minimal tick_combined_evals
    in
    let combined_inner_product =
      let open As_field in
      combined_inner_product (* Note: We do not pad here. *)
        ~actual_proofs_verified:(Nat.Add.create actual_proofs_verified)
        { evals = proof.openings.evals; public_input = x_hat }
        ~r ~xi ~zeta ~zetaw ~old_bulletproof_challenges:prev_challenges
        ~env:tick_env ~domain:tick_domain ~ft_eval1:proof.openings.ft_eval1
        ~plonk:tick_plonk_minimal
    in
    let me_only : _ P.Base.Me_only.Wrap.t =
      { challenge_polynomial_commitment =
          proof.openings.proof.challenge_polynomial_commitment
      ; old_bulletproof_challenges =
          Vector.map prev_statement.proof_state.unfinalized_proofs ~f:(fun t ->
              t.deferred_values.bulletproof_challenges )
      }
    in
    let chal = Challenge.Constant.of_tick_field in
    let new_bulletproof_challenges, b =
      let prechals =
        Array.map (O.opening_prechallenges o) ~f:(fun x ->
            Scalar_challenge.map ~f:Challenge.Constant.of_tick_field x )
      in
      let chals =
        Array.map prechals ~f:(fun x -> Ipa.Step.compute_challenge x)
      in
      let challenge_poly = unstage (challenge_polynomial chals) in
      let open As_field in
      let b =
        let open Tick.Field in
        challenge_poly zeta + (r * challenge_poly zetaw)
      in
      let prechals =
        Array.map prechals ~f:(fun x ->
            { Bulletproof_challenge.prechallenge = x } )
      in
      (prechals, b)
    in
    let plonk =
      Plonk_checks.Type1.derive_plonk
        (module Tick.Field)
        ~shift:Shifts.tick1 ~env:tick_env tick_plonk_minimal tick_combined_evals
    in
    let shift_value =
      Shifted_value.Type1.of_field (module Tick.Field) ~shift:Shifts.tick1
    in
    let branch_data : Branch_data.t =
      { proofs_verified =
          ( match actual_proofs_verified with
          | Z ->
              Branch_data.Proofs_verified.N0
          | S Z ->
              N1
          | S (S Z) ->
              N2
          | _ ->
              assert false )
      ; domain_log2 =
          Branch_data.Domain_log2.of_int_exn step_vk.domain.log_size_of_group
      }
    in
    { proof_state =
        { deferred_values =
            { xi
            ; b = shift_value b
            ; bulletproof_challenges =
                Vector.of_array_and_length_exn new_bulletproof_challenges
                  Tick.Rounds.n
            ; combined_inner_product = shift_value combined_inner_product
            ; branch_data
            ; plonk =
                { plonk with
                  zeta = plonk0.zeta
                ; alpha = plonk0.alpha
                ; beta = chal plonk0.beta
                ; gamma = chal plonk0.gamma
                }
            }
        ; sponge_digest_before_evaluations =
            Digest.Constant.of_tick_field sponge_digest_before_evaluations
        ; me_only
        }
    ; pass_through = prev_statement.proof_state.me_only
    }
  in
  let me_only_prepared =
    P.Base.Me_only.Wrap.prepare next_statement.proof_state.me_only
  in
  let%map.Promise next_proof =
    let (T (input, conv, _conv_inv)) = Impls.Wrap.input () in
    Common.time "wrap proof" (fun () ->
        Impls.Wrap.generate_witness_conv
          ~f:(fun { Impls.Wrap.Proof_inputs.auxiliary_inputs; public_inputs } () ->
            Backend.Tock.Proof.create_async ~primary:public_inputs
              ~auxiliary:auxiliary_inputs pk
              ~message:
                ( Vector.map2
                    (Vector.extend_exn
                       prev_statement.proof_state.me_only
                         .challenge_polynomial_commitments max_proofs_verified
                       (Lazy.force Dummy.Ipa.Wrap.sg) )
                    me_only_prepared.old_bulletproof_challenges
                    ~f:(fun sg chals ->
                      { Tock.Proof.Challenge_polynomial.commitment = sg
                      ; challenges = Vector.to_array chals
                      } )
                |> Wrap_hack.pad_accumulator ) )
          [ input ]
          ~return_typ:(Snarky_backendless.Typ.unit ())
          (fun x () : unit ->
            Impls.Wrap.handle (fun () : unit -> wrap_main (conv x)) handler )
          { pass_through = prev_statement_with_hashes.proof_state.me_only
          ; proof_state =
              { next_statement.proof_state with
                me_only =
                  Wrap_hack.hash_dlog_me_only max_proofs_verified
                    me_only_prepared
              }
          } )
  in
  ( { proof = next_proof
    ; statement = Types.Wrap.Statement.to_minimal next_statement
    ; prev_evals =
        { Plonk_types.All_evals.evals =
            { public_input = x_hat; evals = proof.openings.evals }
        ; ft_eval1 = proof.openings.ft_eval1
        }
    }
    : _ P.Base.Wrap.t )
