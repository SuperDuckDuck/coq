(************************************************************************)
(*  v      *   The Coq Proof Assistant  /  The Coq Development Team     *)
(* <O___,, * CNRS-Ecole Polytechnique-INRIA Futurs-Universite Paris Sud *)
(*   \VV/  **************************************************************)
(*    //   *      This file is distributed under the terms of the       *)
(*         *       GNU Lesser General Public License Version 2.1        *)
(************************************************************************)

(* $Id$ *)

open Pp
open Util
open Names
open Nameops
open Term
open Termops
open Sign
open Environ
open Evd
open Reductionops
open Rawterm
open Pattern
open Tacexpr
open Tacred
open Pretype_errors
open Evarutil
open Unification

(* *)
let w_coerce wc c ctyp target =
  let j = make_judge c ctyp in
  let env = Global.env_of_context wc.it in
  let isevars = create_evar_defs wc.sigma in
  let (evd',j') = Coercion.inh_conv_coerce_to dummy_loc env isevars j target in
  (evars_of evd',j'.uj_val)

let pf_env gls = Global.env_of_context gls.it.evar_hyps
let pf_type_of gls c  = Typing.type_of (pf_env gls) gls.sigma c
let pf_hnf_constr gls c = hnf_constr (pf_env gls) gls.sigma c
let pf_concl gl = gl.it.evar_concl

(* Generator of metavariables *)
let new_meta =
  let meta_ctr = ref 0 in
  fun () -> incr meta_ctr; !meta_ctr

(* replaces a mapping of existentials into a mapping of metas.
   Problem if an evar appears in the type of another one (pops anomaly) *)
let exist_to_meta sigma (emap, c) =
  let metamap = ref [] in
  let change_exist evar =
    let ty = nf_betaiota (nf_evar emap (existential_type emap evar)) in
    let n = new_meta() in
    metamap := (n, ty) :: !metamap;
    mkMeta n in
  let rec replace c =
    match kind_of_term c with
        Evar (k,_ as ev) when not (Evd.in_dom sigma k) -> change_exist ev
      | _ -> map_constr replace c in
  (!metamap, replace c)

(******************************************************************)
(* Clausal environments *)

type wc = named_context sigma

type clausenv = {
  templval : constr freelisted;
  templtyp : constr freelisted;
  namenv : identifier Metamap.t;
  env : meta_map;
  hook : wc }

let subst_clenv f sub clenv = 
  { templval = map_fl (subst_mps sub) clenv.templval;
    templtyp = map_fl (subst_mps sub) clenv.templtyp;
    namenv = clenv.namenv;
    env = Metamap.map (map_clb (subst_mps sub)) clenv.env;
    hook = f sub clenv.hook }

let clenv_nf_meta clenv c = nf_meta clenv.env c
let clenv_meta_type clenv mv = meta_type clenv.env mv
let clenv_value clenv = meta_instance clenv.env clenv.templval
let clenv_type clenv = meta_instance clenv.env clenv.templtyp

let cl_env ce = Global.env_of_context ce.hook.it

let clenv_hnf_constr ce t = hnf_constr (cl_env ce) ce.hook.sigma t

let clenv_get_type_of ce c =
  let metamap =
    List.map 
      (function
	 | (n,Clval(_,typ)) -> (n,typ.rebus)
         | (n,Cltyp typ)    -> (n,typ.rebus))
      (metamap_to_list ce.env) in
  Retyping.get_type_of_with_meta (cl_env ce) ce.hook.sigma metamap c



let clenv_environments bound c =
  let rec clrec (ne,e,metas) n c =
    match n, kind_of_term c with
      | (Some 0, _) -> (ne, e, List.rev metas, c)
      | (n, Cast (c,_)) -> clrec (ne,e,metas) n c
      | (n, Prod (na,c1,c2)) ->
	  let mv = new_meta () in
	  let dep = dependent (mkRel 1) c2 in
	  let ne' =
	    if dep then
              match na with
		| Anonymous -> ne
		| Name id ->
		    if metamap_in_dom mv ne then begin
		      warning ("Cannot put metavar "^(string_of_meta mv)^
			       " in name-environment twice");
		      ne
		    end else 
		      Metamap.add mv id ne
            else 
	      ne 
	  in
	  let e' = Metamap.add mv (Cltyp (mk_freelisted c1)) e in 
	  clrec (ne',e', (mkMeta mv)::metas) (option_app ((+) (-1)) n)
	    (if dep then (subst1 (mkMeta mv) c2) else c2)
      | (n, LetIn (na,b,_,c)) ->
	  clrec (ne,e,metas) (option_app ((+) (-1)) n) (subst1 b c)
      | (n, _) -> (ne, e, List.rev metas, c)
  in 
  clrec (Metamap.empty,Metamap.empty,[]) bound c

let mk_clenv_from_n gls n (c,cty) =
  let (namenv,env,args,concl) = clenv_environments n cty in
  { templval = mk_freelisted (match args with [] -> c | _ -> applist (c,args));
    templtyp = mk_freelisted concl;
    namenv = namenv;
    env = env;
    hook = {it=gls.it.evar_hyps; sigma=gls.sigma} }

let mk_clenv_from gls = mk_clenv_from_n gls None

let mk_clenv_rename_from gls (c,t) = 
  mk_clenv_from gls (c,rename_bound_var (pf_env gls) [] t)

let mk_clenv_rename_from_n gls n (c,t) = 
  mk_clenv_from_n gls n (c,rename_bound_var (pf_env gls) [] t)

let mk_clenv_type_of gls t = mk_clenv_from gls (t,pf_type_of gls t)

(******************************************************************)

(* [mentions clenv mv0 mv1] is true if mv1 is defined and mentions
 * mv0, or if one of the free vars on mv1's freelist mentions
 * mv0 *)

let mentions clenv mv0 = 
  let rec menrec mv1 =
    try
     (match Metamap.find mv1 clenv.env with
	 | Clval (b,_) -> 
	     Metaset.mem mv0 b.freemetas || meta_exists menrec b.freemetas
	 | Cltyp _ -> false)
    with Not_found -> 
      false
  in 
  menrec

let clenv_defined clenv mv = meta_defined clenv.env mv

(* TODO: replace by clenv_unify (mkMeta mv) rhs ? *)		      
let clenv_assign mv rhs clenv =
  let rhs_fls = mk_freelisted rhs in 
  if meta_exists (mentions clenv mv) rhs_fls.freemetas then
    error "clenv__assign: circularity in unification";
  try
    (match Metamap.find mv clenv.env with
       | Clval (fls,ty) ->
	   if not (eq_constr fls.rebus rhs) then
	     try 
	       (* Streams are lazy, force evaluation of id to catch Not_found*)
	       let id = Metamap.find mv clenv.namenv in
	       errorlabstrm "clenv_assign"
		 (str "An incompatible instantiation has already been found for " ++ 
		    pr_id id)
	     with Not_found ->
	       anomaly "clenv_assign: non dependent metavar already assigned"
	   else
	     clenv
       | Cltyp bty -> 
	   { templval = clenv.templval;
	     templtyp = clenv.templtyp;
	     namenv = clenv.namenv;
	     env = Metamap.add mv (Clval (rhs_fls,bty)) clenv.env;
	     hook = clenv.hook })
  with Not_found -> 
    error "clenv_assign"


let clenv_wtactic f clenv =
  let (evd',mmap') =
    f (create_evar_defs clenv.hook.sigma, clenv.env) in
  {clenv with env = mmap' ; hook = {it=clenv.hook.it; sigma=evars_of evd'}}


