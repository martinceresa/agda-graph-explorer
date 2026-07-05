{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE RecordWildCards #-}

-- | A path-light union-find over 'Int' keys, backed by an 'IM.IntMap' so
-- it can union over a sparse subset of node ids cheaply. Shared by the
-- clustering analyses (@fingerprint@, @echo@).
module AgdaOptimization.UnionFind
  ( UF
  , emptyUF
  , ufInsert
  , ufFind
  , ufUnion
  , ufClusters
  ) where

import qualified Data.IntMap.Strict as IM

-- | Union-find state: a parent pointer and a union-by-rank counter per key.
data UF = UF
  { ufParent :: !(IM.IntMap Int)
  , ufRank   :: !(IM.IntMap Int)
  }

emptyUF :: UF
emptyUF = UF IM.empty IM.empty

-- | Ensure @x@ is in the structure (as its own root).
ufInsert :: Int -> UF -> UF
ufInsert x uf@UF{..}
  | IM.member x ufParent = uf
  | otherwise            = uf { ufParent = IM.insert x x ufParent
                              , ufRank   = IM.insert x 0 ufRank }

-- | Find the representative (no path compression — fine for these sizes;
-- clusters are small and we never repeat-find at scale).
ufFind :: Int -> UF -> Int
ufFind x UF{..} = go x
  where
    go !y = case IM.lookup y ufParent of
      Just p  | p == y    -> y
              | otherwise -> go p
      Nothing             -> y  -- shouldn't happen; treat as singleton.

-- | Union two elements. Inserts them first if absent.
ufUnion :: Int -> Int -> UF -> UF
ufUnion a b uf0 =
  let uf1     = ufInsert a (ufInsert b uf0)
      !ra     = ufFind a uf1
      !rb     = ufFind b uf1
  in if ra == rb
       then uf1
       else
         let !rkA = IM.findWithDefault 0 ra (ufRank uf1)
             !rkB = IM.findWithDefault 0 rb (ufRank uf1)
         in case compare rkA rkB of
              LT -> uf1 { ufParent = IM.insert ra rb (ufParent uf1) }
              GT -> uf1 { ufParent = IM.insert rb ra (ufParent uf1) }
              EQ -> uf1 { ufParent = IM.insert ra rb (ufParent uf1)
                        , ufRank   = IM.insert rb (rkB + 1) (ufRank uf1) }

-- | Bucket every inserted element by its representative. Returns one list
-- per cluster; singletons included (caller filters).
ufClusters :: UF -> [[Int]]
ufClusters uf@UF{..} =
  let go !acc k _ =
        let !r = ufFind k uf
        in IM.insertWith (++) r [k] acc
      grouped = IM.foldlWithKey' go IM.empty ufParent
  in IM.elems grouped
