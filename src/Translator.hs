{-# LANGUAGE RecordWildCards #-}
module Translator where
import           AlloyOperators
import           SmtOperators
import           Alloy
import           Smt
import           Env

translateModel :: AlloyModel -> SmtProgram
translateModel model = program6
 where
  sigs     = signatures model
  program1 = declareSignatures emptyProgram sigs
  program2 = translateSignatures program1 sigs
  program3 = translateSignatureFacts program2 sigs
  program4 = translateFacts program3 (facts model)
  -- axioms for none, univAtom, univInt, intValue
  program5 = addSpecialAssertions program4
  program6 = translateCommands program5 (commands model)

translateSignatures :: SmtProgram -> [Sig] -> SmtProgram
--translateSignatures p [] = p
translateSignatures p xs = translateHierarchy p (filter isTopLevel xs)

declareSignatures :: SmtProgram -> [Sig] -> SmtProgram
declareSignatures p xs = foldl declareSignature p xs

declareSignature :: SmtProgram -> Sig -> SmtProgram
declareSignature p Univ      = addConstant p univAtom
declareSignature p SigInt    = addConstant p univInt
declareSignature p None      = addConstant p none
declareSignature _ SigString = undefined
declareSignature p sig       = addConstant
  p
  Variable { name = label sig, sort = s, isOriginal = True }
  where s = translateType (Prod [sig])

translateHierarchy :: SmtProgram -> [Sig] -> SmtProgram
translateHierarchy p xs = foldl translateSignature p xs

translateSignature :: SmtProgram -> Sig -> SmtProgram
translateSignature p Univ         = p
translateSignature p SigInt       = p
translateSignature p None         = p
translateSignature _ SigString    = undefined
translateSignature p PrimSig {..} = program5
 where
  program0 = foldl translateSignature p children
  program1 = translateMultiplicity program0 PrimSig { .. }
  program2 = translateParent program1 PrimSig { .. }
  program3 = translateDisjointChildren program2 PrimSig { .. }
  program4 = translateAbstract program3 PrimSig { .. }
  program5 = translateFields program4 PrimSig { .. }

translateSignature p SubsetSig {..} = program3
 where
  program1 = translateMultiplicity p SubsetSig { .. }
  program2 = translateParent program1 SubsetSig { .. }
  program3 = translateFields program2 SubsetSig { .. }

-- require sig is already defined in SMTScript p
translateMultiplicity :: SmtProgram -> Sig -> SmtProgram
-- sig a
-- use different from empty set
translateMultiplicity p sig = addAssertion assertion p
 where
  c           = getConstant p (label sig)
  s           = translateType (Prod [sig])
  x           = Variable { name = "x", sort = s, isOriginal = False }
  singleton   = (SmtUnary Singleton (SmtMultiArity MkTuple [Var x]))
  isSingleton = SmtBinary Eq (Var c) singleton
  subset      = SmtBinary Subset (Var c) singleton
  empty       = SmtUnary EmptySet (SortExpr (Set (Tuple [s])))
  existsOne   = SmtQt Exists [x] isSingleton
  existsSome  = SmtQt Exists [x] subset
  orExpr      = SmtMultiArity Or [existsOne, empty]
  assertion   = case (multiplicity sig) of
    ONEOF  -> Assertion ("one " ++ (label sig)) existsOne
    LONEOF -> Assertion ("lone " ++ (label sig)) orExpr
    SOMEOF -> Assertion ("some " ++ (label sig)) existsSome
    _      -> Assertion "" smtTrue

-- refactor this with subset 
translateParent :: SmtProgram -> Sig -> SmtProgram
translateParent p PrimSig {..} = addAssertion assertion p
 where
  childVar  = getConstant p primLabel
  parentVar = getConstant p (label parent)
  subset    = SmtBinary Subset (Var childVar) (Var parentVar)
  assertion = Assertion ("parent " ++ primLabel) subset

translateParent p SubsetSig {..} = addAssertion assertion p
 where
  childVar   = getConstant p subsetLabel
  parentVars = map (getConstant p . label) parents
  function parentVar = SmtBinary Subset (Var childVar) (Var parentVar)
  subsets   = SmtMultiArity And (map function parentVars)
  assertion = Assertion ("parents " ++ subsetLabel) subsets

translateParent _ _ = undefined


translateDisjointChildren :: SmtProgram -> Sig -> SmtProgram
translateDisjointChildren p PrimSig {..} = addAssertion assertion p
 where
  function (x, y) = SmtBinary Eq
                              empty
                              (SmtBinary Intersection (Var xVar) (Var yVar))
   where
    xVar = getConstant p (label x)
    yVar = getConstant p (label y)
  disjointChildren zs = map function zs
  sigSort   = translateType (Prod [PrimSig { .. }])
  empty     = SmtUnary EmptySet (SortExpr (Set (Tuple [sigSort])))
  pairs     = [ (u, v) | u <- children, v <- children, (label u) < (label v) ]
  andExpr   = SmtMultiArity And (disjointChildren pairs)
  assertion = Assertion ("disjoint children of " ++ primLabel) andExpr
translateDisjointChildren _ sig =
  error ((label sig) ++ " is not a prime signature")

translateAbstract :: SmtProgram -> Sig -> SmtProgram
translateAbstract p PrimSig {..} = case isAbstract && not (null children) of
  False -> p
  True  -> addAssertion assertion p
   where
    function x y = SmtBinary Union x y
    sigVar    = getConstant p primLabel
    union     = foldl function empty variables
    variables = map (Var . getConstant p . label) children
    sigSort   = translateType (Prod [PrimSig { .. }])
    empty     = SmtUnary EmptySet (SortExpr (Set (Tuple [sigSort])))
    equal     = SmtBinary Eq (Var sigVar) union
    assertion = Assertion ("Abstract " ++ primLabel) equal
translateAbstract _ sig = error ((label sig) ++ " is not a prime signature")

translateFields :: SmtProgram -> Sig -> SmtProgram
translateFields p sig = program3
 where
  sigFields = fields sig
  program1  = declareFields p sig sigFields
  program2  = translateDisjointFields program1 sigFields
  program3  = translateDisjoint2Fields program2 sigFields

declareFields :: SmtProgram -> Sig -> [Decl] -> SmtProgram
declareFields p sig decls = foldl (declareField sig)  p decls

declareField :: Sig -> SmtProgram -> Decl -> SmtProgram
declareField sig p Decl {..} = foldl addField p (splitDecl Decl { .. })
 where
  addField script Decl {..} = addConstant
    script
    Variable { name = concat names, sort = smtSort, isOriginal = True }
  smtSort = translateType (alloyType (AlloyBinary ARROW (Signature sig) expr))

translateDisjointFields :: SmtProgram -> [Decl] -> SmtProgram
translateDisjointFields p _ = p -- ToDo: fix this

translateDisjoint2Fields :: SmtProgram -> [Decl] -> SmtProgram
translateDisjoint2Fields p _ = p -- ToDo: fix this

translateSignatureFacts :: SmtProgram -> [Sig] -> SmtProgram
translateSignatureFacts p [] = p
translateSignatureFacts p xs = foldl translateSignatureFact p xs

translateSignatureFact :: SmtProgram -> Sig -> SmtProgram
translateSignatureFact p sig = case (sigfacts sig) of
  [] -> p
  _  -> undefined

translateFacts :: SmtProgram -> [Fact] -> SmtProgram
translateFacts p xs = foldl translateFact p xs

translateFact :: SmtProgram -> Fact -> SmtProgram
translateFact program (Fact name alloyExpr) = addAssertion assertion program
 where
  assertion    = Assertion name smtExpr
  (_, smtExpr) = translate (program, [], alloyExpr)

addSpecialAssertions :: SmtProgram -> SmtProgram
addSpecialAssertions p = p -- ToDo: change this later

translateCommands :: SmtProgram -> [Command] -> SmtProgram
translateCommands p xs = foldl translateCommand p xs

translateCommand :: SmtProgram -> Command -> SmtProgram
translateCommand _ _ = undefined

translate :: (SmtProgram, Env, AlloyExpr) -> (Env, SmtExpr)
translate (_, env, Signature x             ) = (env, get env (label x))
translate (_, _  , Field _                 ) = undefined
translate (_, _, (AlloyConstant _ sig)) = case sig of
  SigInt -> undefined
  _      -> error ("Constant " ++ " is not supported")
translate (_, _  , (AlloyUnary SOMEOF _)   ) = undefined
translate (_, _  , (AlloyUnary LONEOF _)   ) = undefined
translate (_, _  , (AlloyUnary ONEOF _)    ) = undefined
translate (_, _  , (AlloyUnary SETOF _)    ) = undefined
translate (_, _, (AlloyUnary EXACTLYOF _)) = undefined
translate (p, env, (AlloyUnary NOT x)) =
  (env, SmtUnary Not (second (translate (p, env, x))))
translate (_, _  , (AlloyUnary NO _)                 ) = undefined
translate (_, _  , (AlloyUnary SOME _)               ) = undefined
translate (_, _  , (AlloyUnary LONE _)               ) = undefined
translate (_, _  , (AlloyUnary ONE _)                ) = undefined
translate (_, _  , (AlloyUnary TRANSPOSE _)          ) = undefined
translate (_, _  , (AlloyUnary RCLOSURE _)           ) = undefined
translate (_, _  , (AlloyUnary CLOSURE _)            ) = undefined
translate (_, _  , (AlloyUnary CARDINALITY _)        ) = undefined
translate (_, _  , AlloyUnary CAST2INT _             ) = undefined
translate (_, _  , AlloyUnary CAST2SIGINT _          ) = undefined
translate (p, env, (AlloyUnary NOOP x)               ) = translate (p, env, x)
-- binary expressions
translate (_, _  , (AlloyBinary ARROW _ _)           ) = undefined
translate (_, _  , (AlloyBinary ANY_ARROW_SOME _ _)  ) = undefined
translate (_, _  , (AlloyBinary ANY_ARROW_ONE _ _)   ) = undefined
translate (_, _  , (AlloyBinary ANY_ARROW_LONE _ _)  ) = undefined
translate (_, _  , (AlloyBinary SOME_ARROW_ANY _ _)  ) = undefined
translate (_, _  , (AlloyBinary SOME_ARROW_SOME _ _) ) = undefined
translate (_, _  , (AlloyBinary SOME_ARROW_ONE _ _)  ) = undefined
translate (_, _  , (AlloyBinary SOME_ARROW_LONE _ _) ) = undefined
translate (_, _  , (AlloyBinary ONE_ARROW_ANY _ _)   ) = undefined
translate (_, _  , (AlloyBinary ONE_ARROW_SOME _ _)  ) = undefined
translate (_, _  , (AlloyBinary ONE_ARROW_ONE _ _)   ) = undefined
translate (_, _  , (AlloyBinary ONE_ARROW_LONE _ _)  ) = undefined
translate (_, _  , (AlloyBinary LONE_ARROW_ANY _ _)  ) = undefined
translate (_, _  , (AlloyBinary LONE_ARROW_SOME _ _) ) = undefined
translate (_, _  , (AlloyBinary LONE_ARROW_ONE _ _)  ) = undefined
translate (_, _  , (AlloyBinary LONE_ARROW_LONE _ _) ) = undefined
translate (_, _  , (AlloyBinary ISSEQ_ARROW_LONE _ _)) = undefined
translate (p, env, (AlloyBinary JOIN x y)) =
  ( env
  , SmtBinary Join
              (second (translate (p, env, x)))
              (second (translate (p, env, y)))
  )
translate (_, _, (AlloyBinary DOMAIN _ _)) = undefined
translate (_, _, (AlloyBinary RANGE _ _) ) = undefined
translate (p, env, (AlloyBinary INTERSECT x y)) =
  ( env
  , SmtBinary Intersection
              (second (translate (p, env, x)))
              (second (translate (p, env, y)))
  )
translate (_, _, (AlloyBinary PLUSPLUS _ _)) = undefined
translate (p, env, (AlloyBinary PLUS x y)) =
  ( env
  , SmtBinary Union
              (second (translate (p, env, x)))
              (second (translate (p, env, y)))
  )
translate (_, _, (AlloyBinary IPLUS _ _) ) = undefined
translate (_, _, (AlloyBinary MINUS _ _) ) = undefined
translate (_, _, (AlloyBinary IMINUS _ _)) = undefined
translate (_, _, (AlloyBinary MUL _ _)   ) = undefined
translate (_, _, (AlloyBinary DIV _ _)   ) = undefined
translate (_, _, (AlloyBinary REM _ _)   ) = undefined
translate (p, env, (AlloyBinary EQUALS x y)) =
  ( env
  , SmtBinary Eq
              (second (translate (p, env, x)))
              (second (translate (p, env, y)))
  )
translate (p, env, (AlloyBinary NOT_EQUALS x y)) =
  ( env
  , SmtUnary
    Not
    (SmtBinary Eq
               (second (translate (p, env, x)))
               (second (translate (p, env, y)))
    )
  )
translate (p, env, (AlloyBinary IMPLIES x y)) =
  ( env
  , SmtBinary Implies
              (second (translate (p, env, x)))
              (second (translate (p, env, y)))
  )
translate (p, env, (AlloyBinary Less x y)) =
  ( env
  , SmtBinary Lt
              (second (translate (p, env, x)))
              (second (translate (p, env, y)))
  )
translate (p, env, (AlloyBinary LTE x y)) =
  ( env
  , SmtBinary Lte
              (second (translate (p, env, x)))
              (second (translate (p, env, y)))
  )
translate (p, env, (AlloyBinary Greater x y)) =
  ( env
  , SmtBinary Gt
              (second (translate (p, env, x)))
              (second (translate (p, env, y)))
  )
translate (p, env, (AlloyBinary GTE x y)) =
  ( env
  , SmtBinary Gte
              (second (translate (p, env, x)))
              (second (translate (p, env, y)))
  )
translate (_, _, (AlloyBinary NOT_LT _ _) ) = undefined
translate (_, _, (AlloyBinary NOT_LTE _ _)) = undefined
translate (_, _, (AlloyBinary NOT_GT _ _) ) = undefined
translate (_, _, (AlloyBinary NOT_GTE _ _)) = undefined
translate (_, _, (AlloyBinary SHL _ _)    ) = undefined
translate (_, _, (AlloyBinary SHA _ _)    ) = undefined
translate (_, _, (AlloyBinary SHR _ _)    ) = undefined
translate (_, _, (AlloyBinary IN _ _)     ) = undefined
translate (p, env, (AlloyBinary NOT_IN x y)) = (env, SmtUnary Not expr)
  where (_, expr) =  translate (p, env, AlloyBinary IN x y)
translate (p, env, (AlloyBinary AND x y)) =
  ( env
  , SmtMultiArity
    And
    [(second (translate (p, env, x))), (second (translate (p, env, y)))]
  )
translate (p, env, (AlloyBinary OR x y)) =
  ( env
  , SmtMultiArity
    Or
    [(second (translate (p, env, x))), (second (translate (p, env, y)))]
  )
translate (p, env, (AlloyBinary IFF x y)) =
  ( env
  , SmtBinary Eq
              (second (translate (p, env, x)))
              (second (translate (p, env, y)))
  )
-- if then else expression
translate (p, env, (AlloyITE c x y)) =
  ( env
  , SmtIte (second (translate (p, env, c)))
           (second (translate (p, env, x)))
           (second (translate (p, env, y)))
  )
-- quantified expression
translate (_, _, (AlloyQt _ _ _) ) = undefined
-- let expression
translate (_, _, (AlloyLet _ _ _)) = undefined


-- types
translateType :: AlloyType -> Sort
translateType (Prod xs) = Set (Tuple ys)
  where ys = map (\x -> if isInt (Signature x) then UInt else Atom) xs
translateType AlloyBool = SmtBool