(* [clenv_dependent hyps_only clenv]
 * returns a list of the metavars which appear in the template of clenv,
 * and which are dependent, This is computed by taking the metavars in cval,
 * in right-to-left order, and collecting the metavars which appear
 * in their types, and adding in all the metavars appearing in the
 * type of clenv.
 * If [hyps_only] then metavariables occurring in the type are _excluded_ *)

(* collects all metavar occurences, in left-to-right order, preserving
 * repetitions and all. *)

let collect_metas c = 
  let rec collrec acc c =
    match kind_of_term c with
      | Meta mv -> mv::acc
      | _         -> fold_constr collrec acc c
  in
  List.rev (collrec [] c)

(* [clenv_metavars clenv mv]
 * returns a list of the metavars which appear in the type of
 * the metavar mv.  The list is unordered. *)

let clenv_metavars clenv mv = (meta_ftype clenv.env mv).freemetas

let dependent_metas clenv mvs conclmetas =
  List.fold_right
    (fun mv deps ->
       Metaset.union deps (clenv_metavars clenv mv))
    mvs conclmetas

let clenv_dependent hyps_only clenv =
  let mvs = collect_metas (clenv_value clenv) in
  let ctyp_mvs = (mk_freelisted (clenv_type clenv)).freemetas in
  let deps = dependent_metas clenv mvs ctyp_mvs in
  List.filter
    (fun mv -> Metaset.mem mv deps &&
               not (hyps_only && Metaset.mem mv ctyp_mvs))
    mvs

let clenv_missing ce = clenv_dependent true ce

(******************************************************************)

let clenv_unify allow_K cv_pb t1 t2 clenv =
  let env = cl_env clenv in
  clenv_wtactic (w_unify allow_K env cv_pb t1 t2) clenv

