import chronos, unicode, tables, deques, strutils, sequtils, os
from illwave as iw import nil, `[]`, `[]=`, `==`, width, height
from nimwave as nw import nil
from terminal import nil
import libp2p, cligen

type
  State* = object
    peers*: seq[string]
    messages*: seq[string]
    inputBuffer*: string
    systemLogs*: seq[string]

const
  GOSSIPSUB_CHAT_TOPIC: string = "universal-connectivity"
  GOSSIPSUB_CHAT_FILE_TOPIC: string = "universal-connectivity-file"
  GOSSIPSUB_PEER_DISCOVERY_TOPIC: string = "universal-connectivity-browser-peer-discovery"


include nimwave/prelude

type
  PeersPanel = ref object of nw.Node
  ChatPanel = ref object of nw.Node
  SystemPanel = ref object of nw.Node

proc renderPanel*(node: nw.Node, ctx: var nw.Context[State], title: string, linesData: seq[string], width: Natural, height: Natural) =
  ctx = nw.slice(ctx, 0, 0, width, height)
  var lines = nw.seq(title) & nw.seq(linesData)
  render(
    nw.Box(
      border: nw.Border.Single,
      direction: nw.Direction.Vertical,
      children: lines
    ),
    ctx
  )

method render*(node: ChatPanel, ctx: var nw.Context[State]) =
  let width = int(float(iw.width(ctx.tb))*0.6)
  let height = int(float(iw.height(ctx.tb)) * 0.4)
  renderPanel(node, ctx, "Chat", ctx.data.messages, width, height)

method render*(node: PeersPanel, ctx: var nw.Context[State]) =
  let width = int(float(iw.width(ctx.tb))*0.3)
  let height = int(float(iw.height(ctx.tb)) * 0.4)
  renderPanel(node, ctx, "Peers", ctx.data.peers, width, height)


method render*(node: SystemPanel, ctx: var nw.Context[State]) =
  let width = iw.width(ctx.tb)
  let height = int(float(iw.height(ctx.tb)) * 0.6)
  renderPanel(node, ctx, "System", ctx.data.systemLogs, width, height)

proc runUI(gossip: GossipSub, recvQ: AsyncQueue[string], peerQ: AsyncQueue[PeerId]) {.async: (raises: [Exception]).} =
  var
    ctx = nw.initContext[State]()
    prevTb: iw.TerminalBuffer
    mouseQueue: Deque[iw.MouseInfo]
    keyQueue: Deque[iw.Key]
    mouse: iw.MouseInfo
    key: iw.Key
  terminal.enableTrueColors()
  try:
    iw.init()
  except:
    echo "iw.init error"
  terminal.hideCursor()
  ctx.data.peers =  @[]
  ctx.data.messages = @[]
  ctx.data.systemLogs = @[]
  ctx.data.inputBuffer = ""

  ctx.tb = iw.initTerminalBuffer(terminal.terminalWidth(), terminal.terminalHeight())

  # main UI tick comes here
  while true:
    key = iw.getKey(mouse)
    if key == iw.Key.Mouse:
      mouseQueue.addLast(mouse)
      case mouse.scrollDir:
      of iw.ScrollDirection.sdUp: keyQueue.addLast(iw.Key.Up)
      of iw.ScrollDirection.sdDown: keyQueue.addLast(iw.Key.Down)
      else: discard
    elif key != iw.Key.None:
      keyQueue.addLast(key)

    mouse = if mouseQueue.len > 0: mouseQueue.popFirst else: iw.MouseInfo()
    key = if keyQueue.len > 0: keyQueue.popFirst else: iw.Key.None

    var msgFromMe = false
    # process key if typed
    if key in {iw.Key.Space .. iw.Key.Tilde}:
      ctx.data.inputBuffer.add(cast[char](key.ord))
    elif key == iw.Key.Backspace and ctx.data.inputBuffer.len > 0:
      ctx.data.inputBuffer.setLen(ctx.data.inputBuffer.len - 1)
    elif key == iw.Key.Enter:
      echo "runUI: publishing " & ctx.data.inputBuffer
      discard await gossip.publish(GOSSIPSUB_CHAT_TOPIC, cast[seq[byte]](@(ctx.data.inputBuffer)))
      ctx.data.messages.add("You: " & ctx.data.inputBuffer) # show message in ui
      ctx.data.inputBuffer = "" # clear input buffer
      msgFromMe = true
    elif key != iw.Key.None:
      discard

    # update peer list if there's a new peer from peerQ
    if peerQ.len != 0:
      # TODO: handle peer removals
      let newPeer = await peerQ.get()
      ctx.data.peers.add($newPeer)

    # update messages if there's a new message from recvQ
    if recvQ.len != 0:
      let msg = recvQ.get()
      if not msgFromMe:
        # TODO: print peer where msg is coming from
        ctx.data.messages.add("peer: " & await recvQ.get()) # show message in ui

    renderRoot(
      nw.Box(
        direction: nw.Direction.Vertical,
        children: nw.seq(
          nw.Box(
            direction: nw.Direction.Horizontal,
            children: nw.seq(ChatPanel(), PeersPanel())
          ),
          SystemPanel()
        )
      ),
      ctx
    )

    # render
    iw.display(ctx.tb, prevTb)
    prevTb = ctx.tb

    sleep(5)

proc start(peerId: PeerId, addrs: seq[MultiAddress]) {.async.} =
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
  await switch.start()

  let recvQ = newAsyncQueue[string](0)
  let peerQ = newAsyncQueue[PeerId](0)

  # connect to peer
  await switch.connect(peerId, addrs)

  await sleepAsync(3.seconds)

  let handler1 = proc(topic: string, data: seq[byte]): Future[void] {.async, gcsafe.} =
    let strData = cast[string](data)
    await recvQ.put(strData)

  # register topic handlers
  gossip.subscribe(GOSSIPSUB_CHAT_TOPIC, handler1)

  let handler2 = proc(topic: string, data: seq[byte]): Future[void] {.async, gcsafe.} =
    let peerId: PeerId = switch.peerInfo.peerId # TODO: obtain peerId from data
    await peerQ.put(peerId)

  gossip.subscribe(GOSSIPSUB_PEER_DISCOVERY_TOPIC, handler2)

  try:
    await runUI(gossip, recvQ, peerQ)
    iw.deinit()
  except:
    discard
  finally:
    if switch != nil:
      await switch.stop()
    terminal.showCursor()

proc cli(args: seq[string]) =
  if args.len < 2:
    # print usage
    echo "usage: nimble run -- <peer_id> <multiaddress>, [<multiaddresss>, ...]"
    return
  let peerId = PeerId.init(args[0]).get()
  let addrs = args[1..^1].mapIt(MultiAddress.init(it).get())
  waitFor start(peerId, addrs)


when isMainModule:
  dispatch cli#, help={"peerIdStr": "12D3KooWCsw7PcEWuiYa45JaigaXSbo8YTAU5MyhHsHrJy", "multiaddresses": "/ip4/127.0.0.1/tcp/5559 /ip4/192.168.0.3/tcp/9995"}
