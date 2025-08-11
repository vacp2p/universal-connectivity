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
  systemLogs: seq[string]
  inputBuffer*: string

include nimwave/prelude

const
  PeersPanelWidth: int = 10
  TopHeight: int = 15

type
  PeersPanel = ref object of nw.Node
  ChatPanel = ref object of nw.Node
  SystemPanel = ref object of nw.Node

method render(node: ChatPanel, ctx: var nw.Context[State]) =
  let width =
    if PeersPanelWidth < iw.width(ctx.tb):
      iw.width(ctx.tb) - PeersPanelWidth
    else:
      iw.width(ctx.tb)
  ctx = nw.slice(ctx, 0, 0, width, TopHeight)
  render(
    nw.Box(
      border: nw.Border.Single,
      direction: nw.Direction.Vertical,
      children: nw.seq(ctx.data.messages),
    ),
    ctx,
  )

method render(node: PeersPanel, ctx: var nw.Context[State]) =
  let width = PeersPanelWidth
  let height = TopHeight
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
    if TopHeight < iw.height(ctx.tb):
      iw.height(ctx.tb) - TopHeight
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

proc runUI*(
    gossip: GossipSub,
    room: string,
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

  # TODO: publish my peerid in peerid topic

  while true:
    key = iw.getKey(mouse)
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

    if key in {iw.Key.Space .. iw.Key.Tilde}:
      ctx.data.inputBuffer.add(cast[char](key.ord))
    elif key == iw.Key.Backspace and ctx.data.inputBuffer.len > 0:
      ctx.data.inputBuffer.setLen(ctx.data.inputBuffer.len - 1)
    elif key == iw.Key.Enter:
      # TODO: handle /file command to send/publish files
      # /file filename (registers ID in local database, sends fileId, handles incoming file requests)
      discard await gossip.publish(
        room, cast[seq[byte]](@(ctx.data.inputBuffer))
      )
      ctx.data.messages.add("You: " & ctx.data.inputBuffer) # show message in ui
      ctx.data.inputBuffer = "" # clear input buffer
    elif key != iw.Key.None:
      discard

    # update peer list if there's a new peer from peerQ
    if peerQ.len != 0:
      # TODO: handle peer removals
      let newPeer = await peerQ.get()
      if not ctx.data.peers.contains(shortPeerId(newPeer)):
        ctx.data.peers.add(shortPeerId(newPeer))

    # update messages if there's a new message from recvQ
    if not recvQ.empty():
      let msg = await recvQ.get()
      ctx.data.messages.add(msg) # show message in ui

    renderRoot(
      nw.Box(
        direction: nw.Direction.Vertical,
        children: nw.seq(
          nw.Box(
            direction: nw.Direction.Horizontal,
            children: nw.seq(ChatPanel(), PeersPanel()),
          ),
          SystemPanel(),
        ),
      ),
      ctx,
    )

    # render
    iw.display(ctx.tb, prevTb)
    prevTb = ctx.tb

    await sleepAsync(50.milliseconds)
    iw.clear(ctx.tb)
