{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedStrings #-}

module Futhark.CLI.LSP (main) where

import Control.Concurrent.MVar (newMVar)
import Control.Monad.IO.Class (MonadIO (liftIO))
import Futhark.LSP.Handlers (handlers)
import Futhark.LSP.Utils (debug, emptyState)
import Language.LSP.Server
import Language.LSP.Types
import System.Log.Logger (Priority (DEBUG))

main :: IO Int
main = do
  stateMVar <- newMVar emptyState
  debug "Init with emptyState"
  setupLogger Nothing ["futhark"] DEBUG
  runServer $
    ServerDefinition
      { onConfigurationChange = const $ const $ Right (),
        defaultConfig = (),
        doInitialize = \env _req -> do pure $ Right env,
        staticHandlers = handlers stateMVar,
        interpretHandler = \env -> Iso (runLspT env) liftIO,
        options =
          defaultOptions
            { textDocumentSync = Just syncOptions
            }
      }

syncOptions :: TextDocumentSyncOptions
syncOptions =
  TextDocumentSyncOptions
    { _openClose = Just True,
      _change = Just TdSyncIncremental,
      _willSave = Just False,
      _willSaveWaitUntil = Just False,
      _save = Just $ InR $ SaveOptions $ Just False
    }
