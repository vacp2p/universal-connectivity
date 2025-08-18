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
  try:
    iw.deinit()
  except:
    discard
  # Clear screen and move cursor to top-left
  stdout.write("\e[2J\e[H") # ANSI escape: clear screen & home
  stdout.flushFile()
  quit(130) # SIGINT conventional exit code

proc start(addrs: Opt[MultiAddress], headless: bool, room: string) {.async.} =
  # Handle Ctrl+C
  setControlCHook(cleanup)

  # TODO: check if local.peerid file exists

  # setup peer
  # TDOO: if local.peerid exists, read that, else writeFile...
  let switch = SwitchBuilder
    .new()
    .withRng(newRng())
    .withTcpTransport()
    .withAddresses(@[MultiAddress.init("/ip4/0.0.0.0/tcp/9093").tryGet()])
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
    peerQ = newAsyncQueue[(PeerId, PeerEventKind)]()
    systemQ = newAsyncQueue[string]()

  await systemQ.put("Started switch: " & $switch.peerInfo.peerId)
  writeFile("./local.peerid", $switch.peerInfo.peerId)

  # if --connect was specified, connect to peer
  if addrs.isSome():
    try:
      discard await switch.connect(addrs.get())
    except Exception as exc:
      error "Connection error", error = exc.msg
      await systemQ.put("Connection error: " & exc.msg)

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
    await peerQ.put((msg.fromPeer, PeerEventKind.Joined))
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
    # this will only work if we're connected to `fromPeer` (since we don't have kad-dht)
    let conn = await switch.dial(msg.fromPeer, FileExchangeCodec)
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
    await peerQ.put((peerId, PeerEventKind.Joined))

  # register validators and handlers

  # receive chat messages
  gossip.subscribe(room, nil)
  gossip.addValidator(room, onChatMsg)

  # receive files offerings
  gossip.subscribe(ChatFileTopic, nil)
  gossip.addValidator(ChatFileTopic, onNewFile)

  # receive newly connected peers through gossipsub
  gossip.subscribe(PeerDiscoveryTopic, onNewPeer)

  let onPeerJoined = proc(
      peer: PeerId, peerEvent: PeerEvent
  ) {.gcsafe, async: (raises: [CancelledError]).} =
    await peerQ.put((peer, PeerEventKind.Joined))

  let onPeerLeft = proc(
      peer: PeerId, peerEvent: PeerEvent
  ) {.gcsafe, async: (raises: [CancelledError]).} =
    await peerQ.put((peer, PeerEventKind.Left))

  # receive newly connected peers through direct connections
  switch.addPeerEventHandler(onPeerJoined, PeerEventKind.Joined)
  switch.addPeerEventHandler(onPeerLeft, PeerEventKind.Left)

  # add already connected peers
  for peerId in switch.peerStore[AddressBook].book.keys:
    await peerQ.put((peerId, PeerEventKind.Joined))

  if headless:
    runForever()
  else:
    try:
      await runUI(gossip, room, recvQ, peerQ, systemQ, switch.peerInfo.peerId)
    except Exception as exc:
      echo "Unexpected error: " & exc.msg
    finally:
      if switch != nil:
        await switch.stop()
      cleanup()

proc cli(connect = "", room = ChatTopic, headless = false) =
  var addrs = Opt.none(MultiAddress)
  if connect.len > 0:
    addrs = Opt.some(MultiAddress.init(connect).get())

  waitFor start(addrs, headless, room)

when isMainModule:
  dispatch cli,
    help = {
      "connect": "full multiaddress (with /p2p/ peerId) of the node to connect to",
      "room": "Room name",
    }
