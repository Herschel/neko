open Ast
open Mltype

type context = {
	mutable refvars : (string,unit) PMap.t;
}

let builtin name =
	EConst (Builtin name) , Ast.null_pos

let ident name =
	EConst (Ident name) , Ast.null_pos

let int n =
	EConst (Int n) , Ast.null_pos

let pos (p : Mlast.pos) = 
	{
		pmin = p.Mlast.pmin;
		pmax = p.Mlast.pmax;
		pfile = p.Mlast.pfile;
	}

let rec gen_constant ctx ?(path=[]) c =
	match c with
	| TVoid -> EConst Null
	| TTrue -> EConst True
	| TFalse -> EConst False
	| TInt n -> EConst (Int n)
	| TFloat s -> EConst (Float s)
	| TString s -> EConst (String s)
	| TIdent s -> 		
		if PMap.mem s ctx.refvars then EArray ((EConst (Ident s),null_pos),int 0) else EConst (Ident s)
	| TConstr s -> assert false
	| TModule (path,c) ->
		gen_constant ctx ~path c

let rec gen_expr ctx e =
	let p = pos e.epos in
	match e.edecl with
	| TConst c -> gen_constant ctx c , p
	| TBlock el -> EBlock (gen_block ctx el p) , p
	| TParenthesis e -> EParenthesis (gen_expr ctx e) , p
	| TCall (e,el) -> ECall (gen_expr ctx e, List.map (gen_expr ctx) el) , p
	| TField (e,s) -> EField (gen_expr ctx e, s) , p
	| TArray (e1,e2) -> EArray (gen_expr ctx e1,gen_expr ctx e2) , p
	| TVar (s,e) ->
		ctx.refvars <- PMap.remove s ctx.refvars;
		EVars [s , Some (gen_expr ctx e)] , p
	| TIf (e,e1,e2) -> EIf (gen_expr ctx e, gen_expr ctx e1, match e2 with None -> None | Some e2 -> Some (gen_expr ctx e2)) , p
	| TFunction _ -> gen_functions ctx [e] p
	| TBinop (op,e1,e2) -> EBinop (op,gen_expr ctx e1,gen_expr ctx e2) , p
	| TTupleDecl tl -> ECall (builtin "array",List.map (gen_expr ctx) tl) , p
	| TTypeDecl t -> EBlock [] , p
	| TMut e -> gen_expr ctx (!e)
	| TRecordDecl fl -> 
		EBlock (
			(EVars ["@o" , Some (ECall (builtin "object",[]),p) ] , p) ::
			List.map (fun (s,e) ->
				EBinop ("=",(EField (ident "@o",s),p),gen_expr ctx e) , pos e.epos
			) fl
			@ [ident "@o"]
		) , p
	| TListDecl el ->
		(match el with
		| [] -> ECall (builtin "array",[]) , p
		| x :: l ->
			ECall (builtin "array",[gen_expr ctx x; gen_expr ctx { e with edecl = TListDecl l }]) , p)
	| TUnop (op,e) -> 
		(match op with
		| "-" -> EBinop ("-",int 0,gen_expr ctx e) , p
		| "*" -> EArray (gen_expr ctx e,int 0) , p
		| "!" -> ECall (builtin "not",[gen_expr ctx e]) , p
		| "&" -> ECall (builtin "array",[gen_expr ctx e]) , p
		| _ -> assert false)
	| TMatch (e,pl) -> 
		assert false

and gen_functions ctx fl p =	
	let ell = ref (EVars (List.map (fun e ->
		match e.edecl with
		| TFunction (name,_,_) ->
			ctx.refvars <- PMap.add name () ctx.refvars;
			name , Some (ECall (builtin "array",[EConst Null,null_pos]),null_pos)
		| _ -> assert false
	) fl) , null_pos) in
	List.iter (fun e ->
		let p = pos e.epos in
		match e.edecl with
		| TFunction (name,params,e) ->
			let f() = 
				let e = gen_expr ctx e in
				EFunction (List.map fst params,match e with EBlock _ , _ -> e | _ -> EBlock [e] , p) , p 
			in
			if name = "_" then 
				ell := ENext (!ell,f()) , pos e.epos
			else begin
				let e = EBinop ("=",(EArray (ident name,int 0),p),f()) , p in
				let e = EBlock [e; EBinop ("=",ident name,(EArray (ident name,int 0),p)) , p] , p in		
				ell := ENext (!ell, e) , p;
			end;
			ctx.refvars <- PMap.remove name ctx.refvars;
		| _ ->
			assert false
	) fl;
	!ell

and gen_block ctx el p =	
	let old = ctx.refvars in
	let ell = ref [] in
	let rec loop fl = function
		| [] -> if fl <> [] then ell := gen_functions ctx (List.rev fl) p :: !ell
		| { edecl = TFunction (name,p,f) } as e :: l -> loop (e :: fl) l
		| { edecl = TMut r } :: l -> loop fl (!r :: l)
		| x :: l ->
			if fl <> [] then ell := gen_functions ctx (List.rev fl) p :: !ell;
			ell := gen_expr ctx x :: !ell;
			loop [] l
	in
	loop [] el;	
	ctx.refvars <- old;
	List.rev !ell

let generate e =
	let ctx = {
		refvars = PMap.empty;
	} in
	gen_expr ctx e