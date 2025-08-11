const
  GOSSIPSUB_CHAT_TOPIC*: string = "universal-connectivity"
  GOSSIPSUB_CHAT_FILE_TOPIC*: string = "universal-connectivity-file"
  GOSSIPSUB_PEER_DISCOVERY_TOPIC*: string =
    "universal-connectivity-browser-peer-discovery"

import libp2p

proc shortPeerId*(peerId: PeerId): string {.raises: [ValueError].} =
  let strPeerId = $peerId
  if strPeerId.len < 7:
    raise newException(ValueError, "PeerId too short")
  strPeerId[^7 ..^ 1]
