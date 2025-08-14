import tables, deques, strutils, sequtils, os

import libp2p, chronos, cligen, chronicles
from libp2p/protocols/pubsub/rpc/message import Message

from illwave as iw import nil, `[]`, `[]=`, `==`, width, height
from terminal import nil

import ./ui/root
import ./utils
import ./file_exchange

proc cleanup() {.noconv.} =
  terminal.resetAttributes()
  terminal.showCursor()

  # Clear screen and move cursor to top-left
  stdout.write("\e[2J\e[H") # ANSI escape: clear screen & home
  stdout.flushFile()

  quit(130) # SIGINT conventional exit code

proc start(
    peerId: PeerId, addrs: seq[MultiAddress], headless: bool, room: string
) {.async.} =
  # setup peer
  let switch = SwitchBuilder
    .new()
    .withRng(newRng())
    .withTcpTransport()
    .withYamux()
    .withNoise()
    .build()
  let gossip = GossipSub.init(switch = switch, triggerSelf = true)
  switch.mount(gossip)

  let fileExchange = FileExchange.new()
  switch.mount(fileExchange)

  await switch.start()

  let
    recvQ = newAsyncQueue[string]()
    peerQ = newAsyncQueue[PeerId]()
    systemQ = newAsyncQueue[string]()

  # connect to peer
  try:
    await switch.connect(peerId, addrs)
  except Exception as exc:
    await systemQ.put("Connection error: " & exc.msg)
    if switch != nil:
      await switch.stop()
    return

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
    await systemQ.put("Received message")
    await systemQ.put("    Source: " & $msg.fromPeer)
    await systemQ.put("    Topic: " & $topic)
    await systemQ.put("    Seqno: " & $seqnoToUint64(msg.seqno))
    await systemQ.put(" ") # empty line
    return ValidationResult.Accept

  # when a new file is announced, download it
  let onNewFile = proc(
      topic: string, msg: Message
  ): Future[ValidationResult] {.async, gcsafe.} =
    let fileId = sanitizeFileId(cast[string](msg.data))
    # use known addresses since we can't use kad to get peer addrs
    # this means that we're unable to get files from a peer to which we don't have the addresses
    let conn = await switch.dial(msg.fromPeer, addrs, FileExchangeCodec)
    let filePath = getTempDir() / fileId
    let fileContents = await fileExchange.requestFile(conn, fileId)
    writeFile(filePath, fileContents)
    await conn.close()
    # Save file in /tmp/fileId
    await systemQ.put("Downloaded file to " & filePath)
    await systemQ.put(" ") # empty line
    return ValidationResult.Accept

  # when a new peer is announced
  let onNewPeer = proc(topic: string, data: seq[byte]) {.async, gcsafe.} =
    let peerId = PeerId.init(data).valueOr:
      await systemQ.put("Error parsing PeerId from data: " & $data)
      await systemQ.put(" ") # empty line
      return
    await peerQ.put(peerId)
    await systemQ.put("New peer " & $peerId)

  # register validators and handlers

  # chat messages
  gossip.subscribe(room, nil)
  gossip.addValidator(room, onChatMsg)

  # files
  gossip.subscribe(ChatFileTopic, nil)
  gossip.addValidator(ChatFileTopic, onNewFile)

  # peer discovery
  gossip.subscribe(PeerDiscoveryTopic, onNewPeer)

  # Handle Ctrl+C
  setControlCHook(cleanup)

  try:
    if headless:
      runForever()
    else:
      await runUI(gossip, room, recvQ, peerQ, systemQ, switch.peerInfo.peerId)
      iw.deinit()
      cleanup()
  except Exception as exc:
    cleanup()
    error "Unexpected error", error = exc.msg
  finally:
    if switch != nil:
      await switch.stop()

proc cli(room = ChatTopic, headless = false, args: seq[string]) =
  if args.len < 2:
    echo "usage: nimble run -- <peer_id> <multiaddress>, [<multiaddresss>, ...] [--room <room-name>] [--headless]"
    return
  let peerId = PeerId.init(args[0]).get()
  let addrs = args[1 ..^ 1].mapIt(MultiAddress.init(it).get())
  waitFor start(peerId, addrs, headless, room)

when isMainModule:
  dispatch cli
