module Kempe.File ( tcFile
                  , absFile
                  , irFile
                  ) where

-- common b/w test suite and exec, repl utils
import           Control.Composition       ((.*))
import           Control.Exception         (Exception, throwIO)
import qualified Data.ByteString.Lazy      as BSL
import           Kempe.AST
import           Kempe.Asm.X86.Type
import           Kempe.Error
import           Kempe.IR
import           Kempe.Parser
import           Kempe.Pipeline
import           Kempe.TyAssign
import           Prettyprinter             (Doc, hardline)
import           Prettyprinter.Render.Text (putDoc)

tcFile :: FilePath -> IO (Either (Error ()) ())
tcFile fp = do
    contents <- BSL.readFile fp
    (maxU, m) <- yeetIO $ parseWithMax contents
    pure $ fst <$> runTypeM maxU (checkModule m)

yeetIO :: Exception e => Either e a -> IO a
yeetIO = either throwIO pure

dumpIR :: Int -> Module a b -> Doc ann
dumpIR = prettyIR . fst .* irGen

dumpAbs :: Int -> Module a b -> Doc ann
dumpAbs = prettyAsm .* x86Parsed

irFile :: FilePath -> IO ()
irFile fp = do
    contents <- BSL.readFile fp
    res <- yeetIO $ parseWithMax contents
    putDoc $ hardline <> uncurry dumpIR res

absFile :: FilePath -> IO ()
absFile fp = do
    contents <- BSL.readFile fp
    res <- yeetIO $ parseWithMax contents
    putDoc $ hardline <> uncurry dumpAbs res