let clenv_unique_resolver allow_K clause gl =
  clenv_unify allow_K CUMUL (clenv_type clause) (pf_concl gl) clause 


(* [clenv_pose_dependent_evars clenv]
 * For each dependent evar in the clause-env which does not have a value,
 * pose a value for it by constructing a fresh evar.  We do this in
 * left-to-right order, so that every evar's type is always closed w.r.t.
 * metas. *)
let clenv_pose_dependent_evars clenv =
  let dep_mvs = clenv_dependent false clenv in
  List.fold_left
    (fun clenv mv ->
       let evar = Evarutil.new_evar_in_sign (cl_env clenv) in
       let (evar_n,_) = destEvar evar in
       let tY = clenv_meta_type clenv mv in
       let clenv' =
         clenv_wtactic (w_Declare (cl_env clenv) evar_n tY) clenv in
       clenv_assign mv evar clenv')
    clenv
    dep_mvs

let evar_clenv_unique_resolver clenv gls =
  clenv_pose_dependent_evars (clenv_unique_resolver false clenv gls)


(******************************************************************)

let connect_clenv gls clenv =
  let wc = {it=gls.it.evar_hyps; sigma=gls.sigma} in
  { clenv with hook = wc }

(* [clenv_fchain mv clenv clenv']
 *
 * Resolves the value of "mv" (which must be undefined) in clenv to be
 * the template of clenv' be the value "c", applied to "n" fresh
 * metavars, whose types are chosen by destructing "clf", which should
 * be a clausale forme generated from the type of "c".  The process of
 * resolution can cause unification of already-existing metavars, and
 * of the fresh ones which get created.  This operation is a composite
 * of operations which pose new metavars, perform unification on
 * terms, and make bindings.  *)
let clenv_fchain mv clenv nextclenv =
  (* Add the metavars of [nextclenv] to [clenv], with their name-environment *)
  let clenv' =
    { templval = clenv.templval;
      templtyp = clenv.templtyp;
      namenv =
	List.fold_left (fun ne (mv,id) ->
			  if clenv_defined nextclenv mv then 
			    ne
			  else if metamap_in_dom mv ne then begin
			    warning ("Cannot put metavar "^(string_of_meta mv)^
				     " in name-environment twice");
			    ne
			  end else 
			    Metamap.add mv id ne)
          clenv.namenv (metamap_to_list nextclenv.namenv);
      env = List.fold_left (fun m (n,v) -> Metamap.add n v m) 
	       clenv.env (metamap_to_list nextclenv.env);
      hook = nextclenv.hook } 
  in
  (* unify the type of the template of [nextclenv] with the type of [mv] *)
  let clenv'' =
    clenv_unify true CUMUL
      (clenv_nf_meta clenv' nextclenv.templtyp.rebus)
      (clenv_meta_type clenv' mv)
      clenv' 
  in
  (* assign the metavar *)
  let clenv''' =
    clenv_assign mv (clenv_nf_meta clenv' nextclenv.templval.rebus) clenv''
  in 
  clenv'''

(***************************************************************)
(* Bindings *)

type arg_bindings = (int * constr) list

(* [clenv_independent clenv]
 * returns a list of metavariables which appear in the term cval,
 * and which are not dependent.  That is, they do not appear in
 * the types of other metavars which are in cval, nor in the type
 * of cval, ctyp. *)

let clenv_independent clenv =
  let mvs = collect_metas (clenv_value clenv) in
  let ctyp_mvs = (mk_freelisted (clenv_type clenv)).freemetas in
  let deps = dependent_metas clenv mvs ctyp_mvs in
  List.filter (fun mv -> not (Metaset.mem mv deps)) mvs

let clenv_lookup_name clenv id =
  match metamap_inv clenv.namenv id with
    | []  -> 
	errorlabstrm "clenv_lookup_name"
          (str"No such bound variable " ++ pr_id id)
    | [n] -> 
	n
    |  _  -> 
	 anomaly "clenv_lookup_name: a name occurs more than once in clause"



let clenv_match_args s clause =
  let mvs = clenv_independent clause in 
  let rec matchrec clause = function
    | [] -> clause
    | (loc,b,c)::t ->
	let k =
	  match b with
            | NamedHyp s ->
		if List.exists (fun (_,b',_) -> b=b') t then 
		  errorlabstrm "clenv_match_args" 
		    (str "The variable " ++ pr_id s ++ 
		    str " occurs more than once in binding")
		else
		  clenv_lookup_name clause s
	    | AnonHyp n ->
		if List.exists (fun (_,b',_) -> b=b') t then
		  errorlabstrm "clenv_match_args"
		    (str "The position " ++ int n ++
		    str " occurs more than once in binding");
		try 
		  List.nth mvs (n-1)
		with (Failure _|Invalid_argument _) ->
                  errorlabstrm "clenv_match_args" (str "No such binder")
	in
	let k_typ = clenv_hnf_constr clause (clenv_meta_type clause k)
	(* nf_betaiota was before in type_of - useful to reduce types like *)
	(* (x:A)([x]P u) *)
	and c_typ =
          clenv_hnf_constr clause (nf_betaiota (clenv_get_type_of clause c)) in
	let cl =
	  (* Try to infer some Meta/Evar from the type of [c] *)
	  try 
            clenv_assign k c (clenv_unify true CUMUL c_typ k_typ clause)
	  with _ ->
	  (* Try to coerce to the type of [k]; cannot merge with the
	     previous case because Coercion does not handle Meta *)
          let (_,c') = w_coerce clause.hook c c_typ k_typ in
	  try clenv_unify true CONV (mkMeta k) c' clause
	  with PretypeError (env,CannotUnify (m,n)) ->
	    Stdpp.raise_with_loc loc
 	      (PretypeError (env,CannotUnifyBindingType (m,n)))
	in matchrec cl t
  in 
  matchrec clause s


let clenv_constrain_with_bindings bl clause =
  if bl = [] then 
    clause 
  else 
    let all_mvs = collect_metas clause.templval.rebus in
    let rec matchrec clause = function
      | []       -> clause
      | (n,c)::t ->
          let k = 
            (try
              if n > 0 then 
		List.nth all_mvs (n-1)
              else if n < 0 then 
		List.nth (List.rev all_mvs) (-n-1)
              else error "clenv_constrain_with_bindings" 
            with Failure _ ->
              errorlabstrm "clenv_constrain_with_bindings"
                (str"Clause did not have " ++ int n ++ str"-th" ++
                str" absolute argument")) in
	  let k_typ = nf_betaiota (clenv_meta_type clause k) in
	  let c_typ = nf_betaiota (clenv_get_type_of clause c) in 
	  matchrec
            (clenv_assign k c (clenv_unify true CUMUL c_typ k_typ clause)) t
    in 
    matchrec clause bl


(* not exported: maybe useful ? *)
let clenv_constrain_dep_args hyps_only clause = function
  | [] -> clause 
  | mlist ->
      let occlist = clenv_dependent hyps_only clause in
      if List.length occlist = List.length mlist then
	List.fold_left2
          (fun clenv k c ->
	    let wc = clause.hook in
	    try
	      let k_typ =
                clenv_hnf_constr clause (clenv_meta_type clause k) in
	      let c_typ =
                clenv_hnf_constr clause (clenv_get_type_of clause c) in
              (* faire quelque chose avec le sigma retourne ? *)
	      let (_,c') = w_coerce wc c c_typ k_typ in
	      clenv_unify true CONV (mkMeta k) c' clenv
	    with _ ->
              clenv_unify true CONV (mkMeta k) c clenv)
          clause occlist mlist
      else 
	error ("Not the right number of missing arguments (expected "
	       ^(string_of_int (List.length occlist))^")")

let clenv_constrain_missing_args mlist clause =
  clenv_constrain_dep_args true clause mlist


(***************************)

(* Clausal environment for an application *)

let make_clenv_binding_gen n gls (c,t) = function
  | ImplicitBindings largs ->
      let clause = mk_clenv_from_n gls n (c,t) in
      clenv_constrain_dep_args (n <> None) clause largs
  | ExplicitBindings lbind ->
      let clause = mk_clenv_rename_from_n gls n (c,t) in
      clenv_match_args lbind clause
  | NoBindings ->
      mk_clenv_from_n gls n (c,t)

let make_clenv_binding_apply wc n = make_clenv_binding_gen (Some n) wc
let make_clenv_binding = make_clenv_binding_gen None




(****************************************************************)

let pr_clenv clenv =
  let pr_name mv =
    try 
      let id = Metamap.find mv clenv.namenv in
      (str"[" ++ pr_id id ++ str"]")
    with Not_found -> (mt ())
  in
  let pr_meta_binding = function
    | (mv,Cltyp b) ->
      	hov 0 
	  (pr_meta mv ++ pr_name mv ++ str " : " ++ print_constr b.rebus ++ fnl ())
    | (mv,Clval(b,_)) ->
      	hov 0 
	  (pr_meta mv ++ pr_name mv ++ str " := " ++ print_constr b.rebus ++ fnl ())
  in
  (str"TEMPL: " ++ print_constr clenv.templval.rebus ++
     str" : " ++ print_constr clenv.templtyp.rebus ++ fnl () ++
     (prlist pr_meta_binding (metamap_to_list clenv.env)))
