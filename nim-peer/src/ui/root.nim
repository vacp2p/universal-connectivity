import chronos, deques
from illwave as iw import nil, `[]`, `[]=`, `==`, width, height
from nimwave as nw import nil
from terminal import nil
import libp2p

import ./scrollingtextbox
import ./context
import ../utils

const
  InputPanelHeight: int = 3
  PeersPanelWidth: int = 20
  TopHeight: int = 25

type InputPanel = ref object of nw.Node

method render(node: InputPanel, ctx: var nw.Context[State]) =
  ctx = nw.slice(ctx, 0, 0, iw.width(ctx.tb), InputPanelHeight)
  render(
    nw.Box(
      border: nw.Border.Single,
      direction: nw.Direction.Vertical,
      children: nw.seq("> " & ctx.data.inputBuffer),
    ),
    ctx,
  )

proc runUI*(
    gossip: GossipSub,
    room: string,
    recvQ: AsyncQueue[string],
    peerQ: AsyncQueue[PeerId],
    systemQ: AsyncQueue[string],
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
  terminal.hideCursor()
  try:
    iw.init()
  except:
    echo "iw.init error"
    return

  ctx.data.inputBuffer = ""
  ctx.tb = iw.initTerminalBuffer(terminal.terminalWidth(), terminal.terminalHeight())

  # TODO: publish my peerid in peerid topic
  let
    chatPanel = ScrollingTextBox.new(
      title = "Chat", width = iw.width(ctx.tb) - PeersPanelWidth, height = TopHeight
    )
    peersPanel = ScrollingTextBox.new(
      title = "Peers",
      width = PeersPanelWidth,
      height = TopHeight,
      text = @[shortPeerId(myPeerId) & " (You)"],
    )
    systemPanel = ScrollingTextBox.new(
      title = "System",
      width = iw.width(ctx.tb),
      height = iw.height(ctx.tb) - TopHeight - InputPanelHeight,
    )
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
      discard await gossip.publish(room, cast[seq[byte]](@(ctx.data.inputBuffer)))
      chatPanel.text.add("You: " & ctx.data.inputBuffer) # show message in ui
      ctx.data.inputBuffer = "" # clear input buffer
    elif key != iw.Key.None:
      discard

    # update peer list if there's a new peer from peerQ
    if not peerQ.empty():
      # TODO: handle peer removals
      let newPeer = await peerQ.get()
      if not peersPanel.text.contains(shortPeerId(newPeer)):
        peersPanel.text.add(shortPeerId(newPeer))

    # update messages if there's a new message from recvQ
    if not recvQ.empty():
      let msg = await recvQ.get()
      chatPanel.text.add(msg) # show message in ui

    # update messages if there's a new message from recvQ
    if not systemQ.empty():
      let msg = await systemQ.get()
      systemPanel.text.add(msg) # show message in ui

    renderRoot(
      nw.Box(
        direction: nw.Direction.Vertical,
        children: nw.seq(
          nw.Box(
            direction: nw.Direction.Horizontal, children: nw.seq(chatPanel, peersPanel)
          ),
          systemPanel,
          InputPanel(),
        ),
      ),
      ctx,
    )

    # render
    iw.display(ctx.tb, prevTb)
    prevTb = ctx.tb
    ctx.tb = iw.initTerminalBuffer(terminal.terminalWidth(), terminal.terminalHeight())

    await sleepAsync(5.milliseconds)
    # iw.clear(ctx.tb)
