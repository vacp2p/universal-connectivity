import chronos, unicode, tables, deques, strutils, sequtils, os
from illwave as iw import nil, `[]`, `[]=`, `==`, width, height
from nimwave as nw import nil
from terminal import nil
import libp2p, cligen

type
  State* = object
    focusIndex*: int
    focusAreas*: ref seq[iw.TerminalBuffer]
    peers*: seq[string]
    chats*: seq[string]
    messages*: seq[string]
    inputBuffer*: string
    switch*: Switch

const
  GOSSIPSUB_CHAT_TOPIC: string = "universal-connectivity"
  GOSSIPSUB_CHAT_FILE_TOPIC: string = "universal-connectivity-file"
  GOSSIPSUB_PEER_DISCOVERY_TOPIC: string = "universal-connectivity-browser-peer-discovery"


include nimwave/prelude

proc addFocusArea(ctx: var nw.Context[State]): bool =
  result = ctx.data.focusIndex == ctx.data.focusAreas[].len
  ctx.data.focusAreas[].add(ctx.tb)

# ------------------------
# Panels
# ------------------------

type
  PeersPanel = ref object of nw.Node
  ChatsPanel = ref object of nw.Node
  MessagesPanel = ref object of nw.Node

proc renderPanel*(node: nw.Node, ctx: var nw.Context[State], title: string, linesData: seq[string], heightRatio: float) =
  let width = iw.width(ctx.tb)
  let height = int(float(iw.height(ctx.tb)) * heightRatio)
  ctx = nw.slice(ctx, 0, 0, width, height)
  let focused = addFocusArea(ctx)
  var lines = nw.seq(title) & nw.seq(linesData)
  render(
    nw.Box(
      direction: nw.Direction.Vertical,
      border: if focused: nw.Border.Double else: nw.Border.Single,
      children: lines
    ),
    ctx
  )

method render*(node: PeersPanel, ctx: var nw.Context[State]) =
  renderPanel(node, ctx, "Peers:", ctx.data.peers, 0.2)

method render*(node: ChatsPanel, ctx: var nw.Context[State]) =
  renderPanel(node, ctx, "Chats:", ctx.data.chats, 0.2)

method render*(node: MessagesPanel, ctx: var nw.Context[State]) =
  let width = iw.width(ctx.tb)
  let height = int(float(iw.height(ctx.tb)) * 0.4)
  ctx = nw.slice(ctx, 0, 0, width, height)
  let focused = addFocusArea(ctx)
  render(
    nw.Box(
      direction: nw.Direction.Vertical,
      border: if focused: nw.Border.Double else: nw.Border.Single,
      children: nw.seq("Messages:") & nw.seq(ctx.data.messages) & nw.seq("> " & ctx.data.inputBuffer)
    ),
    ctx
  )

# ------------------------
# Tick (main render + events)
# ------------------------

proc tick*(ctx: var nw.Context[State], mouse: iw.MouseInfo, key: iw.Key) =
  # Use passed mouse/key only (no globals)

  if mouse.button == iw.MouseButton.mbLeft and mouse.action == iw.MouseButtonAction.mbaPressed:
    for i in countDown(ctx.data.focusAreas[].len-1, 0):
      if iw.contains(ctx.data.focusAreas[i], mouse):
        ctx.data.focusIndex = i
        break

  var focusChange = case key
    of iw.Key.Up: -1
    of iw.Key.Down: 1
    else: 0

  if focusChange != 0 and ctx.data.focusAreas[].len > 0:
    if ctx.data.focusIndex + focusChange in 0 ..< ctx.data.focusAreas[].len:
      ctx.data.focusIndex += focusChange

  if key in {iw.Key.Space .. iw.Key.Tilde}:
    ctx.data.inputBuffer.add(cast[char](key.ord))
  elif key == iw.Key.Backspace and ctx.data.inputBuffer.len > 0:
    ctx.data.inputBuffer.setLen(ctx.data.inputBuffer.len - 1)
  elif key == iw.Key.Enter:
    ctx.data.messages.add("You: " & ctx.data.inputBuffer)
    ctx.data.inputBuffer = ""
  elif key != iw.Key.None:
    discard

  ctx.data.focusAreas[] = @[]

  try:
    renderRoot(
      nw.Box(
        direction: nw.Direction.Vertical,
        children: nw.seq(
          nw.Box(direction: nw.Direction.Horizontal, children: nw.seq(PeersPanel(), ChatsPanel())),
          MessagesPanel()
        )
      ),
      ctx
    )
  except Exception as e:
    echo "Render error: ", e.msg

