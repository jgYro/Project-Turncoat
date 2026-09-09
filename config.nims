switch("define", "ssl")
switch("define", "happyxStdserver")
switch("nimcache", "nimcache")
# begin Nimble config (version 2)
--noNimblePath
when withDir(thisDir(), system.fileExists("nimble.paths")):
  include "nimble.paths"
# end Nimble config
