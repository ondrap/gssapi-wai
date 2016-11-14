[![Build Status](https://travis-ci.org/ondrap/haskell-gssapi.svg?branch=master)](https://travis-ci.org/ondrap/haskell-gssapi) [![Hackage](https://img.shields.io/hackage/v/haskell-gssapi.svg)](https://hackage.haskell.org/package/haskell-gssapi)

## GSSAPI and Kerberos bindings for Haskell

See [haskell-gssapi](http://github.com/ondrap/haskell-gssapi)
for tutorial how to set up kerberos authentication with Windows AD.

#### The application

Generally you need to use TLS, otherwise browsers refuse to use SPNEGO authentication.
The library provides wai middleware component to ease use. The username is saved
to a vault.

````haskell
{-# LANGUAGE OverloadedStrings #-}
module Main where
import           Data.ByteString.Lazy.Char8     (fromStrict)
import           Data.Function                  ((&))
import           Data.Maybe                     (fromMaybe)
import           Data.Monoid                    ((<>))
import qualified Data.Vault.Lazy                as V
import           Network.HTTP.Types             (status200)
import           Network.HTTP.Types.Header      (hContentType)
import           Network.Wai                    (Application, responseLBS,
                                                 vault)
import           Network.Wai.Handler.Warp       (defaultSettings, setPort)
import           Network.Wai.Handler.WarpTLS    (runTLS, tlsSettings)

import           Network.Wai.Middleware.SpnegoAuth

app :: Application
app req respond = do
    let user = fromMaybe "no-user-found?" (V.lookup spnegoAuthKey (vault req))
    respond $ responseLBS status200 [(hContentType, "text/plain")] ("Hello " <> fromStrict user)

main :: IO ()
main = do
  let port = 3000
      settings = defaultSettings & setPort port
      tsettings = tlsSettings "cert.pem" "key.pem"
      authSettings = defaultSpnegoSettings{spnegoRealm=Just "EXAMPLE.COM"}
  putStrLn $ "Listening on port " ++ show port
  runTLS tsettings settings (spnegoAuth authSettings app)
````
