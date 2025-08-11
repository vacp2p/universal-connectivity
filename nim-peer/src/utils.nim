const
  ChatTopic*: string = "universal-connectivity"
  ChatFileTopic*: string = "universal-connectivity-file"
  PeerDiscoveryTopic*: string =
    "universal-connectivity-browser-peer-discovery"

import libp2p

proc shortPeerId*(peerId: PeerId): string {.raises: [ValueError].} =
  let strPeerId = $peerId
  if strPeerId.len < 7:
    raise newException(ValueError, "PeerId too short")
  strPeerId[^7 ..^ 1]
