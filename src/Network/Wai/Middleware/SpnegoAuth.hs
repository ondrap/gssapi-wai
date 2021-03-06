{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

-- |
-- Module : Network.Wai.Middleware.SpnegoAuth
-- License : BSD-style
--
-- Maintainer  : palkovsky.ondrej@gmail.com
-- Stability   : experimental
-- Portability : portable
--
-- WAI Middleware for SPNEGO authentication with failback to Basic authentication, where
-- the username/password is checked using Kerberos library (i.e. kinit user@EXAMPLE.COM).

module Network.Wai.Middleware.SpnegoAuth (
    spnegoAuth
  , SpnegoAuthSettings(..)
  , defaultSpnegoSettings
  , spnegoAuthKey
  , defaultAuthResponse
  , defaultAuthError
) where

import           Control.Arrow                   (second)
import           Control.Exception               (catch)
import qualified Data.ByteString.Base64          as B64
import qualified Data.ByteString.Char8           as BS
import qualified Data.CaseInsensitive            as CI
import           Data.Maybe                      (fromMaybe)
import           Data.Monoid                     ((<>))
import qualified Data.Vault.Lazy                 as V
import           Network.HTTP.Types              (status401)
import           Network.HTTP.Types.Header       (hAuthorization,
                                                  hWWWAuthenticate)
import           Network.Wai                     (Application, Middleware,
                                                  Request (..),
                                                  mapResponseHeaders,
                                                  responseLBS, ResponseReceived,
                                                  Response)
import           Network.Wai.Middleware.HttpAuth (extractBasicAuth)
import           System.IO                       (hPutStrLn, stderr)
import           System.IO.Unsafe

import           Network.Security.GssApi
import           Network.Security.Kerberos

-- | Configuration structure for `spnegoAuth` middleware
data SpnegoAuthSettings = SpnegoAuthSettings {
    spnegoRealm         :: Maybe BS.ByteString -- ^ Realm to use with both kerberos and spnego authentication.
  , spnegoService       :: Maybe BS.ByteString -- ^ If set, use 'spnegoService@spnegoRealm' credentials from the keytab.
                                            --   May contain the whole principal, in such case `spnegoRealm` is used only for
                                            --   kerberos user/password authentication.
  , spnegoUserFull      :: Bool -- ^ Always return full user principal; normally, if the user realm is equal to spnegoRealm,
                             --   the realm is stripped
  , spnegoBasicFailback :: Bool -- ^ Allow failback to basic auth (username/password with kerberos api)
  , spnegoForceRealm    :: Bool -- ^ Force use of `spnegoRealm` or default system realm in basic auth failback
  , spnegoOnAuthError   :: SpnegoAuthSettings -> Maybe (Either KrbException GssException) -> Application
    -- ^ Called upon GSSAPI/Kerberos error. It is supposed to return 401 return code with
    --   'Authorize: Negotiate' and possibly 'Authorize: Basic realm=...' headers
    --
    -- You MUST flush the request body in this method, otherwise POST/PUT/etc. requests mysteriously fail.
  , spnegoFakeBasicAuth :: Bool -- ^ Fake 'Authorization: ' basic header for applications relying on Basic auth
}

-- | Default settings for `spnegoAuth` middleware
defaultSpnegoSettings :: SpnegoAuthSettings
defaultSpnegoSettings = SpnegoAuthSettings {
    spnegoRealm = Nothing
  , spnegoService = Nothing
  , spnegoUserFull = False
  , spnegoBasicFailback = True
  , spnegoForceRealm = True
  , spnegoOnAuthError = defaultAuthError (hPutStrLn stderr)
  , spnegoFakeBasicAuth = False
  }

-- | Genereate HTTP response that asks client to do appropriate authentication
defaultAuthResponse :: SpnegoAuthSettings -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
defaultAuthResponse settings request respond = do
    flushRequestBody request
    respond $ responseLBS status401 (authHeaders settings) "Unauthorized"
  where
    authHeaders SpnegoAuthSettings{spnegoBasicFailback=True, spnegoRealm=Just realm} =
        [(hWWWAuthenticate, "Negotiate"), (hWWWAuthenticate, "Basic realm=\"" <> realm <> "\"")]
    authHeaders SpnegoAuthSettings{spnegoBasicFailback=True, spnegoRealm=Nothing} =
        [(hWWWAuthenticate, "Negotiate"), (hWWWAuthenticate, "Basic realm=\"Auth\"")]
    authHeaders SpnegoAuthSettings{spnegoBasicFailback=False} = [(hWWWAuthenticate, "Negotiate")]

flushRequestBody :: Request -> IO ()
flushRequestBody req = do
    res <- requestBody req
    case res of
        "" -> return ()
        _ -> flushRequestBody req

-- | Default authentication for filling in spnegoOnAuthError
defaultAuthError :: (String -> IO ()) -> SpnegoAuthSettings -> Maybe (Either KrbException GssException) -> Application
defaultAuthError _ settings Nothing req respond = defaultAuthResponse settings req respond
defaultAuthError logerr settings (Just (Left (KrbException code err))) req respond = do
    logerr $ "Kerberos error code: " <> show code <> ", error: " <> show err
    defaultAuthResponse settings req respond
defaultAuthError logerr settings (Just (Right (GssException major majorTxt minor minorTxt))) req respond = do
    logerr $ "GSSAPI major code: " <> show major <> ", error: " <> show majorTxt
               <> ", minor code: " <> show minor <> ", error: " <> show minorTxt
    defaultAuthResponse settings req respond

-- | Key that is used to access the username in WAI vault
spnegoAuthKey :: V.Key BS.ByteString
spnegoAuthKey = unsafePerformIO V.newKey
{-# NOINLINE spnegoAuthKey #-}

-- | Middleware that provides SSO capabilites
spnegoAuth :: SpnegoAuthSettings -> Middleware
spnegoAuth settings@SpnegoAuthSettings{..} iapp req respond = do
    let hdrs = requestHeaders req
    case lookup hAuthorization hdrs of
      Just val
          | Just token <- getSpnegoToken val ->
              runSpnegoCheck token `catch` (\exc -> spnegoOnAuthError settings (Just (Right exc)) req respond)
          | Just (user, password) <- extractBasicAuth val ->
              runKerberosCheck user password `catch` (\exc -> spnegoOnAuthError settings (Just (Left exc)) req respond)
      _ -> spnegoOnAuthError settings Nothing req respond
    where
      insertUserToVault user myreq  = myreq{vault = vault'}
          where
            vault' = V.insert spnegoAuthKey (stripSpnegoRealm user) (vault myreq)
      fakeAuth user myreq
        | spnegoFakeBasicAuth =
            let oldHeaders = requestHeaders myreq
                fakeHeader = (hAuthorization, "Basic " <> B64.encode (stripSpnegoRealm user <> ":password"))
            in myreq{requestHeaders=fakeHeader : oldHeaders}
        | otherwise = myreq

      modifyKrbUser orig_user
        | spnegoForceRealm = user <> fromMaybe "" (("@" <>) <$> spnegoRealm)
        | BS.null realm, Just newrealm <- spnegoRealm = user <> "@" <> newrealm
        | otherwise = orig_user
        where
          (user, realm) = splitPrincipal orig_user

      runKerberosCheck origuser password = do
          user <- krb5Resolve (modifyKrbUser origuser)
          krb5Login user password -- throws exception in case of error
          iapp (insertUserToVault user req) respond

      runSpnegoCheck token = do
          let service
                | (BS.elem '@' <$> spnegoService) == Just True = spnegoService
                | otherwise = (<> fromMaybe "" (("@" <>) <$> spnegoRealm)) <$> spnegoService
          (user, output) <- runGssCheck service token
          let neghdr = (hWWWAuthenticate, "Negotiate " <> B64.encode output)
          iapp (fakeAuth user $ insertUserToVault user req) (respond . mapResponseHeaders (neghdr :))

      -- Strip Realm, if spnegoUserFull is not set and the realm equals to spnegoRealm
      stripSpnegoRealm user
        | not spnegoUserFull, (clservice, clrealm) <- splitPrincipal user,
            Just clrealm == spnegoRealm = clservice
        | otherwise = user

      getSpnegoToken :: BS.ByteString -> Maybe BS.ByteString
      getSpnegoToken val
        | CI.mk w1 == "negotiate" = either (const Nothing) Just (B64.decode $ BS.drop 1 w2)
        | otherwise = Nothing
        where
          (w1, w2) = BS.break (==' ') val

splitPrincipal :: BS.ByteString -> (BS.ByteString, BS.ByteString)
splitPrincipal = second (BS.drop 1) . BS.break (== '@')
