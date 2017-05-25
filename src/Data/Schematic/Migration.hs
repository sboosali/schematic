{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE TemplateHaskell #-}

module Data.Schematic.Migration where

import Data.Kind
import Data.Schematic.Path
import Data.Schematic.Schema
import Data.Schematic.Utils
import Data.Singletons.Prelude hiding (All)
import Data.Singletons.TypeLits

class MigrateSchema (a :: Schema) (b :: Schema) where
  migrate :: JsonRepr a -> JsonRepr b

data Action = AddKey Symbol Schema | Update Schema | DeleteKey

data instance Sing (a :: Action) where
  SAddKey
    :: (Known (Sing n), Known (Sing s))
    => Sing n
    -> Sing s
    -> Sing ('AddKey n s)
  SUpdate :: Known (Sing s) => Sing s -> Sing ('Update s)
  SDelete :: Sing 'DeleteKey

instance (Known (Sing n), Known (Sing s)) => Known (Sing ('AddKey n s)) where
  known = SAddKey known known
instance (Known (Sing s)) => Known (Sing ('Update s)) where known = SUpdate known
instance Known (Sing 'DeleteKey) where known = SDelete

-- | User-supplied atomic difference between schemas.
-- Migrations can consists of many differences.
data Diff = Diff [PathSegment] Action

data instance Sing (diff :: Diff) where
  SDiff
    :: (Known (Sing jp), Known (Sing a))
    => Sing (jp :: [PathSegment])
    -> Sing (a :: Action)
    -> Sing ('Diff jp a)

type family TypedDiffList (s :: Schema) (ds :: [Diff]) :: Constraint where
  TypedDiffList s '[]       = ()
  TypedDiffList s (d ': tl) = (TypedDiff s d, TypedDiffList s tl)

type family TypedDiffListSchema (s :: Schema) (ds :: [Diff]) :: Schema where
  TypedDiffListSchema s '[]       = s
  TypedDiffListSchema s (d ': tl) = TypedDiffListSchema (TypedDiffSchema s d) tl

type family TypedDiff (s :: Schema) (d :: Diff) :: Constraint where
  TypedDiff s ('Diff ps a) = TypedSubSchema s ps

type family TypedDiffSchema (s :: Schema) (d :: Diff) :: Schema where
  TypedDiffSchema s ('Diff ps a) = TypedSubSchemaSchema s ps

type family TypedSubSchema (s :: Schema) (p :: [PathSegment]) :: Constraint where
  TypedSubSchema s '[]       = ()
  TypedSubSchema s (h ': tl) = TypedSubSchema (TraverseStep s h) tl

type family TypedSubSchemaSchema (s :: Schema) (p :: [PathSegment]) :: Schema where
  TypedSubSchemaSchema s '[] = s
  TypedSubSchemaSchema s (h ': tl) = TypedSubSchemaSchema (TraverseStep s h) tl

type family TraverseStep (s :: Schema) (ps :: PathSegment) :: Schema where
  TraverseStep ('SchemaArray acs s) ('Ix n)                = s
  TraverseStep ('SchemaObject ( '(fn, s) ': tl)) ('Key fn) = s
  TraverseStep ('SchemaObject ( h ': tl)) ('Key fn)        =
    TraverseStep ('SchemaObject tl) ('Key fn)

type family SubSchema (s :: Schema) (p :: [PathSegment]) where
  SubSchema s '[]       = s
  SubSchema s (h ': tl) = SubSchema (TraverseStep s h) tl

-- | User-provided name of the revision.
type Revision = Symbol

data Migration = Migration Revision [Diff]

type family TypedMigration (s :: Schema) (m :: Migration) :: Constraint where
  TypedMigration s ('Migration r ds) = (TypedDiffList s ds)

type family TypedMigrationSchema (s :: Schema) (m :: Migration) :: (Symbol, Schema) where
  TypedMigrationSchema s ('Migration r ds) = '(r, TypedDiffListSchema s ds)

data instance Sing (m :: Migration) where
  SMigration
    :: (KnownSymbol r, Known (Sing ds))
    => Sing r
    -> Sing ds
    -> Sing ('Migration r ds)

data Versioned = Versioned Schema [Migration]

type family TypedVersioned (s :: Schema) (ms :: [Migration]) :: Constraint where
  TypedVersioned s '[]       = ()
  TypedVersioned s (h ': tl) =
    ( TypedMigration s h
    , MigrateSchema s (Snd (TypedMigrationSchema s h))
    , TypedVersioned (Snd (TypedMigrationSchema s h)) tl )

type family TypedVersionedSchema

data instance Sing (v :: Versioned) where
  SVersioned
    :: (Known (Sing s), Known (Sing ms), TypedMigration s m)
    => Sing (s :: Schema)  -- base version
    -> Sing (ms :: [Migration]) -- a bunch of migrations
    -> Sing ('Versioned s ms)

type family HeadVersion (vd :: Versioned) :: Schema where
  HeadVersion ('Versioned s '[])        = s
  HeadVersion ('Versioned s (m ': tl))  =
    HeadVersion ('Versioned (Snd (TypedMigrationSchema s m)) tl)
