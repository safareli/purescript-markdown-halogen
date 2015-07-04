-- | This module defines functions for rendering Markdown to HTML.

module Text.Markdown.SlamDown.Html
  ( SlamDownEvent()
  , SlamDownState(..)
  , FormFieldValue(..)
  , initSlamDownState
  , applySlamDownEvent
  , renderHalogen
  )
  where

import Control.Alternative (Alternative)
import Control.Monad.State (State(), evalState)
import Control.Monad.State.Class (get, modify)

import Data.Array (concat, zipWith, mapMaybe)
import Data.Maybe (Maybe(..), maybe)
import Data.Monoid (mempty)
import Data.String (joinWith)
import Data.Tuple (Tuple(..), zip)
import Data.Traversable (traverse, zipWithA)

import Text.Markdown.SlamDown

import qualified Data.Set as S
import qualified Data.StrMap as M
import qualified Halogen.HTML as H
import qualified Halogen.HTML.Attributes as A
import qualified Halogen.HTML.Events as E
import qualified Halogen.HTML.Events.Forms as E

data FormFieldValue
  = SingleValue TextBoxType String
  | MultipleValues (S.Set String)

instance showFormFieldValue :: Show FormFieldValue where
  show (SingleValue t s) = "(SingleValue " ++ show t ++ " " ++ show s ++ ")"
  show (MultipleValues ss) = "(MultipleValues " ++ show ss ++ ")"

-- | The state of a SlamDown form - a mapping from input keys to values
newtype SlamDownState = SlamDownState (M.StrMap FormFieldValue)

instance showSlamDownState :: Show SlamDownState where
  show (SlamDownState m) = "(SlamDownState " ++ show m ++ ")"

-- | The initial state of form, in which all fields use their default values
initSlamDownState :: SlamDown -> SlamDownState
initSlamDownState = SlamDownState <<< M.fromList <<< everything (const mempty) go
  where
  go :: Inline -> [Tuple String FormFieldValue]
  go (FormField label _ field) = maybe [] (\v -> [Tuple label v]) $ getValue field
  go _ = []

  getValue :: FormField -> Maybe FormFieldValue
  getValue (TextBox tbt (Just (Literal value))) = Just $ SingleValue tbt value
  getValue (CheckBoxes (Literal sels) (Literal vals)) = Just $ MultipleValues $ S.fromList $ chk `mapMaybe` zip sels vals
    where
    chk (Tuple true value) = Just value
    chk _ = Nothing
  getValue (RadioButtons (Literal value) _) = Just $ SingleValue PlainText value
  getValue (DropDown _ (Just (Literal value))) = Just $ SingleValue PlainText value
  getValue _ = Nothing

-- | The type of events which can be raised by SlamDown forms
data SlamDownEvent
  = TextChanged TextBoxType String String
  | CheckBoxChanged String String Boolean

-- | Apply a `SlamDownEvent` to a `SlamDownState`.
applySlamDownEvent :: SlamDownState -> SlamDownEvent -> SlamDownState
applySlamDownEvent (SlamDownState m) (TextChanged t key val) =
  SlamDownState (M.insert key (SingleValue t val) m)
applySlamDownEvent (SlamDownState m) (CheckBoxChanged key val checked) =
  SlamDownState (M.alter (Just <<< updateSet) key m)
  where
  updateSet :: Maybe FormFieldValue -> FormFieldValue
  updateSet (Just (MultipleValues s))
    | checked = MultipleValues (S.insert val s)
    | otherwise = MultipleValues (S.delete val s)
  updateSet _
    | checked = MultipleValues (S.singleton val)
    | otherwise = MultipleValues S.empty

type Fresh = State Number

