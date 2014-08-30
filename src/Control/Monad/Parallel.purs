module Control.Monad.Parallel where

import Control.Bind
import Control.Monad.Eff
import Control.Monad.Cont.Trans 
import Debug.Foreign
import Debug.Trace

type Url    = String
type Script = String

foreign import data Parallel :: !
foreign import data Worker :: *

foreign import getScripts
  "function getScripts(){\
  \    var tags = document.querySelectorAll('script[parallel]');\
  \    var scripts = [];\
  \    for(var i = 0; i < tags.length; i++){\
  \      scripts.push(tags[i].src);\
  \    }\
  \    return scripts;\
  \};" :: forall e. Eff (parallel :: Parallel | e) [Url]

foreign import toString 
  "function toString(fn){\
  \  return fn.toString(); \
  \};" :: forall a. a -> String

foreign import makeWorker
  "function makeWorker(script) {\
  \  return function(){\
  \    var URL = window.URL || window.webkitURL;\
  \    var Blob = window.Blob;\
  \    var Worker = window.Worker;\    
  \    if (!URL || !Blob || !Worker || !script) {\
  \        return null;\
  \    }\
  \    var blob = new Blob([script]);\
  \    var worker = new Worker(URL.createObjectURL(blob));\
  \    return worker;\
  \  };\
  \};" :: forall e. String -> Eff (parallel :: Parallel | e) Worker

importScripts :: [Url] -> String
importScripts ss = "importScripts(" ++ write ss ++ ");"
  where 
    write [s]    =  "'" ++ s ++ "'"
    write (s:ss) =  "'" ++ s ++ "', " ++ write ss

foreign import postMessage
  "function postMessage(message){\
  \  return function(worker){\
  \    return function(){\
  \       worker.postMessage(message);\
  \       return worker;\
  \    };\
  \  };\
  \};" :: forall a e. a -> Worker -> Eff (parallel :: Parallel | e) Worker

foreign import subscribeWorker
  "function subscribeWorker(fn){\
  \  return function(worker){\
  \    return function(){\
  \      worker.onmessage = function(e){\
  \        fn(e.data)();\
  \      };\
  \      return worker;\
  \    };\
  \  };\
  \};" :: forall a e. a -> Worker -> Eff (parallel :: Parallel | e) Worker

foreign import workerPool
  "function workerPool(workers){\
  \  return function(xs){\
  \    return function(fn){\
  \      return function(){\
  \        var wl  = workers.length,\
  \            xl  = xs.length,\
  \            cur = 0,\
  \            res = [],\
  \            max = wl > xl ? xl : wl,\

  \        work = function(j){\
  \          var worker = workers[j];\
  \          worker.postMessage(xs[j]);\
  \          cur = j;\
  \          worker.onmessage = function(e){\
  \            res.push(e.data);\
  \            cur++;\
  \            if(xs[cur] && cur < xl){\
  \             worker.postMessage(xs[cur]);\
  \            }else if(res.length === xl){\
  \              for(var k = 0; k < wl; k++){ workers[k].onmessage = undefined; }\
  \              fn(res)();\
  \            }\
  \          };\
  \        };\

  \        for(var j = 0; j < max; j++){ work(j); }\
            
  \        return workers;\
  \      };\
  \    };\
  \  };\
  \}" :: forall a b c e. [Worker] -> [a] -> (b -> Eff (parallel :: Parallel | e) c) -> Eff (parallel :: Parallel | e) Unit

parallel :: forall a b e. [Worker] -> [a] -> ContT Unit (Eff (parallel :: Parallel | e)) b
parallel workers as = ContT $ workerPool workers as

foreign import terminate
  "function terminate(worker){\
  \  return function(){\
  \    return worker.terminate();\
  \  };\
  \};" :: forall e. Worker -> Eff (parallel :: Parallel | e) Unit

workerInternalMonadic :: forall e. String -> Eff (parallel :: Parallel, trace :: Trace | e) String 
workerInternalMonadic fn = getScripts >>= importScripts >>> t fn >>> return
  where 
    t fn ss = "var window = self; var document = {};"++ ss ++ "\
    \self.addEventListener('message', function(e){\ 
    \    var res = " ++ fn ++ "(e.data)();\
    \    postMessage(res);\
    \}, false);"

workerInternalPure :: forall e. String -> Eff (parallel :: Parallel, trace :: Trace | e) String 
workerInternalPure fn = getScripts >>= importScripts >>> t fn >>> return
  where 
    t fn ss = "var window = self; var document = {};"++ ss ++ "\
    \self.addEventListener('message', function(e){\
    \    var res = " ++ fn ++ "(e.data);\
    \    postMessage(res);\
    \}, false);"

workerInternalPureToMonad :: forall e. String -> Eff (parallel :: Parallel, trace :: Trace | e) String 
workerInternalPureToMonad fn = getScripts >>= importScripts >>> t fn >>> return
  where 
    t fn ss = "var window = self; var document = {};"++ ss ++ "\
    \self.addEventListener('message', function(e){\ 
    \    var res = " ++ fn ++ "(e.data);\
    \    postMessage(res());\
    \}, false);"

foreign import workerInternal
  "function workerInternal(fn){\
  \  return function(){\
  \     console.log(fn.toString());\
  \  };\
  \}" :: forall a e. a -> Eff (parallel :: Parallel | e) Unit

getWorkerM :: forall e. String -> Eff(trace :: Trace, parallel :: Parallel | e) Worker
getWorkerM fn = workerInternalMonadic fn >>= makeWorker

getWorkerm :: forall e. String -> Eff(trace :: Trace, parallel :: Parallel | e) Worker
getWorkerm fn = workerInternalPureToMonad fn >>= makeWorker

getWorker :: forall e. String -> Eff(trace :: Trace, parallel :: Parallel | e) Worker
getWorker fn = workerInternalPure fn >>= makeWorker

subPostRet cb wks = subscribeWorker cb wks >>= (flip postMessage) >>> return

workM fn cb = getWorkerM fn >>= subPostRet cb
workm fn cb = getWorkerm fn >>= subPostRet cb
work  fn cb = getWorker  fn >>= subPostRet cb