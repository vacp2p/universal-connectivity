import chronos, chronicles, deques, strutils
from illwave as iw import nil, `[]`, `[]=`, `==`, width, height
from nimwave as nw import nil
from terminal import nil
import libp2p

import ./scrollingtextbox
import ./context
import ../utils

const
  InputPanelHeight: int = 3
  ScrollSpeed: int = 2

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

proc resizePanels(
    chatPanel: ScrollingTextBox,
    peersPanel: ScrollingTextBox,
    systemPanel: ScrollingTextBox,
    newWidth: int,
    newHeight: int,
) =
  let
    peersPanelWidth = (newWidth / 4).int
    topHeight = (newHeight / 2).int
  chatPanel.resize(newWidth - peersPanelWidth, topHeight)
  peersPanel.resize(peersPanelWidth, topHeight)
  systemPanel.resize(newWidth, newHeight - topHeight - InputPanelHeight)

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
    mouse: iw.MouseInfo
    key: iw.Key
  terminal.enableTrueColors()
  terminal.hideCursor()
  try:
    iw.init()
  except:
    echo "iw.init error"
    return

  ctx.tb = iw.initTerminalBuffer(terminal.terminalWidth(), terminal.terminalHeight())

  # TODO: publish my peerid in peerid topic
  let
    peersPanelWidth = (iw.width(ctx.tb) / 4).int
    topHeight = (iw.height(ctx.tb) / 2).int
    chatPanel = ScrollingTextBox.new(
      title = "Chat", width = iw.width(ctx.tb) - peersPanelWidth, height = topHeight
    )
    peersPanel = ScrollingTextBox.new(
      title = "Peers",
      width = peersPanelWidth,
      height = topHeight,
      text = @[shortPeerId(myPeerId) & " (You)"],
    )
    systemPanel = ScrollingTextBox.new(
      title = "System",
      width = iw.width(ctx.tb),
      height = iw.height(ctx.tb) - topHeight - InputPanelHeight,
    )

  # Send chronicle logs to systemPanel
  defaultChroniclesStream.output.writer = proc(
      logLevel: LogLevel, msg: LogOutputStr
  ) {.gcsafe.} =
    for line in msg.replace("\t", "    ").splitLines():
      systemPanel.push(line)

  ctx.data.inputBuffer = ""
  let focusAreas = @[chatPanel, peersPanel, systemPanel]
  var focusIndex = 0
  var focusedPanel: ScrollingTextBox

  while true:
    focusedPanel = focusAreas[focusIndex]
    focusedPanel.border = nw.Border.Double
    key = iw.getKey(mouse)
    if key == iw.Key.Mouse:
      case mouse.scrollDir
      of iw.ScrollDirection.sdUp:
        focusedPanel.scrollUp(ScrollSpeed)
      of iw.ScrollDirection.sdDown:
        focusedPanel.scrollDown(ScrollSpeed)
      else:
        discard
    elif key == iw.Key.Tab:
      # unfocus previous panel
      focusedPanel.border = nw.Border.Single
      focusIndex += 1
      if focusIndex >= focusAreas.len:
        focusIndex = 0 # wrap around
    elif key in {iw.Key.Space .. iw.Key.Tilde}:
      ctx.data.inputBuffer.add(cast[char](key.ord))
    elif key == iw.Key.Backspace and ctx.data.inputBuffer.len > 0:
      ctx.data.inputBuffer.setLen(ctx.data.inputBuffer.len - 1)
    elif key == iw.Key.Enter:
      # TODO: handle /file command to send/publish files
      # /file filename (registers ID in local database, sends fileId, handles incoming file requests)
      #if ctx.data.inputBuffer.startsWith("/file "):
      # split buffer in spaces
      # read file that is splitted[1]
      # give file an Id
      # publish Id
      # wait for connections
      discard await gossip.publish(room, cast[seq[byte]](@(ctx.data.inputBuffer)))
      chatPanel.push("You: " & ctx.data.inputBuffer) # show message in ui
      systemPanel.push("Sent chat message")
      ctx.data.inputBuffer = "" # clear input buffer
    elif key != iw.Key.None:
      discard

    # update peer list if there's a new peer from peerQ
    if not peerQ.empty():
      # TODO: handle peer removals
      let newPeer = await peerQ.get()
      if not peersPanel.text.contains(shortPeerId(newPeer)):
        peersPanel.push(shortPeerId(newPeer))

    # update messages if there's a new message from recvQ
    if not recvQ.empty():
      let msg = await recvQ.get()
      chatPanel.push(msg) # show message in ui

    # update messages if there's a new message from recvQ
    if not systemQ.empty():
      let msg = await systemQ.get()
      if msg.len > 0:
        systemPanel.push(msg) # show message in ui

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
    if iw.width(prevTb) != iw.width(ctx.tb) or iw.height(prevTb) != iw.height(ctx.tb):
      resizePanels(
        chatPanel, peersPanel, systemPanel, iw.width(ctx.tb), iw.height(ctx.tb)
      )

    await sleepAsync(5.milliseconds)
