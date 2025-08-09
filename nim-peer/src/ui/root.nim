import chronos, unicode, tables, deques, sequtils, os
from illwave as iw import nil, `[]`, `[]=`, `==`, width, height
from nimwave as nw import nil
from terminal import nil
import libp2p

import ./scrollingtextbox
import ../utils

type State = object
  peers: seq[string]
  messages: seq[string]
  inputBuffer: string
  systemLogs: seq[string]

include nimwave/prelude

const
  PEERS_PANEL_WIDTH: int = 10
  TOP_HEIGHT: int = 15

type
  PeersPanel = ref object of nw.Node
  ChatPanel = ref object of nw.Node
  SystemPanel = ref object of nw.Node

method render(node: ChatPanel, ctx: var nw.Context[State]) =
  let width =
    if PEERS_PANEL_WIDTH < iw.width(ctx.tb):
      iw.width(ctx.tb) - PEERS_PANEL_WIDTH
    else:
      iw.width(ctx.tb)
  ctx = nw.slice(ctx, 0, 0, width, TOP_HEIGHT)
  render(
    nw.Box(
      border: nw.Border.Single,
      direction: nw.Direction.Vertical,
      children: nw.seq(ctx.data.messages),
    ),
    ctx,
  )

method render(node: PeersPanel, ctx: var nw.Context[State]) =
  let width = PEERS_PANEL_WIDTH
  let height = TOP_HEIGHT
  ctx = nw.slice(ctx, 0, 0, width, height)
  render(
    nw.Box(
      border: nw.Border.Single,
      direction: nw.Direction.Vertical,
      children: nw.seq(ctx.data.peers),
    ),
    ctx,
  )

method render(node: SystemPanel, ctx: var nw.Context[State]) =
  let width = iw.width(ctx.tb)
  let height =
    if TOP_HEIGHT < iw.height(ctx.tb):
      iw.height(ctx.tb) - TOP_HEIGHT
    else:
      iw.height(ctx.tb)
  ctx = nw.slice(ctx, 0, 0, width, height)
  render(
    nw.Box(
      border: nw.Border.Single,
      direction: nw.Direction.Vertical,
      children: nw.seq(ctx.data.systemLogs),
    ),
    ctx,
  )

proc shortPeerId(peerId: PeerId): string {.raises: [ValueError].} =
  let strPeerId = $peerId
  if strPeerId.len < 7:
    raise newException(ValueError, "PeerId too short")
  strPeerId[^7 ..^ 1]

proc asyncGetKey(stdinReader: StreamTransport): Future[iw.Key] {.async.} =
  await stdinReader.readKey()

proc runUI*(
    gossip: GossipSub,
    recvQ: AsyncQueue[string],
    peerQ: AsyncQueue[PeerId],
    myPeerId: PeerId,
) {.async: (raises: [Exception]).} =
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
  ctx.data.peers = @["Peers", "", shortPeerId(myPeerId) & " (You)"]
  ctx.data.messages = @["Chat", ""]
  ctx.data.systemLogs = @["System", ""]
  ctx.data.inputBuffer = ""

  ctx.tb = iw.initTerminalBuffer(terminal.terminalWidth(), terminal.terminalHeight())

  # Pipe to read stdin from main thread
  let (rfd, wfd) = createAsyncPipe()
  let stdinReader = fromPipe(rfd)

  # main UI tick comes here
  while true:
    key = await asyncGetKey(stdinReader)
    if key == iw.Key.Mouse:
      mouseQueue.addLast(mouse)
      case mouse.scrollDir
      of iw.ScrollDirection.sdUp:
        keyQueue.addLast(iw.Key.Up)
      of iw.ScrollDirection.sdDown:
        keyQueue.addLast(iw.Key.Down)
      else:
        discard
    elif key != iw.Key.None:
      keyQueue.addLast(key)

    mouse =
      if mouseQueue.len > 0:
        mouseQueue.popFirst
      else:
        iw.MouseInfo()
    key = if keyQueue.len > 0: keyQueue.popFirst else: iw.Key.None

    var msgFromMe = false
    # process key if typed
    if key in {iw.Key.Space .. iw.Key.Tilde}:
      ctx.data.inputBuffer.add(cast[char](key.ord))
    elif key == iw.Key.Backspace and ctx.data.inputBuffer.len > 0:
      ctx.data.inputBuffer.setLen(ctx.data.inputBuffer.len - 1)
    elif key == iw.Key.Enter:
      discard await gossip.publish(
        GOSSIPSUB_CHAT_TOPIC, cast[seq[byte]](@(ctx.data.inputBuffer))
      )
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
    if not recvQ.empty():
      let msg = await recvQ.get()
      echo "received msg: " & msg
      if not msgFromMe:
        # TODO: print peer where msg is coming from
        ctx.data.messages.add(msg) # show message in ui

    # renderRoot(
    #   nw.Box(
    #     direction: nw.Direction.Vertical,
    #     children: nw.seq(
    #       nw.Box(
    #         direction: nw.Direction.Horizontal,
    #         children: nw.seq(ChatPanel(), PeersPanel()),
    #       ),
    #       SystemPanel(),
    #     ),
    #   ),
    #   ctx,
    # )

#     # render
#     iw.display(ctx.tb, prevTb)
#     prevTb = ctx.tb

#     sleep(50)
#     iw.clear(ctx.tb)