-- | Render the SlamDown AST to an arbitrary Halogen HTML representation
renderHalogen :: forall f. (Alternative f) => String -> SlamDownState -> SlamDown -> [H.HTML (f SlamDownEvent)]
renderHalogen formName (SlamDownState m) (SlamDown bs) = evalState (traverse renderBlock bs) 1

  where

  renderBlock :: Block -> Fresh (H.HTML (f SlamDownEvent))
  renderBlock (Paragraph is) = H.p_ <$> traverse renderInline is
  renderBlock (Header level is) = h_ level <$> traverse renderInline is
    where
    h_ :: forall a. Number -> [H.HTML (f a)] -> H.HTML (f a)
    h_ 1 = H.h1_
    h_ 2 = H.h2_
    h_ 3 = H.h3_
    h_ 4 = H.h4_
    h_ 5 = H.h5_
    h_ 6 = H.h6_
  renderBlock (Blockquote bs) = H.blockquote_ <$> traverse renderBlock bs
  renderBlock (List lt bss) = el_ lt <$> traverse item bss
    where
    el_ :: forall a. ListType -> [H.HTML (f a)] -> H.HTML (f a)
    el_ (Bullet _)  = H.ul_
    el_ (Ordered _) = H.ol_
    item :: [Block] -> Fresh (H.HTML (f SlamDownEvent))
    item bs = H.li_ <$> traverse renderBlock bs
  renderBlock (CodeBlock _ ss) =
    pure $ H.pre_ [ H.code_ [ H.text (joinWith "\n" ss) ] ]
  renderBlock (LinkReference l url) =
    pure $ H.p_ [ H.text (l <> ": ")
                , H.a [ A.name l, A.id_ l, A.href url ] [ H.text url ]
                ]
  renderBlock Rule = pure $ H.hr_ []

  renderInline :: Inline -> Fresh (H.HTML (f SlamDownEvent))
  renderInline (Str s) = pure $ H.text s
  renderInline (Entity s) = pure $ H.text s
  renderInline Space = pure $ H.text " "
  renderInline SoftBreak = pure $ H.text "\n"
  renderInline LineBreak = pure $ H.br_ []
  renderInline (Emph is) = H.em_ <$> traverse renderInline is
  renderInline (Strong is) = H.strong_ <$> traverse renderInline is
  renderInline (Code _ c) = pure $ H.code_ [ H.text c ]
  renderInline (Link body tgt) = H.a [ A.href (href tgt) ] <$> traverse renderInline body
    where
    href (InlineLink url) = url
    href (ReferenceLink tgt) = maybe "" ("#" ++) tgt
  renderInline (Image body url) = H.img [ A.src url ] <$> traverse renderInline body
  renderInline (FormField label req el) = do
    id <- fresh
    el' <- renderFormElement id label el
    pure $ H.span_ $ [ H.label (if requiresId then [ A.for id ] else [])
                               [ H.text (label ++ requiredLabel) ]
                     , el'
                     ]
    where
    requiredLabel = if req then "*" else ""
    requiresId = case el of
      CheckBoxes _ _ -> false
      RadioButtons _ _ -> false
      _ -> true

  renderFormElement :: String -> String -> FormField -> Fresh (H.HTML (f SlamDownEvent))
  renderFormElement id label (TextBox t Nothing) =
    pure $ renderTextInput id label t (lookupTextValue label "")
  renderFormElement id label (TextBox t (Just (Literal value))) =
    pure $ renderTextInput id label t (lookupTextValue label value)
  renderFormElement _ label (RadioButtons (Literal def) (Literal ls)) =
    H.ul_ <$> traverse (\val -> radio (val == sel) val) (def : ls)
    where
    sel = lookupTextValue label def
    radio checked value = do
      id <- fresh
      pure $ H.li_ [ H.input [ A.checked checked
                             , A.type_ "radio"
                             , A.id_ id
                             , A.name label
                             , A.value value
                             , E.onChange (E.input_ (TextChanged PlainText label value))
                             ] []
                   , H.label [ A.for id ] [ H.text value ]
                   ]
  renderFormElement _ label (CheckBoxes (Literal bs) (Literal ls)) =
    H.ul_ <$> zipWithA checkBox (lookupMultipleValues label bs ls) ls
    where
    checkBox checked value = do
      id <- fresh
      pure $ H.li_ [ H.input [ A.checked checked
                             , A.type_ "checkbox"
                             , A.id_ id
                             , A.name label
                             , A.value value
                             , E.onChecked (E.input (CheckBoxChanged label value))
                             ] []
                   , H.label [ A.for id ] [ H.text value ]
                   ]
  renderFormElement id label (DropDown (Literal ls) Nothing) = do
    pure $ renderDropDown id label ("" : ls) Nothing
  renderFormElement id label (DropDown (Literal ls) (Just (Literal sel))) = do
    pure $ renderDropDown id label ls (Just (lookupTextValue label sel))
  renderFormElement _ _ _ = pure $ unsupportedFormElement

  lookupTextValue :: String -> String -> String
  lookupTextValue key def =
    case M.lookup key m of
      Just (SingleValue _ val) -> val
      _ -> def

  lookupMultipleValues :: String -> [Boolean] -> [String] -> [Boolean]
  lookupMultipleValues key def ls =
    case M.lookup key m of
      Just (MultipleValues val) -> (`S.member` val) <$> ls
      _ -> def

  fresh :: Fresh String
  fresh = do
    n <- get :: Fresh Number
    modify (+ 1)
    pure (formName ++ "-" ++ show n)

renderTextInput :: forall f. (Alternative f) => String -> String -> TextBoxType -> String -> H.HTML (f SlamDownEvent)
renderTextInput id label t value =
  H.input [ A.type_ (textBoxTypeName t)
          , A.id_ id
          , A.name label
          , A.value value
          , E.onInput (E.input (TextChanged t label))
          ] []

renderDropDown :: forall f. (Alternative f) => String -> String -> [String] -> Maybe String -> H.HTML (f SlamDownEvent)
renderDropDown id label ls sel =
  H.select [ A.id_ id
           , A.name label
           , E.onValueChanged (E.input (TextChanged PlainText label))
           ]
           $ maybe option option' sel <$> ls
  where
  option :: String -> H.HTML (f SlamDownEvent)
  option value = H.option [ A.value value ] [ H.text value ]
  option' :: String -> String -> H.HTML (f SlamDownEvent)
  option' sel value = H.option [ A.selected (value == sel), A.value value ] [ H.text value ]

textBoxTypeName :: TextBoxType -> String
textBoxTypeName t = case t of
  PlainText -> "text"
  Date -> "date"
  Time -> "time"
  DateTime -> "datetime-local"

unsupportedFormElement :: forall a. H.HTML a
unsupportedFormElement = H.text "Unsupported form element"
