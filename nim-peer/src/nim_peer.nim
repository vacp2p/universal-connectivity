from illwave as iw import nil, `[]`, `[]=`, `==`, width, height
from terminal import nil

import chronos, tables, deques, strutils, sequtils
import libp2p, cligen
from libp2p/protocols/pubsub/rpc/message import Message

import ./ui/root
import ./utils

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

  let recvQ = newAsyncQueue[string](0)
  let peerQ = newAsyncQueue[PeerId](0)

  # connect to peer
  await switch.connect(peerId, addrs)

  await sleepAsync(3.seconds)

  # register topic handlers
  # chat topic actually needs validator instead of handler
  # validators allow us to get information about peers sending the messages
  let validator1 = proc(
      topic: string, msg: Message
  ): Future[ValidationResult] {.async, gcsafe.} =
    let strMsg = cast[string](msg.data)
    await recvQ.put($msg.fromPeer & ": " & strMsg)
    return ValidationResult.Accept
  gossip.subscribe(GOSSIPSUB_CHAT_TOPIC, nil)
  gossip.addValidator(GOSSIPSUB_CHAT_TOPIC, validator1)

  # for peer discovery, we just need the message itself
  let handler1 = proc(topic: string, data: seq[byte]): Future[void] {.async, gcsafe.} =
    let peerId: PeerId = switch.peerInfo.peerId # TODO: obtain peerId from data
    await peerQ.put(peerId)
  gossip.subscribe(GOSSIPSUB_PEER_DISCOVERY_TOPIC, handler1)

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
