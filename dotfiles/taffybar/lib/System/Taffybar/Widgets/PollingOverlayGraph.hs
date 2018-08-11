{-# LANGUAGE ScopedTypeVariables #-}
-- | This is a graph widget inspired by the widget of the same name in
-- Awesome (the window manager).  It plots a series of data points
-- similarly to a bar graph.  This version must be explicitly fed data
-- with 'graphAddSample'.  For a more automated version, see
-- 'PollingGraph'.
--
-- Like Awesome, this graph can plot multiple data sets in one widget.
-- The data sets are plotted in the order provided by the caller.
--
-- Note: all of the data fed to this widget should be in the range
-- [0,1].
module System.Taffybar.Widgets.PollingOverlayGraph (
  pollingOverlayGraphNew,
  defaultOverlayGraphConfig,

  OverlayGraphConfig(..),
  GraphDirection(..),
  GraphStyle(..)
  ) where

import Prelude hiding ( mapM_ )
import Control.Concurrent
import Data.Sequence ( Seq(..), (<|), viewl, ViewL(..) )
import Data.Foldable ( mapM_ )
import Control.Monad ( when, forever, (<=<) )
import Control.Monad.Trans ( liftIO )
import Data.IORef ( newIORef, readIORef, modifyIORef )
import qualified Control.Exception.Enclosed as E
import qualified Data.Sequence as S
import qualified Graphics.Rendering.Cairo as C
import qualified Graphics.Rendering.Cairo.Matrix as M
import qualified Graphics.Rendering.Pango.Cairo as P
import qualified Graphics.UI.Gtk as Gtk

import System.Taffybar.Widgets.Graph ( GraphDirection(..), GraphStyle(..) )

pollingOverlayGraphNew :: OverlayGraphConfig
                          -> Double
                          -> Int
                          -> IO (Double, String, (Double, Double, Double, Double))
                          -> IO Gtk.Widget
pollingOverlayGraphNew cfg pollSeconds savePeriod action = do
  (da, h) <- graphNew cfg

  counter <- newIORef 0
  _ <- Gtk.on da Gtk.realize $ do
       _ <- forkIO $ forever $ do
         esample <- E.tryAny action
         case esample of
           Left _ -> return ()
           Right sample -> do
             count <- readIORef counter
             if count == 0
               then graphAddSample h sample
               else graphUpdate h sample
             modifyIORef counter ((`mod` savePeriod) . (+ 1))
         threadDelay $ floor (pollSeconds * 1000000)
       return ()

  return da

newtype GraphHandle = GH (MVar GraphState)
data GraphState =
  GraphState { graphIsBootstrapped :: Bool
             , graphHistory :: Seq Double
             , graphLabel :: String
             , graphColor :: (Double, Double, Double, Double)
             , graphCanvas :: Gtk.DrawingArea
             , graphLayout :: Gtk.PangoLayout
             , graphConfig :: OverlayGraphConfig
             }

-- | The configuration options for the graph.  The padding is the
-- number of pixels reserved as blank space around the widget in each
-- direction.
data OverlayGraphConfig =
  OverlayGraphConfig { ographPadding :: Int -- ^ Number of pixels of padding on each side of the graph widget
                     , ographBackgroundColor :: (Double, Double, Double) -- ^ The background color of the graph (default black)
                     , ographBorderColor :: (Double, Double, Double) -- ^ The border color drawn around the graph (default gray)
                     , ographLabelColor :: (Double, Double, Double)
                     , ographBorderWidth :: Int -- ^ The width of the border (default 1, use 0 to disable the border)
                     , ographDataStyle :: GraphStyle -- ^ How to draw each data point (default @repeat Area@)
                     , ographHistorySize :: Int -- ^ The number of data points to retain for each data set (default 20)
                     , ographWidth :: Int -- ^ The width (in pixels) of the graph widget (default 50)
                     , ographDirection :: GraphDirection
                     }

defaultOverlayGraphConfig :: OverlayGraphConfig
defaultOverlayGraphConfig = OverlayGraphConfig { ographPadding = 2
                                               , ographBackgroundColor = (0.0, 0.0, 0.0)
                                               , ographBorderColor = (0.5, 0.5, 0.5)
                                               , ographLabelColor = (0.5, 0.5, 0.5)
                                               , ographBorderWidth = 1
                                               , ographDataStyle = Area
                                               , ographHistorySize = 20
                                               , ographWidth = 50
                                               , ographDirection = LEFT_TO_RIGHT
                                               }

-- | Add a data point to the graph for each of the tracked data sets.
-- There should be as many values in the list as there are data sets.
graphUpdate, graphAddSample :: GraphHandle -> (Double, String, (Double, Double, Double, Double)) -> IO ()
graphUpdate = graphUpdate' False
graphAddSample = graphUpdate' True
graphUpdate' addSample (GH mv) (rawData, label, color) = do
  s <- readMVar mv
  let drawArea = graphCanvas s
      histSize = ographHistorySize (graphConfig s)
      newVal = clamp 0 1 rawData
      oldHist = graphHistory s
      newHist = if not addSample then oldHist else case oldHist of
        S.Empty -> S.replicate histSize newVal
        old :|> _ -> newVal <| old
  case graphIsBootstrapped s of
    False -> return ()
    True -> do
      modifyMVar_ mv (\s' -> return s' { graphHistory = newHist
                                       , graphLabel = label
                                       , graphColor = color
                                       })
      Gtk.postGUIAsync $ Gtk.widgetQueueDraw drawArea

clamp :: Double -> Double -> Double -> Double
clamp lo hi d = max lo $ min hi d

outlineData :: (Double -> Double) -> Double -> Double -> C.Render ()
outlineData pctToY xStep pct = do
  (curX,_) <- C.getCurrentPoint
  C.lineTo (curX + xStep) (pctToY pct)

renderFrameAndBackground :: OverlayGraphConfig -> Int -> Int -> C.Render ()
renderFrameAndBackground cfg w h = do
  let (backR, backG, backB) = ographBackgroundColor cfg
      (frameR, frameG, frameB) = ographBorderColor cfg
      pad = ographPadding cfg
      fpad = fromIntegral pad
      fw = fromIntegral w
      fh = fromIntegral h

  -- Draw the requested background
  C.setSourceRGB backR backG backB
  C.rectangle fpad fpad (fw - 2 * fpad) (fh - 2 * fpad)
  C.fill

  -- Draw a frame around the widget area
  -- (unless equal to background color, which likely means the user does not
  -- want a frame)
  when (ographBorderWidth cfg > 0) $ do
    let p = fromIntegral (ographBorderWidth cfg)
    C.setLineWidth p
    C.setSourceRGB frameR frameG frameB
    C.rectangle (fpad + (p / 2)) (fpad + (p / 2)) (fw - 2 * fpad - p) (fh - 2 * fpad - p)
    C.stroke


renderGraph :: Seq Double -> Gtk.PangoLayout -> (Double, Double, Double, Double) -> OverlayGraphConfig -> Int -> Int -> Double -> C.Render ()
renderGraph hist layout color cfg w h xStep = do
  renderFrameAndBackground cfg w h

  C.setLineWidth 0.1

  let pad = fromIntegral $ ographPadding cfg
  let framePad = fromIntegral $ ographBorderWidth cfg

  -- Make the new origin be inside the frame and then scale the
  -- drawing area so that all operations in terms of width and height
  -- are inside the drawn frame.
  C.translate (pad + framePad) (pad + framePad)
  let xS = (fromIntegral w - 2 * pad - 2 * framePad) / fromIntegral w
      yS = (fromIntegral h - 2 * pad - 2 * framePad) / fromIntegral h
  C.scale xS yS

  -- If right-to-left direction is requested, apply an horizontal inversion
  -- transformation with an offset to the right equal to the width of the widget.
  if ographDirection cfg == RIGHT_TO_LEFT
      then C.transform $ M.Matrix (-1) 0 0 1 (fromIntegral w) 0
      else return ()

  let pctToY pct = fromIntegral h * (1 - pct)
      (r, g, b, a) = color
      originY = pctToY newestSample
      originX = 0
      newestSample :< hist' = viewl hist
  C.setSourceRGBA r g b a
  C.moveTo originX originY

  mapM_ (outlineData pctToY xStep) hist'
  case ographDataStyle cfg of
    Area -> do
      (endX, _) <- C.getCurrentPoint
      C.lineTo endX (fromIntegral h)
      C.lineTo 0 (fromIntegral h)
      C.fill
    Line -> do
      C.setLineWidth 1.0
      C.stroke

  C.identityMatrix
  let (r, g, b) = ographLabelColor cfg
  C.setSourceRGB r g b
  Gtk.PangoRectangle _ _ w' h' <- liftIO $ snd <$> Gtk.layoutGetExtents layout
  let [x, y] = zipWith (\a b -> (fromIntegral a - b) / 2) [w, h] [w', h']
  C.moveTo x y
  P.showLayout layout

drawBorder :: MVar GraphState -> Gtk.DrawingArea -> IO ()
drawBorder mv drawArea = do
  (w, h) <- Gtk.widgetGetSize drawArea
  drawWin <- Gtk.widgetGetDrawWindow drawArea
  s <- readMVar mv
  let cfg = graphConfig s
  Gtk.renderWithDrawable drawWin (renderFrameAndBackground cfg w h)
  modifyMVar_ mv (\s' -> return s' { graphIsBootstrapped = True })
  return ()

drawGraph :: MVar GraphState -> Gtk.DrawingArea -> IO ()
drawGraph mv drawArea = do
  (w, h) <- Gtk.widgetGetSize drawArea
  drawWin <- Gtk.widgetGetDrawWindow drawArea
  s <- readMVar mv
  let hist = graphHistory s
      label = graphLabel s
      layout = graphLayout s
      color = graphColor s
      cfg = graphConfig s
      histSize = ographHistorySize cfg
      -- Subtract 1 here since the first data point doesn't require
      -- any movement in the X direction
      xStep = fromIntegral w / fromIntegral (histSize - 1)
  Gtk.layoutSetText layout label
  case hist of
    S.Empty -> Gtk.renderWithDrawable drawWin (renderFrameAndBackground cfg w h)
    _ -> Gtk.renderWithDrawable drawWin (renderGraph hist layout color cfg w h xStep)

graphNew :: OverlayGraphConfig -> IO (Gtk.Widget, GraphHandle)
graphNew cfg = do
  drawArea <- Gtk.drawingAreaNew
  label <- Gtk.labelNew (Nothing :: Maybe String)
  l <- Gtk.labelGetLayout label
  mv <- newMVar GraphState { graphIsBootstrapped = False
                           , graphHistory = S.Empty
                           , graphCanvas = drawArea
                           , graphConfig = cfg
                           , graphLayout = l
                           , graphLabel = ""
                           , graphColor = (0, 0, 0, 0)
                           }

  Gtk.widgetSetSizeRequest drawArea (ographWidth cfg) (-1)
  _ <- Gtk.on drawArea Gtk.exposeEvent $ Gtk.tryEvent $ liftIO (drawGraph mv drawArea)
  _ <- Gtk.on drawArea Gtk.realize $ liftIO (drawBorder mv drawArea)
  box <- Gtk.hBoxNew False 1

  Gtk.boxPackStart box label Gtk.PackNatural 0

  Gtk.boxPackStart box drawArea Gtk.PackGrow 0
  Gtk.widgetShowAll box
  return (Gtk.toWidget box, GH mv)