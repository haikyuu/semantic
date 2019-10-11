{-# LANGUAGE DerivingVia, FlexibleContexts, FlexibleInstances, LambdaCase, MultiParamTypeClasses, NamedFieldPuns, OverloadedStrings, RankNTypes, RecordWildCards, TypeApplications, TypeOperators, UndecidableInstances #-}
module Analysis.Concrete
( Concrete(..)
, concrete
, concreteAnalysis
, heapGraph
, heapValueGraph
, heapAddressGraph
, addressStyle
) where

import qualified Algebra.Graph as G
import qualified Algebra.Graph.Export.Dot as G
import           Analysis.Analysis
import           Control.Applicative (Alternative (..))
import           Control.Carrier.Fail.WithLoc
import           Control.Effect
import           Control.Effect.Fresh
import           Control.Effect.NonDet
import           Control.Effect.Reader hiding (Local)
import           Control.Effect.State
import           Control.Monad ((<=<), guard)
import           Core.File
import           Core.Name
import           Data.Function (fix)
import qualified Data.IntMap as IntMap
import qualified Data.IntSet as IntSet
import qualified Data.Map as Map
import           Data.Semigroup (Last (..))
import qualified Data.Set as Set
import           Data.Text (Text, pack)
import           Data.Traversable (for)
import           Prelude hiding (fail)
import           Source.Span
import qualified System.Path as Path

type Precise = Int
type Env name = Map.Map name Precise

newtype FrameId = FrameId { unFrameId :: Precise }
  deriving (Eq, Ord, Show)

data Concrete term name
  = Closure Path.AbsRelFile Span name term (Env name)
  | Unit
  | Bool Bool
  | String Text
  | Record (Env name)
  deriving (Eq, Ord, Show)
  -- NB: We derive the 'Semigroup' instance for 'Concrete' to take the second argument. This is equivalent to stating that the return value of an imperative sequence of statements is the value of its final statement.
  deriving Semigroup via Last (Concrete term name)

recordFrame :: Concrete term name -> Maybe (Env name)
recordFrame (Record frame) = Just frame
recordFrame _              = Nothing

newtype Frame name = Frame
  { frameSlots :: Env name
  }
  deriving (Eq, Ord, Show)

type Heap term name = IntMap.IntMap (Concrete term name)

data Edge = Lexical | Import
  deriving (Eq, Ord, Show)


-- | Concrete evaluation of a term to a value.
--
--   >>> map fileBody (snd (concrete eval [File (Path.AbsRelFile "bool") (Span (Pos 1 1) (Pos 1 5)) (Core.bool True)]))
--   [Right (Bool True)]
concrete
  :: (Foldable term, Show (term Name))
  => (forall sig m
     .  (Carrier sig m, Member (Reader Path.AbsRelFile) sig, Member (Reader Span) sig, MonadFail m)
     => Analysis (term Name) Name Precise (Concrete (term Name) Name) m
     -> (term Name -> m (Concrete (term Name) Name))
     -> (term Name -> m (Concrete (term Name) Name))
     )
  -> [File (term Name)]
  -> (Heap (term Name) Name, [File (Either (Path.AbsRelFile, Span, String) (Concrete (term Name) Name))])
concrete eval
  = run
  . runFresh
  . runHeap
  . traverse (runFile eval)

runFile
  :: ( Carrier sig m
     , Effect sig
     , Foldable term
     , Member Fresh sig
     , Member (State (Heap (term Name) Name)) sig
     , Show (term Name)
     )
  => (forall sig m
     .  (Carrier sig m, Member (Reader Path.AbsRelFile) sig, Member (Reader Span) sig, MonadFail m)
     => Analysis (term Name) Name Precise (Concrete (term Name) Name) m
     -> (term Name -> m (Concrete (term Name) Name))
     -> (term Name -> m (Concrete (term Name) Name))
     )
  -> File (term Name)
  -> m (File (Either (Path.AbsRelFile, Span, String) (Concrete (term Name) Name)))
runFile eval file = traverse run file
  where run = runReader (filePath file)
            . runReader (fileSpan file)
            . runFail
            . runReader @(Env Name) mempty
            . fix (eval concreteAnalysis)

concreteAnalysis :: ( Carrier sig m
                    , Foldable term
                    , Member Fresh sig
                    , Member (Reader (Env Name)) sig
                    , Member (Reader Path.AbsRelFile) sig
                    , Member (Reader Span) sig
                    , Member (State (Heap (term Name) Name)) sig
                    , MonadFail m
                    , Show (term Name)
                    )
                 => Analysis (term Name) Name Precise (Concrete (term Name) Name) m
concreteAnalysis = Analysis{..}
  where alloc _ = fresh
        bind name addr m = local (Map.insert name addr) m
        lookupEnv n = asks (Map.lookup n)
        deref = gets . IntMap.lookup
        assign addr value = modify (IntMap.insert addr value)
        abstract _ name body = do
          path <- ask
          span <- ask
          env <- asks (flip Map.restrictKeys (Set.delete name (foldMap Set.singleton body)))
          pure (Closure path span name body env)
        apply eval (Closure path span name body env) a = do
          local (const path) . local (const span) $ do
            addr <- alloc name
            assign addr a
            local (const (Map.insert name addr env)) (eval body)
        apply _ f _ = fail $ "Cannot coerce " <> show f <> " to function"
        unit = pure Unit
        bool b = pure (Bool b)
        asBool (Bool b) = pure b
        asBool v        = fail $ "Cannot coerce " <> show v <> " to Bool"
        string s = pure (String s)
        asString (String s) = pure s
        asString v          = fail $ "Cannot coerce " <> show v <> " to String"
        record fields = do
          fields' <- for fields $ \ (name, value) -> do
            addr <- alloc name
            assign addr value
            pure (name, addr)
          pure (Record (Map.fromList fields'))
        addr ... n = do
          val <- deref addr
          heap <- get
          pure (val >>= lookupConcrete heap n)


lookupConcrete :: Heap term Name -> Name -> Concrete term Name -> Maybe Precise
lookupConcrete heap name = run . evalState IntSet.empty . runNonDet . inConcrete
  where -- look up the name in a concrete value
        inConcrete = inFrame <=< maybeA . recordFrame
        -- look up the name in a specific 'Frame', with slots taking precedence over parents
        inFrame fs = maybeA (Map.lookup name fs) <|> (maybeA (Map.lookup "__semantic_super" fs) >>= inAddress)
        -- look up the name in the value an address points to, if we haven’t already visited it
        inAddress addr = do
          visited <- get
          guard (addr `IntSet.notMember` visited)
          -- FIXME: throw an error if we can’t deref @addr@
          val <- maybeA (IntMap.lookup addr heap)
          modify (IntSet.insert addr)
          inConcrete val
        maybeA = maybe empty pure


runHeap :: StateC (Heap term name) m a -> m (Heap term name, a)
runHeap = runState mempty


-- | 'heapGraph', 'heapValueGraph', and 'heapAddressGraph' allow us to conveniently export SVGs of the heap:
--
--   > λ let (heap, res) = concrete [ruby]
--   > λ writeFile "/Users/rob/Desktop/heap.dot" (export (addressStyle heap) (heapAddressGraph heap))
--   > λ :!dot -Tsvg < ~/Desktop/heap.dot > ~/Desktop/heap.svg
heapGraph :: (Precise -> Concrete term name -> a) -> (Either Edge name -> Precise -> G.Graph a) -> Heap term name -> G.Graph a
heapGraph vertex edge h = foldr (uncurry graph) G.empty (IntMap.toList h)
  where graph k v rest = (G.vertex (vertex k v) `G.connect` outgoing v) `G.overlay` rest
        outgoing = \case
          Unit -> G.empty
          Bool _ -> G.empty
          String _ -> G.empty
          Closure _ _ _ _ env -> foldr (G.overlay . edge (Left Lexical)) G.empty env
          Record frame -> Map.foldrWithKey (\ k -> G.overlay . edge (Right k)) G.empty frame

heapValueGraph :: Heap term name -> G.Graph (Concrete term name)
heapValueGraph h = heapGraph (const id) (const fromAddr) h
  where fromAddr addr = maybe G.empty G.vertex (IntMap.lookup addr h)

heapAddressGraph :: Heap term Name -> G.Graph (EdgeType term Name, Precise)
heapAddressGraph = heapGraph (\ addr v -> (Value v, addr)) (fmap G.vertex . (,) . either Edge Slot)

addressStyle :: Heap term Name -> G.Style (EdgeType term Name, Precise) Text
addressStyle heap = (G.defaultStyle vertex) { G.edgeAttributes }
  where vertex (_, addr) = pack (show addr) <> " = " <> maybe "?" fromConcrete (IntMap.lookup addr heap)
        edgeAttributes _ (Slot name,    _) = ["label" G.:= unName name]
        edgeAttributes _ (Edge Import,  _) = ["color" G.:= "blue"]
        edgeAttributes _ (Edge Lexical, _) = ["color" G.:= "green"]
        edgeAttributes _ _                 = []
        fromConcrete = \case
          Unit ->  "()"
          Bool b -> pack $ show b
          String s -> pack $ show s
          Closure p (Span s e) n _ _ -> "\\\\ " <> unName n <> " [" <> pack (show p) <> ":" <> showPos s <> "-" <> showPos e <> "]"
          Record _ -> "{}"
        showPos (Pos l c) = pack (show l) <> ":" <> pack (show c)

data EdgeType term name
  = Edge Edge
  | Slot name
  | Value (Concrete term name)
  deriving (Eq, Ord, Show)


-- $setup
-- >>> :seti -XOverloadedStrings
-- >>> import qualified Core.Core as Core
