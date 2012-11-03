{-# LANGUAGE FlexibleContexts #-}

-- | Interpreter for Boogie 2
module Language.Boogie.Interpreter (
  -- * Executing programs
  executeProgram,
  -- * State
  Value (..),
  Environment (..),
  emptyEnv,
  lookupFunction,
  lookupProcedure,
  modifyTypeContext,
  setV,
  setAll,
  -- * Executions
  Execution,
  SafeExecution,
  execSafely,
  execUnsafely,
  -- * Run-time failures
  FailureSource (..),
  InternalCode,
  StackFrame (..),
  StackTrace,
  RuntimeFailure (..),  
  FailureKind (..),
  failureKind,
  -- * Executing parts of programs
  eval,
  exec,
  execProcedure,
  collectDefinitions,
  -- * Pretty-printing
  valueDoc,
  varsDoc,
  functionsDoc,
  runtimeFailureDoc
  ) where

import Language.Boogie.AST
import Language.Boogie.Util
import Language.Boogie.Intervals
import Language.Boogie.Position
import Language.Boogie.Tokens (nonIdChar)
import Language.Boogie.PrettyPrinter
import Language.Boogie.TypeChecker
import Language.Boogie.NormalForm
import Language.Boogie.BasicBlocks
import Data.List
import Data.Map (Map, (!))
import qualified Data.Map as M
import Control.Monad.Error hiding (join)
import Control.Applicative hiding (empty)
import Control.Monad.State hiding (join)
import Text.PrettyPrint

{- Interface -}

-- | 'executeProgram' @p tc entryPoint@ :
-- Execute program @p@ in type context @tc@ starting from procedure @entryPoint@, 
-- and return the final environment;
-- requires that @entryPoint@ have no in- or out-parameters
executeProgram :: Program -> Context -> Id -> Either RuntimeFailure Environment
executeProgram p tc entryPoint = finalEnvironment
  where
    initEnvironment = emptyEnv { envTypeContext = tc }
    finalEnvironment = case runState (runErrorT programExecution) initEnvironment of
      (Left err, _) -> Left err
      (_, env)      -> Right env            
    programExecution = do
      execUnsafely $ collectDefinitions p
      execCall [] entryPoint [] noPos
              
{- State -}

-- | Run-time value
data Value = IntValue Integer |   -- ^ Integer value
  BoolValue Bool |                -- ^ Boolean value
  MapValue (Map [Value] Value) |  -- ^ Value of a map type
  CustomValue Integer             -- ^ Value of a user-defined type (values with the same code are considered equal)
  deriving (Eq, Ord)
      
-- | Default value of a type (used to initialize variables)  
defaultValue :: Type -> Value
defaultValue BoolType         = BoolValue False  
defaultValue IntType          = IntValue 0
defaultValue (MapType _ _ _)  = MapValue M.empty
defaultValue (IdType _ _)     = CustomValue 0

-- | Pretty-printed value
valueDoc :: Value -> Doc
valueDoc (IntValue n) = integer n
valueDoc (BoolValue False) = text "false"
valueDoc (BoolValue True) = text "true"
valueDoc (MapValue m) = brackets (commaSep (map itemDoc (M.toList m)))
  where itemDoc (keys, v) = commaSep (map valueDoc keys) <+> text "->" <+>  valueDoc v
valueDoc (CustomValue n) = text "custom_" <> integer n

instance Show Value where
  show v = show (valueDoc v)

-- | Execution state
data Environment = Environment
  {
    envLocals :: Map Id Value,          -- ^ Local variable names to values
    envGlobals :: Map Id Value,         -- ^ Global variable names to values
    envOld :: Map Id Value,             -- ^ Global variable names to old values (in two-state contexts)
    envConstants :: Map Id Expression,  -- ^ Constant names to expressions
    envFunctions :: Map Id [FDef],      -- ^ Function names to definitions
    envProcedures :: Map Id [PDef],     -- ^ Procedure names to definitions
    envTypeContext :: Context           -- ^ Type context
  }
   
-- | Empty environment   
emptyEnv = Environment
  {
    envLocals = M.empty,
    envGlobals = M.empty,
    envOld = M.empty,
    envConstants = M.empty,
    envFunctions = M.empty,
    envProcedures = M.empty,
    envTypeContext = emptyContext
  }
  
-- | 'lookupFunction' @id env@ : All definitions of function @id@ in @env@
lookupFunction id env = case M.lookup id (envFunctions env) of
  Nothing -> []
  Just defs -> defs    
  
-- | 'lookupProcedure' @id env@ : All definitions of procedure @id@ in @env@  
lookupProcedure id env = case M.lookup id (envProcedures env) of
  Nothing -> []
  Just defs -> defs  

setGlobal id val env = env { envGlobals = M.insert id val (envGlobals env) }    
setLocal id val env = env { envLocals = M.insert id val (envLocals env) }
addConstantDef id def env = env { envConstants = M.insert id def (envConstants env) }
addFunctionDefs id defs env = env { envFunctions = M.insert id (lookupFunction id env ++ defs) (envFunctions env) }
addProcedureDef id def env = env { envProcedures = M.insert id (def : (lookupProcedure id env)) (envProcedures env) } 
modifyTypeContext f env = env { envTypeContext = f (envTypeContext env) }

-- | Pretty-printed mapping of variables to values
varsDoc :: Map Id Value -> Doc
varsDoc vars = vsep $ map varDoc (M.toList vars)
  where varDoc (id, val) = text id <+> text "=" <+> valueDoc val
  
-- | Pretty-printed set of function definitions
functionsDoc :: Map Id [FDef] -> Doc  
functionsDoc funcs = vsep $ map funcDoc (M.toList funcs)
  where 
    funcDoc (id, defs) = vsep $ map (funcsDefDoc id) defs
    funcsDefDoc id (FDef formals guard body) = exprDoc guard <+> text "->" <+> 
      text id <> parens (commaSep (map text formals)) <+> text "=" <+> exprDoc body
      
{- Executions -}

-- | Computations with 'Environment' as state, which can result in either @a@ or 'RuntimeFailure'
type Execution a = ErrorT RuntimeFailure (State Environment) a

-- | Computations with 'Environment' as state, which always result in @a@
type SafeExecution a = State Environment a

-- | 'execUnsafely' @computation@ : Execute a safe @computation@ in an unsafe environment
execUnsafely :: SafeExecution a -> Execution a
execUnsafely computation = ErrorT (Right <$> computation)

-- | 'execSafely' @computation handler@ : Execute an unsafe @computation@ in a safe environment, handling errors that occur in @computation@ with @handler@
execSafely :: Execution a -> (RuntimeFailure -> SafeExecution a) -> SafeExecution a
execSafely computation handler = do
  eres <- runErrorT computation
  either handler return eres
  
-- | Computations that perform a cleanup at the end
class Monad m => Finalizer m where
  finally :: m a -> m () -> m a
    
instance (Monad m) => Finalizer (StateT s m) where
  finally main cleanup = do
    res <- main
    cleanup
    return res

instance (Error e, Monad m) => Finalizer (ErrorT e m) where
  finally main cleanup = do
    res <- main `catchError` (\err -> cleanup >> throwError err)
    cleanup
    return res  
          
-- | 'setV' @id val@ : set value of variable @id@ to @val@;
-- @id@ has to be declared in the current type context
setV id val = do
  tc <- gets envTypeContext
  if M.member id (localScope tc)
    then modify $ setLocal id val
    else modify $ setGlobal id val      
    
-- | 'setAll' @ids vals@ : set values of variables @ids@ to @vals@;
-- all @ids@ have to be declared in the current type context
setAll ids vals = zipWithM_ setV ids vals

-- | Run execution in the old environment
old :: Execution a -> Execution a
old execution = do
  env <- get
  put env { envGlobals = envOld env }
  res <- execution
  put env
  return res

-- | Save current values of global variables in the "old" environment, return the previous "old" environment
saveOld :: Execution (Map Id Value)  
saveOld = do
  env <- get
  put env { envOld = envGlobals env }
  return $ envOld env

-- | Set the "old" environment to olds  
restoreOld :: Map Id Value -> Execution ()  
restoreOld olds = do
  env <- get
  put env { envOld = olds }
  
-- | Enter local scope (apply localTC to the type context and assign actuals to formals),
-- execute computation,
-- then restore type context and local variables to their initial values
executeLocally :: (MonadState Environment m, Finalizer m) => (Context -> Context) -> [Id] -> [Value] -> m a -> m a
executeLocally localTC formals actuals computation = do
  oldEnv <- get
  modify $ modifyTypeContext localTC
  setAll formals actuals
  computation `finally` unwind oldEnv
  where
    -- | Restore type context and the values of local variables 
    unwind oldEnv = do
      env <- get
      put env { envTypeContext = envTypeContext oldEnv, envLocals = envLocals oldEnv }
              
{- Nondeterminism -}  
  
-- | Generate a value of type t,
-- such that when it is set, guard does not fail.
-- Fail if cannot find such a value.
-- (So far just returns the default value, but will be more elaborate in the future)
generateValue :: Type -> (Value -> Execution ()) -> (Execution ()) -> Execution Value          
generateValue t set guard = let newValue = defaultValue t in
  do
    set newValue 
    guard
    return newValue  
  
{- Runtime failures -}

data FailureSource = 
  SpecViolation SpecClause |    -- ^ Violation of user-defined specification
  DivisionByZero |              -- ^ Division by zero  
  UnsupportedConstruct String | -- ^ Language construct is not yet supported (should disappear in later versions)
  InfiniteDomain Id Interval |  -- ^ Quantification over an infinite set
  NoImplementation Id |         -- ^ Call to a procedure with no implementation
  InternalFailure InternalCode  -- ^ Must be cought inside the interpreter and never reach the user
  deriving Eq

-- | Information about a procedure or function call  
data StackFrame = StackFrame {
  callPos :: SourcePos, -- ^ Source code position of the call
  callName :: Id        -- ^ Name of procedure or function
} deriving Eq

type StackTrace = [StackFrame]

-- | Failures that occur during execution
data RuntimeFailure = RuntimeFailure {
  rtfSource :: FailureSource,   -- ^ Source of the failure
  rtfPos :: SourcePos,          -- ^ Location where the failure occurred
  rtfEnv :: Environment,        -- ^ Environment at the time of failure
  rtfTrace :: StackTrace        -- ^ Stack trace from the program entry point to the procedure where the failure occurred
}

-- | Throw a run-time failure
throwRuntimeFailure source pos = do
  env <- get
  throwError (RuntimeFailure source pos env [])

-- | Push frame on the stack trace of a runtime failure
addStackFrame frame (RuntimeFailure source pos env trace) = throwError (RuntimeFailure source pos env (frame : trace))

-- | Kinds of run-time failures
data FailureKind = Error | -- ^ Error state reached (assertion violation)
  Unreachable | -- ^ Unreachable state reached (assumption violation)
  Nonexecutable -- ^ The state is OK in Boogie semantics, but the execution cannot continue due to the limitations of the interpreter
  deriving Eq

-- | Kind of a run-time failure
failureKind :: RuntimeFailure -> FailureKind
failureKind err = case rtfSource err of
  SpecViolation (SpecClause _ True _) -> Unreachable
  SpecViolation (SpecClause _ False _) -> Error
  DivisionByZero -> Error
  _ -> Nonexecutable
  
instance Error RuntimeFailure where
  noMsg    = RuntimeFailure (UnsupportedConstruct "unknown") noPos emptyEnv []
  strMsg s = RuntimeFailure (UnsupportedConstruct s) noPos emptyEnv []
  
-- | Pretty-printed run-time failure
runtimeFailureDoc err = failureSourceDoc (rtfSource err) <+> posDoc (rtfPos err) $+$ 
  text "with" <+> varsDoc revelantVars $+$
  vsep (map stackFrameDoc (reverse (rtfTrace err)))
  where
    failureSourceDoc (SpecViolation (SpecClause specType isFree e)) = text (clauseName specType isFree) <+> doubleQuotes (exprDoc e) <+> defPosition specType e <+> text "violated"
    failureSourceDoc (DivisionByZero) = text "Division by zero"
    failureSourceDoc (InfiniteDomain var int) = text "Variable" <+> text var <+> text "quantified over an infinite domain" <+> text (show int)
    failureSourceDoc (NoImplementation name) = text "Procedure" <+> text name <+> text "with no implementation called"
    failureSourceDoc (UnsupportedConstruct s) = text "Unsupported construct" <+> text s
    
    clauseName Inline isFree = if isFree then "Assumption" else "Assertion"  
    clauseName Precondition isFree = if isFree then "Free precondition" else "Precondition"  
    clauseName Postcondition isFree = if isFree then "Free postcondition" else "Postcondition"  
    clauseName LoopInvariant isFree = if isFree then "Free loop invariant" else "Loop invariant"  
    clauseName Where True = "Where clause"  -- where clauses cannot be non-free  
    
    defPosition Inline _ = empty
    defPosition LoopInvariant _ = empty
    defPosition _ e = text "defined" <+> posDoc (position e)
    
    revelantVars = let env = rtfEnv err      
      in M.filterWithKey (\k _ -> isRelevant k) (envLocals env `M.union` envGlobals env)
      
    isRelevant k = case rtfSource err of
      SpecViolation (SpecClause _ _ expr) -> k `elem` freeVars expr
      _ -> False
    
    stackFrameDoc f = text "in call to" <+> text (callName f) <+> posDoc (callPos f)
    posDoc pos
      | pos == noPos = text "from the environment"
      | otherwise = text "at" <+> text (sourceName pos) <+> text "line" <+> int (sourceLine pos)

instance Show RuntimeFailure where
  show err = show (runtimeFailureDoc err)
  
-- | Internal error codes 
data InternalCode = NotLinear
  deriving Eq

throwInternalFailure code = throwRuntimeFailure (InternalFailure code) noPos

{- Expressions -}

-- | Semantics of unary operators
unOp :: UnOp -> Value -> Value
unOp Neg (IntValue n)   = IntValue (-n)
unOp Not (BoolValue b)  = BoolValue (not b)

-- | Semi-strict semantics of binary operators:
-- 'binOpLazy' @op lhs@ : returns the value of @lhs op@ if already defined, otherwise Nothing 
binOpLazy :: BinOp -> Value -> Maybe Value
binOpLazy And     (BoolValue False) = Just $ BoolValue False
binOpLazy Or      (BoolValue True)  = Just $ BoolValue True
binOpLazy Implies (BoolValue False) = Just $ BoolValue True
binOpLazy Explies (BoolValue True)  = Just $ BoolValue True
binOpLazy _ _                       = Nothing

-- | Strict semantics of binary operators
binOp :: SourcePos -> BinOp -> Value -> Value -> Execution Value 
binOp pos Plus    (IntValue n1) (IntValue n2)   = return $ IntValue (n1 + n2)
binOp pos Minus   (IntValue n1) (IntValue n2)   = return $ IntValue (n1 - n2)
binOp pos Times   (IntValue n1) (IntValue n2)   = return $ IntValue (n1 * n2)
binOp pos Div     (IntValue n1) (IntValue n2)   = if n2 == 0 
                                                then throwRuntimeFailure DivisionByZero pos
                                                else return $ IntValue (fst (n1 `euclidean` n2))
binOp pos Mod     (IntValue n1) (IntValue n2)   = if n2 == 0 
                                                then throwRuntimeFailure DivisionByZero pos
                                                else return $ IntValue (snd (n1 `euclidean` n2))
binOp pos Leq     (IntValue n1) (IntValue n2)   = return $ BoolValue (n1 <= n2)
binOp pos Ls      (IntValue n1) (IntValue n2)   = return $ BoolValue (n1 < n2)
binOp pos Geq     (IntValue n1) (IntValue n2)   = return $ BoolValue (n1 >= n2)
binOp pos Gt      (IntValue n1) (IntValue n2)   = return $ BoolValue (n1 > n2)
binOp pos And     (BoolValue b1) (BoolValue b2) = return $ BoolValue (b1 && b2)
binOp pos Or      (BoolValue b1) (BoolValue b2) = return $ BoolValue (b1 || b2)
binOp pos Implies (BoolValue b1) (BoolValue b2) = return $ BoolValue (b1 <= b2)
binOp pos Explies (BoolValue b1) (BoolValue b2) = return $ BoolValue (b1 >= b2)
binOp pos Equiv   (BoolValue b1) (BoolValue b2) = return $ BoolValue (b1 == b2)
binOp pos Eq      v1 v2                         = return $ BoolValue (v1 == v2)
binOp pos Neq     v1 v2                         = return $ BoolValue (v1 /= v2)
binOp pos Lc      v1 v2                         = throwRuntimeFailure (UnsupportedConstruct "orders") pos

-- | Euclidean division used by Boogie for integer division and modulo
euclidean :: Integer -> Integer -> (Integer, Integer)
a `euclidean` b =
  case a `quotRem` b of
    (q, r) | r >= 0    -> (q, r)
           | b >  0    -> (q - 1, r + b)
           | otherwise -> (q + 1, r - b)

-- | Evaluate an expression;
-- can have a side-effect of initializing variables that were not previously defined
eval :: Expression -> Execution Value
eval expr = case node expr of
  TT -> return $ BoolValue True
  FF -> return $ BoolValue False
  Numeral n -> return $ IntValue n
  Var id -> evalVar id (position expr)
  Application id args -> evalApplication id args (position expr)
  MapSelection m args -> evalMapSelection m args (position expr)
  MapUpdate m args new -> evalMapUpdate m args new
  Old e -> old $ eval e
  IfExpr cond e1 e2 -> evalIf cond e1 e2
  Coercion e t -> eval e
  UnaryExpression op e -> unOp op <$> eval e
  BinaryExpression op e1 e2 -> evalBinary op e1 e2
  Quantified Lambda _ _ _ -> throwRuntimeFailure (UnsupportedConstruct "lambda expressions") (position expr)
  Quantified Forall tv vars e -> vnot <$> evalExists tv vars (enot e) (position expr)
    where vnot (BoolValue b) = BoolValue (not b)
  Quantified Exists tv vars e -> evalExists tv vars e (position expr)
  
evalVar id pos = do
  tc <- gets envTypeContext
  case M.lookup id (localScope tc) of
    Just t -> lookup envLocals setLocal t
    Nothing -> case M.lookup id (ctxGlobals tc) of
      Just t -> lookup envGlobals setGlobal t
      Nothing -> case M.lookup id (ctxConstants tc) of
        Just t -> do
          constants <- gets envConstants
          case M.lookup id constants of
            Just e -> eval e
            Nothing -> return $ defaultValue t -- ToDo: cache constant value?
        Nothing -> (error . show) (text "encountered unknown identifier during execution:" <+> text id) 
  where
    lookup getter setter t = do
      vars <- gets getter
      case M.lookup id vars of
        Just val -> return val
        Nothing -> generateValue t (modify . setter id) (checkWhere id pos)
  
evalApplication name args pos = do
  defs <- gets (lookupFunction name)  
  evalDefs defs
  where
    -- | If the guard of one of function definitions evaluates to true, apply that definition; otherwise return the default value
    evalDefs :: [FDef] -> Execution Value
    evalDefs [] = defaultValue . returnType <$> gets envTypeContext
    evalDefs (FDef formals guard body : defs) = do
      argsV <- mapM eval args
      applicable <- evalLocally formals argsV guard `catchError` addStackFrame frame
      case applicable of
        BoolValue True -> evalLocally formals argsV body `catchError` addStackFrame frame 
        BoolValue False -> evalDefs defs
    evalLocally formals actuals expr = do
      sig <- funSig name <$> gets envTypeContext
      executeLocally (enterFunction sig formals args) formals actuals (eval expr)
    returnType tc = exprType tc (gen $ Application name args)
    frame = StackFrame pos name
    
evalMapSelection m args pos = do 
  tc <- gets envTypeContext
  let rangeType = exprType tc (gen $ MapSelection m args)
  mV <- eval m
  argsV <- mapM eval args
  case mV of 
    MapValue map -> case M.lookup argsV map of
      Nothing -> 
        case mapVariable tc (node m) of
        Nothing -> return $ defaultValue rangeType -- The underlying map comes from a constant or function, nothing to check
        Just v -> generateValue rangeType (\_ -> return ()) (checkWhere v pos) -- The underlying map comes from a variable: check the where clause
        -- Decided not to cache map access so far, because it leads to strange effects when the map is passed as an argument and can take a lot of memory 
        -- Just v -> generateValue rangeType (cache v map argsV) (checkWhere v pos) -- The underlying map comes from a variable: check the where clause and cache the value
      Just v -> return v
  where
    mapVariable tc (Var v) = if M.member v (allVars tc)
      then Just v
      else Nothing
    mapVariable tc (MapUpdate m _ _) = mapVariable tc (node m)
    mapVariable tc _ = Nothing 
    -- cache m map args val = setV m (MapValue (M.insert args val map))
    
evalMapUpdate m args new = do
  mV <- eval m
  argsV <- mapM eval args
  newV <- eval new
  case mV of 
    MapValue map -> return $ MapValue (M.insert argsV newV map)
  
evalIf cond e1 e2 = do
  v <- eval cond
  case v of
    BoolValue True -> eval e1    
    BoolValue False -> eval e2    
      
evalBinary op e1 e2 = do
  left <- eval e1
  case binOpLazy op left of
    Just result -> return result
    Nothing -> do
      right <- eval e2
      binOp (position e1) op left right

-- | Finite domain      
type Domain = [Value]      

evalExists :: [Id] -> [IdType] -> Expression -> SourcePos -> Execution Value      
evalExists tv vars e pos = do
  tc <- gets envTypeContext
  case node $ normalize tc (attachPos pos $ Quantified Exists tv vars e) of
    Quantified Exists tv' vars' e' -> evalExists' tv' vars' e'

evalExists' :: [Id] -> [IdType] -> Expression -> Execution Value    
evalExists' tv vars e = do
  results <- executeLocally (enterQuantified tv vars) [] [] evalWithDomains
  return $ BoolValue (any isTrue results)
  where
    evalWithDomains = do
      doms <- domains e varNames
      evalForEach varNames doms
    -- | evalForEach vars domains: evaluate e for each combination of possible values of vars, drown from respective domains
    evalForEach :: [Id] -> [Domain] -> Execution [Value]
    evalForEach [] [] = replicate 1 <$> eval e
    evalForEach (var : vars) (dom : doms) = concat <$> forM dom (fixOne vars doms var)
    -- | Fix the value of var to val, then evaluate e for each combination of values for the rest of vars
    fixOne :: [Id] -> [Domain] -> Id -> Value -> Execution [Value]
    fixOne vars doms var val = do
      setV var val
      evalForEach vars doms
    isTrue (BoolValue b) = b
    varNames = map fst vars
      
{- Statements -}

-- | Execute a basic statement
-- (no jump, if or while statements allowed)
exec :: Statement -> Execution ()
exec stmt = case node stmt of
  Predicate specClause -> execPredicate specClause (position stmt)
  Havoc ids -> execHavoc ids (position stmt)
  Assign lhss rhss -> execAssign lhss rhss
  Call lhss name args -> execCall lhss name args (position stmt)
  CallForall name args -> return () -- ToDo: assume (forall args :: pre ==> post)?
  
execPredicate specClause pos = do
  b <- eval $ specExpr specClause
  case b of 
    BoolValue True -> return ()
    BoolValue False -> throwRuntimeFailure (SpecViolation specClause) pos
    
execHavoc ids pos = do
  tc <- gets envTypeContext
  mapM_ (havoc tc) ids 
  where
    havoc tc id = generateValue (exprType tc . gen . Var $ id) (setV id) (checkWhere id pos) 
    
execAssign lhss rhss = do
  rVals <- mapM eval rhss'
  setAll lhss' rVals
  where
    lhss' = map fst (zipWith simplifyLeft lhss rhss)
    rhss' = map snd (zipWith simplifyLeft lhss rhss)
    simplifyLeft (id, []) rhs = (id, rhs)
    simplifyLeft (id, argss) rhs = (id, mapUpdate (gen $ Var id) argss rhs)
    mapUpdate e [args] rhs = gen $ MapUpdate e args rhs
    mapUpdate e (args1 : argss) rhs = gen $ MapUpdate e args1 (mapUpdate (gen $ MapSelection e args1) argss rhs)
    
execCall lhss name args pos = do
  tc <- gets envTypeContext
  defs <- gets (lookupProcedure name)
  case defs of
    [] -> throwRuntimeFailure (NoImplementation name) pos
    def : _ -> do
      let lhssExpr = map (attachPos (ctxPos tc) . Var) lhss
      retsV <- execProcedure (procSig name tc) def args lhssExpr `catchError` addStackFrame frame
      setAll lhss retsV
  where
    frame = StackFrame pos name
    
-- | Execute program consisting of blocks starting from the block labeled label.
-- Return the location of the exit point.
execBlock :: Map Id [Statement] -> Id -> Execution SourcePos
execBlock blocks label = let
  block = blocks ! label
  statements = init block
  in do
    mapM exec statements
    case last block of
      Pos pos Return -> return pos
      Pos _ (Goto lbs) -> tryOneOf blocks lbs
  
-- | tryOneOf blocks labels: try executing blocks starting with each of labels,
-- until we find one that does not result in an assumption violation      
tryOneOf :: Map Id [Statement] -> [Id] -> Execution SourcePos        
tryOneOf blocks (l : lbs) = execBlock blocks l `catchError` retry
  where
    retry err 
      | failureKind err == Unreachable && not (null lbs) = tryOneOf blocks lbs
      | otherwise = throwError err
  
-- | 'execProcedure' @sig def args lhss@ :
-- Execute definition @def@ of procedure @sig@ with actual arguments @args@ and call left-hand sides @lhss@
execProcedure :: PSig -> PDef -> [Expression] -> [Expression] -> Execution [Value]
execProcedure sig def args lhss = let 
  ins = pdefIns def
  outs = pdefOuts def
  blocks = snd (pdefBody def)
  exitPoint pos = if pos == noPos 
    then pdefPos def  -- Fall off the procedure body: take the procedure definition location
    else pos          -- A return statement inside the body
  execBody = do
    checkPreconditions sig def
    olds <- saveOld
    pos <- exitPoint <$> execBlock blocks startLabel
    checkPostonditions sig def pos
    restoreOld olds
    mapM (eval . attachPos (pdefPos def) . Var) outs
  in do
    argsV <- mapM eval args
    executeLocally (enterProcedure sig def args lhss) ins argsV execBody
    
{- Specs -}

-- | Assert preconditions of definition def of procedure sig
checkPreconditions sig def = mapM_ (exec . attachPos (pdefPos def) . Predicate . subst sig) (psigRequires sig)
  where 
    subst sig (SpecClause t f e) = SpecClause t f (paramSubst sig def e)

-- | Assert postconditions of definition def of procedure sig at exitPoint    
checkPostonditions sig def exitPoint = mapM_ (exec . attachPos exitPoint . Predicate . subst sig) (psigEnsures sig)
  where 
    subst sig (SpecClause t f e) = SpecClause t f (paramSubst sig def e)

-- | Assume where clause of variable at a program location pos
-- (pos will be reported as the location of the failure instead of the location of the variable definition).
checkWhere id pos = do
  whereClauses <- ctxWhere <$> gets envTypeContext
  case M.lookup id whereClauses of
    Nothing -> return ()
    Just w -> (exec . attachPos pos . Predicate . SpecClause Where True) w

{- Preprocessing -}

-- | Collect constant, function and procedure definitions from the program
collectDefinitions :: Program -> SafeExecution ()
collectDefinitions (Program decls) = mapM_ processDecl decls
  where
    processDecl (Pos _ (FunctionDecl name _ args _ (Just body))) = processFunctionBody name args body
    processDecl (Pos pos (ProcedureDecl name _ args rets _ (Just body))) = processProcedureBody name pos (map noWhere args) (map noWhere rets) body
    processDecl (Pos pos (ImplementationDecl name _ args rets bodies)) = mapM_ (processProcedureBody name pos args rets) bodies
    processDecl (Pos _ (AxiomDecl expr)) = processAxiom expr
    processDecl _ = return ()
  
processFunctionBody name args body = let
  formals = map (formalName . fst) args
  guard = gen TT
  in
    modify $ addFunctionDefs name [FDef formals guard body]
  where
    formalName Nothing = dummyFArg 
    formalName (Just n) = n    

processProcedureBody name pos args rets body = do
  sig <- procSig name <$> gets envTypeContext
  modify $ addProcedureDef name (PDef argNames retNames (paramsRenamed sig) (flatten body) pos) 
  where
    argNames = map fst args
    retNames = map fst rets
    flatten (locals, statements) = (concat locals, M.fromList (toBasicBlocks statements))
    paramsRenamed sig = map itwId (psigParams sig) /= (argNames ++ retNames)     

processAxiom expr = do
  extractConstantDefs expr
  extractFunctionDefs expr []
  
{- Constant and function definitions -}

-- | Extract constant definitions from a boolean expression bExpr
extractConstantDefs :: Expression -> SafeExecution ()
extractConstantDefs bExpr = case node bExpr of  
  BinaryExpression Eq (Pos _ (Var c)) rhs -> modify $ addConstantDef c rhs -- c == rhs: remember rhs as a definition for c
  _ -> return ()

-- | Extract function definitions from a boolean expression bExpr, using guards extracted from the exclosing expression.
-- bExpr of the form "(forall x :: P(x, c) ==> f(x, c) == rhs(x, c) && B) && A",
-- with zero or more bound variables x and zero or more constants c,
-- produces a definition "f(x, x') = rhs(x, x')" with a guard "P(x) && x' == c"
extractFunctionDefs :: Expression -> [Expression] -> SafeExecution ()
extractFunctionDefs bExpr guards = extractFunctionDefs' (node bExpr) guards

extractFunctionDefs' (BinaryExpression Eq (Pos _ (Application f args)) rhs) outerGuards = do
  c <- gets envTypeContext
  -- Only possible if each argument is either a variables or does not involve variables and there are no extra variables in rhs:
  if all (simple c) args && closedRhs c
    then do    
      let (formals, guards) = unzip (extractArgs c)
      let allGuards = concat guards ++ outerGuards
      let guard = if null allGuards then gen TT else foldl1 (|&|) allGuards
      modify $ addFunctionDefs f [FDef formals guard rhs]
    else return ()
  where
    simple _ (Pos p (Var _)) = True
    simple c e = null $ freeVars e `intersect` M.keys (ctxIns c)
    closedRhs c = null $ (freeVars rhs \\ concatMap freeVars args) `intersect` M.keys (ctxIns c)
    extractArgs c = zipWith (extractArg c) args [0..]
    -- | Formal argument name and guards extracted from an actual argument at position i
    extractArg :: Context -> Expression -> Integer -> (String, [Expression])
    extractArg c (Pos p e) i = let 
      x = freshArgName i 
      xExpr = attachPos p $ Var x
      in 
        case e of
          Var arg -> if arg `M.member` ctxIns c 
            then (arg, []) -- Bound variable of the enclosing quantifier: use variable name as formal, no additional guards
            else (x, [xExpr |=| Pos p e]) -- Constant: use fresh variable as formal (will only appear in the guard), add equality guard
          _ -> (x, [xExpr |=| Pos p e])
    freshArgName i = f ++ (nonIdChar : show i)
extractFunctionDefs' (BinaryExpression Implies cond bExpr) outerGuards = extractFunctionDefs bExpr (cond : outerGuards)
extractFunctionDefs' (BinaryExpression And bExpr1 bExpr2) outerGuards = do
  extractFunctionDefs bExpr1 outerGuards
  extractFunctionDefs bExpr2 outerGuards
extractFunctionDefs' (Quantified Forall tv vars bExpr) outerGuards = executeLocally (enterQuantified tv vars) [] [] (extractFunctionDefs bExpr outerGuards)
extractFunctionDefs' _ _ = return ()
   
{- Quantification -}

-- | Sets of interval constraints on integer variables
type Constraints = Map Id Interval
            
-- | The set of domains for each variable in vars, outside which boolean expression boolExpr is always false.
-- Fails if any of the domains are infinite or cannot be found.
domains :: Expression -> [Id] -> Execution [Domain]
domains boolExpr vars = do
  initC <- foldM initConstraints M.empty vars
  finalC <- inferConstraints boolExpr initC 
  forM vars (domain finalC)
  where
    initConstraints c var = do
      tc <- gets envTypeContext
      case M.lookup var (allVars tc) of
        Just BoolType -> return c
        Just IntType -> return $ M.insert var top c
        _ -> throwRuntimeFailure (UnsupportedConstruct "quantification over a map or user-defined type") (position boolExpr)
    domain c var = do
      tc <- gets envTypeContext
      case M.lookup var (allVars tc) of
        Just BoolType -> return $ map BoolValue [True, False]
        Just IntType -> do
          case c ! var of
            int | isBottom int -> return []
            Interval (Finite l) (Finite u) -> return $ map IntValue [l..u]
            int -> throwRuntimeFailure (InfiniteDomain var int) (position boolExpr)

-- | Starting from initial constraints, refine them with the information from boolExpr,
-- until fixpoint is reached or the domain for one of the variables is empty.
-- This function terminates because the interval for each variable can only become smaller with each iteration.
inferConstraints :: Expression -> Constraints -> Execution Constraints
inferConstraints boolExpr constraints = do
  constraints' <- foldM refineVar constraints (M.keys constraints)
  if bot `elem` M.elems constraints'
    then return $ M.map (const bot) constraints'  -- if boolExpr does not have a satisfying assignment to one variable, then it has none to all variables
    else if constraints == constraints'
      then return constraints'                    -- if a fixpoint is reached, return it
      else inferConstraints boolExpr constraints' -- otherwise do another iteration
  where
    refineVar :: Constraints -> Id -> Execution Constraints
    refineVar c id = do
      int <- inferInterval boolExpr c id
      return $ M.insert id (meet (c ! id) int) c 

-- | Infer an interval for variable x, outside which boolean expression booExpr is always false, 
-- assuming all other quantified variables satisfy constraints;
-- boolExpr has to be in negation-prenex normal form.
inferInterval :: Expression -> Constraints -> Id -> Execution Interval
inferInterval boolExpr constraints x = (case node boolExpr of
  FF -> return bot
  BinaryExpression And be1 be2 -> liftM2 meet (inferInterval be1 constraints x) (inferInterval be2 constraints x)
  BinaryExpression Or be1 be2 -> liftM2 join (inferInterval be1 constraints x) (inferInterval be2 constraints x)
  BinaryExpression Eq ae1 ae2 -> do
    (a, b) <- toLinearForm (ae1 |-| ae2) constraints x
    if 0 <: a && 0 <: b
      then return top
      else return $ -b // a
  BinaryExpression Leq ae1 ae2 -> do
    (a, b) <- toLinearForm (ae1 |-| ae2) constraints x
    if isBottom a || isBottom b
      then return bot
      else if 0 <: a && not (isBottom (meet b nonPositives))
        then return top
        else return $ join (lessEqual (-b // meet a positives)) (greaterEqual (-b // meet a negatives))
  BinaryExpression Ls ae1 ae2 -> inferInterval (ae1 |<=| (ae2 |-| num 1)) constraints x
  BinaryExpression Geq ae1 ae2 -> inferInterval (ae2 |<=| ae1) constraints x
  BinaryExpression Gt ae1 ae2 -> inferInterval (ae2 |<=| (ae1 |-| num 1)) constraints x
  -- Quantifier can only occur here if it is alternating with the enclosing one, hence no domain can be inferred 
  _ -> return top
  ) `catchError` handleNotLinear
  where      
    lessEqual int | isBottom int = bot
                  | otherwise = Interval NegInf (upper int)
    greaterEqual int  | isBottom int = bot
                      | otherwise = Interval (lower int) Inf
    handleNotLinear err = case rtfSource err of
      InternalFailure NotLinear -> return top
      _ -> throwError err                      

-- | Linear form (A, B) represents a set of expressions a*x + b, where a in A and b in B
type LinearForm = (Interval, Interval)

-- | If possible, convert arithmetic expression aExpr into a linear form over variable x,
-- assuming all other quantified variables satisfy constraints.
toLinearForm :: Expression -> Constraints -> Id -> Execution LinearForm
toLinearForm aExpr constraints x = case node aExpr of
  Numeral n -> return (0, fromInteger n)
  Var y -> if x == y
    then return (1, 0)
    else case M.lookup y constraints of
      Just int -> return (0, int)
      Nothing -> const aExpr
  Application name args -> if null $ M.keys constraints `intersect` freeVars aExpr
    then const aExpr
    else throwInternalFailure NotLinear
  MapSelection m args -> if null $ M.keys constraints `intersect` freeVars aExpr
    then const aExpr
    else throwInternalFailure NotLinear
  Old e -> old $ toLinearForm e constraints x
  UnaryExpression Neg e -> do
    (a, b) <- toLinearForm e constraints x
    return (-a, -b)
  BinaryExpression op e1 e2 -> do
    left <- toLinearForm e1 constraints x
    right <- toLinearForm e2 constraints x 
    combineBinOp op left right
  where
    const e = do
      v <- eval e
      case v of
        IntValue n -> return (0, fromInteger n)
    combineBinOp Plus   (a1, b1) (a2, b2) = return (a1 + a2, b1 + b2)
    combineBinOp Minus  (a1, b1) (a2, b2) = return (a1 - a2, b1 - b2)
    combineBinOp Times  (a, b)   (0, k)   = return (k * a, k * b)
    combineBinOp Times  (0, k)   (a, b)   = return (k * a, k * b)
    combineBinOp _ _ _ = throwInternalFailure NotLinear                      
  