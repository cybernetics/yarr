
module Data.Yarr.Repr.Delayed where

import Prelude as P
import Control.Monad

import Data.Yarr.Base as B
import Data.Yarr.Shape
import Data.Yarr.Utils.FixedVector as V


data D

instance Shape sh => Regular D sh a where

    data UArray D sh a =
        Delayed
            !sh           -- Extent
            !Bool         -- If shape indexing preferred
            (IO ())       -- Touch
            (sh -> IO a)  -- Get
            (Int -> IO a) -- Linear get

    extent (Delayed sh _ _ _ _) = sh
    shapeIndexingPreferred (Delayed _ shIxPref _ _ _) = shIxPref
    touch (Delayed _ _ tch _ _) = tch

    {-# INLINE extent #-}
    {-# INLINE shapeIndexingPreferred #-}
    {-# INLINE touch #-}

instance Shape sh => NFData (UArray D sh a) where
    rnf (Delayed sh shIxPref tch get lget) =
        sh `deepseq` shIxPref `seq` tch `seq` lget `seq` get `seq` ()

instance Shape sh => USource D sh a where
    index (Delayed _ _ _ get _) = get
    linearIndex (Delayed _ _ _ _ lget) = lget
    {-# INLINE index #-}
    {-# INLINE linearIndex #-}


instance (Shape sh, Vector v e) => VecRegular D sh D v e where
    slices (Delayed sh shIxPref tch get lget) =
        V.generate (
            \i ->
                Delayed
                    sh shIxPref tch
                    ((return . (V.! i)) <=< get)
                    ((return . (V.! i)) <=< lget))
    {-# INLINE slices #-}

instance (Shape sh, Vector v e) => UVecSource D sh D v e

instance USource r sh a => Fusion r D sh a b where
    fmapM f arr =
        Delayed (extent arr) (shapeIndexingPreferred arr) (touch arr)
            (f <=< index arr) (f <=< linearIndex arr)

    fzipM fun arrs =
        let shapes = V.toList $ V.map extent arrs
            sh0 = P.head shapes
            needReshape = not $ all (== sh0) shapes
            sh = if not needReshape
                    then sh0
                    else intersect shapes
            shIxPref = needReshape || any shapeIndexingPreferred (V.toList arrs)

            tch = V.mapM_ touch arrs

            gets = V.map index arrs
            {-# INLINE get #-}
            get sh = do
                v <- V.mapM ($ sh) gets
                inspect v fun

            lgetFromArr = if not needReshape
                then linearIndex
                else \arr ->
                    if extent arr == sh
                        then linearIndex arr
                        else index arr . fromIndex sh
            lgets = V.map lgetFromArr arrs
            {-# INLINE lget #-}
            lget i = do
                v <- V.mapM ($ i) lgets
                inspect v fun

        in Delayed sh shIxPref tch get lget

    {-# INLINE fmapM #-}
    {-# INLINE fzipM #-}

instance Shape sh => DefaultFusion D D sh a b


fromShapeFunction :: Shape sh => sh -> IO () -> (sh -> IO a) -> UArray D sh a
{-# INLINE fromShapeFunction #-}
fromShapeFunction sh tch get = Delayed sh True tch get (get . fromIndex sh)

fromLinearFunction :: Shape sh => sh -> IO () -> (Int -> IO a) -> UArray D sh a
{-# INLINE fromLinearFunction #-}
fromLinearFunction sh tch lget =
    Delayed sh False tch (lget . toIndex sh) lget