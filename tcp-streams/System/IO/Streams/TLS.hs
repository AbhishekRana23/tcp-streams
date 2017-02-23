{-# LANGUAGE ScopedTypeVariables #-}

-- | This module provides convenience functions for interfacing @io-streams@
-- with @tls@. the default receive buffer size is decided by @tls@.
-- sending is unbuffered, anything write into 'OutputStream' will be
-- immediately send to underlying socket.
--
-- The same exceptions rule which applied to TCP apply here, with addtional
-- 'TLS.TLSException' to be watched out.
--
-- This module is intended to be imported @qualified@, e.g.:
--
-- @
-- import qualified "System.IO.Streams.TLS" as TLS
-- @
--
module System.IO.Streams.TLS
  ( -- * connection type
    Connection(..)
    -- * tcp client
  , connect
  , connectTLS
  , tLsToConnection
    -- * tcp server
  , accept
  , module Data.TLSSetting
  ) where

import qualified Control.Exception     as E
import           Data.Connection
import qualified Data.ByteString       as B
import qualified Data.ByteString.Char8 as BC
import           Data.TLSSetting
import qualified Network.Socket        as N
import           Network.TLS           (ClientParams, Context, ServerParams)
import qualified Network.TLS           as TLS
import qualified System.IO.Streams     as Stream
import qualified System.IO.Streams.TCP as TCP


-- | Given an existing TLS 'Context' connection, produces an 'InputStream' \/
-- 'OutputStream' pair.
--
tLsToConnection :: (Context, N.SockAddr)    -- ^ TLS connection / socket address pair
                -> IO Connection
tLsToConnection (ctx, addr) = do
    is <- Stream.makeInputStream input
    return (Connection is write (closeTLS ctx) addr)
  where
    input = (do
        s <- TLS.recvData ctx
        return $! if B.null s then Nothing else Just s
        ) `E.catch` (\(_::E.SomeException) -> return Nothing)
    write s = TLS.sendData ctx s

-- | Close a TLS 'Context' and its underlying socket.
--
closeTLS :: Context -> IO ()
closeTLS ctx = (TLS.bye ctx >> TLS.contextClose ctx) -- sometimes socket was closed before 'TLS.bye'
    `E.catch` (\(_::E.SomeException) -> return ())   -- so we catch the 'Broken pipe' error here

-- | Convenience function for initiating an TLS connection to the given
-- @('HostName', 'PortNumber')@ combination.
--
-- This operation will throw 'TLS.TLSException' on failure.
--
connectTLS :: ClientParams         -- ^ check "Data.TLSSetting".
           -> Maybe String         -- ^ Optional certificate subject name, if set to 'Nothing'
                                   -- then we will try to verify 'HostName' as subject name.
           -> N.HostName             -- ^ hostname to connect to
           -> N.PortNumber           -- ^ port number to connect to
           -> IO (Context, N.SockAddr)
connectTLS prms subname host port = do
    let subname' = maybe host id subname
        prms' = prms { TLS.clientServerIdentification = (subname', BC.pack (show port)) }
    (sock, addr) <- TCP.connectSocket host port
    E.bracketOnError (TLS.contextNew sock prms') closeTLS $ \ ctx -> do
        TLS.handshake ctx
        return (ctx, addr)

connect :: ClientParams         -- ^ check "Data.TLSSetting".
        -> Maybe String         -- ^ Optional certificate subject name, if set to 'Nothing'
                                -- then we will try to verify 'HostName' as subject name.
        -> N.HostName             -- ^ hostname to connect to
        -> N.PortNumber           -- ^ port number to connect to
        -> IO Connection
connect prms subname host port = connectTLS prms subname host port >>= tLsToConnection

-- | Accept a new connection from remote client, return a 'InputStream' / 'OutputStream'
-- pair and remote 'N.SockAddr', you should call 'TCP.bindAndListen' first.
--
-- this operation will throw 'TLS.TLSException' on failure.
--
accept :: ServerParams              -- ^ check "Data.TLSSetting".
       -> N.Socket                    -- ^ the listening 'Socket'.
       -> IO Connection
accept prms sock = do
    (sock', addr) <- N.accept sock
    E.bracketOnError (TLS.contextNew sock' prms) closeTLS $ \ ctx -> do
        TLS.handshake ctx
        conn <- tLsToConnection (ctx, addr)
        return conn

