{-# LANGUAGE DataKinds, MultiParamTypeClasses, TypeFamilies #-}
module Control.Abstract.Analysis
( MonadAnalysis(..)
, evaluateTerm
, require
, load
, liftAnalyze
, runAnalysis
, module X
, Subterm(..)
, SubtermAlgebra
) where

import Control.Abstract.Evaluator as X
import Control.Effect as X
import Control.Monad.Effect.Fail as X
import Control.Monad.Effect.Fresh as X
import Control.Monad.Effect.NonDet as X
import Control.Monad.Effect.Reader as X
import Control.Monad.Effect.State as X
import Data.Abstract.Environment
import Data.Abstract.ModuleTable
import Data.Abstract.Value
import Data.Coerce
import qualified Data.Map as Map
import Prelude hiding (fail)
import Prologue

-- | A 'Monad' in which one can evaluate some specific term type to some specific value type.
--
--   This typeclass is left intentionally unconstrained to avoid circular dependencies between it and other typeclasses.
class (MonadEvaluator term value m, Recursive term) => MonadAnalysis term value m where
  -- | The effects necessary to run the analysis. Analyses which are composed on top of (wrap) other analyses should include the inner analyses 'RequiredEffects' in their own list.
  type family RequiredEffects term value m :: [* -> *]

  -- | Analyze a term using the semantics of the current analysis. This should generally only be called by definitions of 'evaluateTerm' and 'analyzeTerm' in this or other instances.
  analyzeTerm :: SubtermAlgebra (Base term) term (m value)

  -- | Evaluate a (root-level) term to a value using the semantics of the current analysis. This should be used to evaluate single-term programs as well as each module in multi-term programs.
  evaluateModule :: term -> m value
  evaluateModule = evaluateTerm

-- | Evaluate a term to a value using the semantics of the current analysis.
--
--   This should always be called when e.g. evaluating the bodies of closures instead of explicitly folding either 'eval' or 'analyzeTerm' over subterms, except in 'MonadAnalysis' instances themselves. On the other hand, top-level evaluation should be performed using 'evaluateModule'.
evaluateTerm :: MonadAnalysis term value m => term -> m value
evaluateTerm = foldSubterms analyzeTerm


-- | Require/import another term/file and return an Effect.
--
-- Looks up the term's name in the cache of evaluated modules first, returns a value if found, otherwise loads/evaluates the module.
require :: ( MonadAnalysis term value m
           , Ord (LocationFor value)
           )
        => ModuleName
        -> m (EnvironmentFor value)
require name = getModuleTable >>= maybe (load name) pure . moduleTableLookup name

-- | Load another term/file and return an Effect.
--
-- Always loads/evaluates.
load :: ( MonadAnalysis term value m
        , Ord (LocationFor value)
        )
     => ModuleName
     -> m (EnvironmentFor value)
load name = askModuleTable >>= maybe notFound evalAndCache . moduleTableLookup name
  where notFound = fail ("cannot load module: " <> show name)
        evalAndCache e = do
          void $ evaluateModule e
          -- TODO: If the set of exports is empty because no exports have been
          -- defined, do we export all terms, or no terms? This behavior varies across
          -- languages. We need better semantics rather than doing it ad-hoc.
          env <- getGlobalEnv
          exports <- getExports
          let env' = if Map.null exports then env else bindExports exports env
          modifyModuleTable (moduleTableInsert name env')
          pure env'


-- | Lift a 'SubtermAlgebra' for an underlying analysis into a containing analysis. Use this when defining an analysis which can be composed onto other analyses to ensure that a call to 'analyzeTerm' occurs in the inner analysis and not the outer one.
liftAnalyze :: ( Coercible (  m term value (effects :: [* -> *]) value) (t m term value effects value)
               , Coercible (t m term value effects value) (  m term value effects value)
               , Functor (Base term)
               )
            => SubtermAlgebra (Base term) term (  m term value effects value)
            -> SubtermAlgebra (Base term) term (t m term value effects value)
liftAnalyze analyze term = coerce (analyze (second coerce <$> term))


-- | Run an analysis, performing its effects and returning the result alongside any state.
--
--   This enables us to refer to the analysis type as e.g. @Analysis1 (Analysis2 Evaluating) Term Value@ without explicitly mentioning its effects (which are inferred to be simply its 'RequiredEffects').
runAnalysis :: ( Effectful m
               , RunEffects effects a
               , RequiredEffects term value (m effects) ~ effects
               , MonadAnalysis term value (m effects)
               )
            => m effects a
            -> Final effects a
runAnalysis = run