# ------------------------
# Init / deinit
# ------------------------

proc deinit(ctx: var nw.Context[State]) =
  try:
    iw.deinit()
  except:
    echo "iw.deinit error"
  terminal.showCursor()

proc initCtx(ctx: var nw.Context[State]) =
  terminal.enableTrueColors()
  try:
    iw.init()
  except:
    echo "iw.init error"
  terminal.hideCursor()

  ctx.data.focusIndex = 0
  ctx.data.focusAreas = new seq[iw.TerminalBuffer]
  ctx.data.peers =  @[]
  ctx.data.chats = @["chat1", "chat2"]
  ctx.data.messages = @["Welcome to nim universal-connectivity-app!"]
  ctx.data.inputBuffer = ""
  ctx.data.switch = SwitchBuilder.new()
    .withRng(newRng())
    .withTcpTransport()
    .withYamux()
    .withNoise()
    .build()

# ------------------------
# Async main loop
# ------------------------

proc runUi*(ctx: var nw.Context[State], gossip: GossipSub) =
  var
    prevTb: iw.TerminalBuffer
    mouseQueue: Deque[iw.MouseInfo]
    keyQueue: Deque[iw.Key]
    mouse: iw.MouseInfo
    key: iw.Key

  ctx.tb = iw.initTerminalBuffer(terminal.terminalWidth(), terminal.terminalHeight())

  while true:
    let width = terminal.terminalWidth()
    let height = terminal.terminalHeight()
    if ctx.tb.width() != width or ctx.tb.height() != height:
      ctx.tb = iw.initTerminalBuffer(width, height)

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

    # update peer list from switch
    ctx.data.peers = ctx.data.switch.peerInfo.addrs.mapIt($it)

    tick(ctx, mouse, key)
    iw.display(ctx.tb, prevTb)
    prevTb = ctx.tb

    sleep(5)

proc peer*(peerId: PeerId, addrs: seq[MultiAddress]) {.async.} =
  var ctx = nw.initContext[State]()
  initCtx(ctx)
  let gossip = GossipSub.init(switch = ctx.data.switch, triggerSelf = true)
  ctx.data.switch.mount(gossip)
  await ctx.data.switch.start()

  # connect to peer
  await ctx.data.switch.connect(peerId, addrs)

  await sleepAsync(3.seconds)
  #discard await gossip.subscribe(GOSSIPSUB_CHAT_TOPIC)
  #discard await gossip.subscribe(GOSSIPSUB_CHAT_FILE_TOPIC)
  #discard await gossip.subscribe(GOSSIPSUB_PEER_DISCOVERY_TOPIC)
  discard await gossip.publish(GOSSIPSUB_CHAT_TOPIC, cast[seq[byte]](@"hello there"))
  #let conn = await ctx.data.switch.dial(peerId, addrs, GossipSubCodec_12)
  try:
    runUi(ctx, gossip)
  except Exception:
    if ctx.data.switch != nil:
      await ctx.data.switch.stop()
    deinit(ctx)

proc cli(args: seq[string]) =
  let peerId = PeerId.init(args[0]).get()
  let addresses = args[1..^1].mapIt(MultiAddress.init(it).get())
  waitFor peer(peerId, addresses)

when isMainModule:
  dispatch cli#, help={"peerIdStr": "12D3KooWCsw7PcEWuiYa45JaigaXSbo8YTAU5MyhHsHrJy", "multiaddresses": "/ip4/127.0.0.1/tcp/5559 /ip4/192.168.0.3/tcp/9995"}
