from illwave as iw import nil, `[]`, `[]=`, `==`, width, height
from terminal import nil

import chronos, tables, deques, strutils, sequtils
import libp2p, cligen
from libp2p/protocols/pubsub/rpc/message import Message

import ./ui/root
import ./utils

const MAX_FILE_SIZE: int = 1024 # 1KiB

proc start(peerId: PeerId, addrs: seq[MultiAddress]) {.async.} =
  # setup peer
  let switch = SwitchBuilder
    .new()
    .withRng(newRng())
    .withTcpTransport()
    .withYamux()
    .withNoise()
    .build()
  let gossip =
    GossipSub.init(switch = switch, triggerSelf = true, verifySignature = false)
  switch.mount(gossip)
  await switch.start()

  let recvQ = newAsyncQueue[string]()
  let peerQ = newAsyncQueue[PeerId]()

  # connect to peer
  await switch.connect(peerId, addrs)

  # wait so that gossipsub can form mesh
  await sleepAsync(3.seconds)

  # topic handlers
  # chat and file handlers actually need to be validators instead of regular handlers
  # validators allow us to get information about which peer sent a message
  let onChatMsg = proc(
      topic: string, msg: Message
  ): Future[ValidationResult] {.async, gcsafe.} =
    let strMsg = cast[string](msg.data)
    await recvQ.put(shortPeerId(msg.fromPeer) & ": " & strMsg)
    await peerQ.put(msg.fromPeer)
    return ValidationResult.Accept

  # when a new file is announced, download it
  let onNewFile = proc(
      topic: string, msg: Message
  ): Future[ValidationResult] {.async, gcsafe.} =
    let fileId = msg.data
    # use known addresses since we can't use kad to get peer addrs
    # this means that we're unable to get files from a peer to which we don't have the addresses
    let conn = await switch.dial(msg.fromPeer, addrs, "/universal-connectivity-file/1")
    defer: await conn.close()
    # Request file
    await conn.writeLp(fileId)
    # Read file contents
    let fileContents = await conn.readLp(MAX_FILE_SIZE)
    # TODO: do sth with file
    let strFile = cast[string](fileContents)
    echo "downloaded file: " & strFile
    return ValidationResult.Accept

  # when a new peer is announced
  let onNewPeer = proc(topic: string, data: seq[byte]): Future[void] {.async, gcsafe.} =
    let peerId: PeerId = switch.peerInfo.peerId # TODO: obtain peerId from data
    await peerQ.put(peerId)

  # register validators and handlers

  # chat messages
  gossip.subscribe(GOSSIPSUB_CHAT_TOPIC, nil)
  gossip.addValidator(GOSSIPSUB_CHAT_TOPIC, onChatMsg)

  # files
  gossip.subscribe(GOSSIPSUB_CHAT_FILE_TOPIC, nil)
  gossip.addValidator(GOSSIPSUB_CHAT_FILE_TOPIC, onNewFile)

  # peer discovery
  gossip.subscribe(GOSSIPSUB_PEER_DISCOVERY_TOPIC, onNewPeer)

  try:
    await runUI(gossip, recvQ, peerQ, switch.peerInfo.peerId)
    iw.deinit()
  except Exception as exc:
    echo "runUI error: " & exc.msg
    discard
  finally:
    if switch != nil:
      await switch.stop()
    terminal.showCursor()

proc cli(args: seq[string]) =
  if args.len < 2:
    echo "usage: nimble run -- <peer_id> <multiaddress>, [<multiaddresss>, ...]"
    return
  let peerId = PeerId.init(args[0]).get()
  let addrs = args[1 ..^ 1].mapIt(MultiAddress.init(it).get())
  waitFor start(peerId, addrs)

when isMainModule:
  dispatch cli
