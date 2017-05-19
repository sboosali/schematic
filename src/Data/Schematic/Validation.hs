{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -fprint-explicit-kinds #-}

module Data.Schematic.Validation where

import Control.Applicative
import Control.Category ((<<<), (>>>))
import Control.Monad
import Data.Aeson as J
import Data.Aeson.Types as J
import Data.Eq.Deriving (deriveEq1)
import Data.Foldable as F
import Data.Functor.Classes
import Data.Functor.Foldable
import Data.HashMap.Strict as H
import Data.Kind
import Data.Maybe
import Data.Scientific
import Data.Singletons.Decide
import Data.Singletons.Prelude.List
import Data.Singletons.TH
import Data.Singletons.TypeLits
import Data.Text as T
import Data.Vector as V
import Data.Vinyl hiding (Dict)
import Data.Vinyl.Functor
import Text.Show.Deriving (deriveShow1)


-- -- | Type Tags
data JType
  = JText
  | JNumber
  | JArray
  | JObject
  | JNull
  deriving (Show, Eq)

genSingletons [ ''JType ]

-- instance Show (Sing JText) where showsPrec 4 _ = showString "SJText"
-- instance Show (Sing JNumber) where showsPrec 4 _ = showString "SJNumber"
-- instance Show (Sing JArray) where showsPrec 4 _ = showString "SJArray"
-- instance Show (Sing JObject) where showsPrec 4 _ = showString "SJObject"
-- instance Show (Sing JNull) where showsPrec 4 _ = showString "SJNull"

-- instance Eq (Sing JText) where (==) _ _ = True
-- instance Eq (Sing JNumber) where (==) _ _ = True
-- instance Eq (Sing JArray) where (==) _ _ = True
-- instance Eq (Sing JObject) where (==) _ _ = True
-- instance Eq (Sing JNull) where (==) _ _ = True

type family CRepr (jty :: Schema) :: Type where
  CRepr (SchemaText cs)  = TextConstraint
  CRepr (SchemaNumber cs) = NumberConstraint
  CRepr (SchemaObject fs) = (String, Schema)
  CRepr (SchemaArray ar s) = ArrayConstraint

data TextConstraint
  = TEq Nat
  | TLe Nat
  | TGt Nat
  | Regex Symbol

data instance Sing (tc :: TextConstraint) where
  STextLengthEq :: Sing n -> Sing (TEq n)
  STextLengthLe :: Sing n -> Sing (TLe n)
  STextLengthGt :: Sing n -> Sing (TGt n)

data NumberConstraint
  = NLe Nat
  | NGt Nat
  | NEq Nat

data instance Sing (nc :: NumberConstraint) where
  SNumberEq :: Sing n -> Sing (NEq n)
  SNumberGt :: Sing n -> Sing (NGt n)
  SNumberLe :: Sing n -> Sing (NLe n)

data ArrayConstraint
  = AEq Nat

data instance Sing (ac :: ArrayConstraint) where
  SArrayEq :: Sing n -> Sing (AEq n)

data Schema
  = SchemaText [TextConstraint]
  | SchemaNumber [NumberConstraint]
  | SchemaObject [(Symbol, Schema)]
  | SchemaArray [ArrayConstraint] Schema
  | SchemaNull

data instance Sing (schema :: Schema) where
  SSchemaText :: Sing tcs -> Sing (SchemaText tcs)
  SSchemaNumber :: Sing ncs -> Sing (SchemaNumber ncs)
  SSchemaArray :: Sing acs -> Sing schema -> Sing (SchemaArray acs schema)
  SSchemaObject :: Sing fields -> Sing (SchemaObject fields)
  SSchemaNull :: Sing SchemaNull

data FieldRepr :: (Symbol, Schema) -> Type where
  FieldRepr :: KnownSymbol name => JsonRepr schema -> FieldRepr '(name, schema)

data JsonRepr :: Schema -> Type where
  ReprText :: Text -> JsonRepr (SchemaText cs)
  ReprNumber :: Scientific -> JsonRepr (SchemaNumber cs)
  ReprNull :: JsonRepr SchemaNull
  ReprArray :: V.Vector (JsonRepr s) -> JsonRepr (SchemaArray cs s)
  ReprObject :: Rec FieldRepr fs -> JsonRepr (SchemaObject fs)

instance (SingI schema) => J.FromJSON (JsonRepr schema) where
  parseJSON value = case sing :: Sing schema of
    SSchemaText _    -> withText "String" (pure . ReprText) value
    SSchemaNumber _  -> withScientific "Number" (pure . ReprNumber) value
    SSchemaNull      -> pure ReprNull
    SSchemaArray c s -> withArray "Array" f value
      where
        f v = do
          values <- withSingI s $ traverse parseJSON v
          pure $ ReprArray values
    SSchemaObject fs -> ReprObject <$> withObject "Object" (demoteFields fs) value

demoteFields
  :: SList s
  -> H.HashMap Text J.Value
  -> Parser (Rec FieldRepr s)
demoteFields SNil h
  | H.null h  = pure RNil
  | otherwise = mzero
demoteFields (SCons (STuple2 (n :: Sing fn) s) tl) h = withKnownSymbol n $ do
  let fieldName = T.pack $ symbolVal (Proxy @fn)
  fieldRepr <- case H.lookup fieldName h of
    Just v  -> FieldRepr <$> (withSingI s $ parseJSON v)
    Nothing -> mzero
  (fieldRepr :&) <$> demoteFields tl h

instance J.ToJSON (JsonRepr a) where
  toJSON ReprNull       = J.Null
  toJSON (ReprText t)   = J.String t
  toJSON (ReprNumber n) = J.Number n
  toJSON (ReprArray v)  = J.Array $ toJSON <$> v
  toJSON (ReprObject r) = J.Object . H.fromList . fold $ r
    where
      extract
        :: forall name s
        .  (KnownSymbol name)
        => FieldRepr '(name, s)
        -> (Text, Value)
      extract (FieldRepr s) = (T.pack $ symbolVal $ Proxy @name, toJSON s)
      fold :: Rec FieldRepr fs -> [(Text, J.Value)]
      fold = \case
        RNil                   -> []
        fr@(FieldRepr s) :& tl -> (extract fr) : fold tl

type Spec
  = SchemaObject
    '[ '("foo", SchemaArray '[AEq 3] (SchemaNumber '[NGt 10]))
     , '("bar", SchemaText '[Regex "\\w+"])]

spec :: (SingKind Schema, SingI Spec) => DemoteRep Schema
spec = fromSing (sing :: Sing Spec)

exampleTest :: JsonRepr (SchemaText '[TEq 3])
exampleTest = ReprText "ololo"

exampleNumber :: JsonRepr (SchemaNumber '[NEq 3])
exampleNumber = ReprNumber 3

exampleArray :: JsonRepr (SchemaArray '[AEq 1] (SchemaNumber '[NEq 3]))
exampleArray = ReprArray [exampleNumber]

exampleObject
  :: JsonRepr (SchemaObject '[ '("foo", SchemaArray '[AEq 1] (SchemaNumber '[NEq 3]))] )
exampleObject = ReprObject $ FieldRepr exampleArray :& RNil

example :: JsonRepr Spec
example = ReprObject $
  FieldRepr (ReprArray [ReprNumber 3])
    :& FieldRepr (ReprText "test")
    :& RNil

class FalseConstraint

type family TopLevel (spec :: Schema) :: Constraint where
  TopLevel (SchemaArray a e) = ()
  TopLevel (SchemaObject o)  = ()
  TopLevel spec              = FalseConstraint