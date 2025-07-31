# Package

version       = "0.1.0"
author        = "Gabriel Cruz"
description   = "universal-connectivity nim peer"
license       = "MIT"
srcDir        = "src"
bin           = @["nim_peer"]


# Dependencies

requires "nim >= 2.2.0", "nimwave", "chronos", "libp2p", "illwill", "cligen"
