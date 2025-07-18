from illwave as iw import nil, `[]`, `[]=`, `==`
from nimwave as nw import nil
from terminal import nil
import unicode, tables, deques
from strutils import nil
from sequtils import nil
from os import nil

type
  State* = object
    focusIndex*: int
    focusAreas*: ref seq[iw.TerminalBuffer]
    peers*: seq[string]
    chats*: seq[string]
    messages*: seq[string]
    inputBuffer*: string

include nimwave/prelude

var
  mouseQueue: Deque[iw.MouseInfo]
  keyQueue: Deque[iw.Key]

proc onMouse*(m: iw.MouseInfo) =
  mouseQueue.addLast(m)
  case m.scrollDir:
  of iw.ScrollDirection.sdUp: keyQueue.addLast(iw.Key.Up)
  of iw.ScrollDirection.sdDown: keyQueue.addLast(iw.Key.Down)
  else: discard

proc onKey*(k: iw.Key) =
  keyQueue.addLast(k)

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
# Tick
# ------------------------

proc tick*(ctx: var nw.Context[State]) =
  while true:
    let
      mouse = if mouseQueue.len > 0: mouseQueue.popFirst else: iw.MouseInfo()
      key = if keyQueue.len > 0: keyQueue.popFirst else: iw.Key.None

    # Handle mouse click for focus
    if mouse.button == iw.MouseButton.mbLeft and mouse.action == iw.MouseButtonAction.mbaPressed:
      for i in countDown(ctx.data.focusAreas[].len-1, 0):
        if iw.contains(ctx.data.focusAreas[i], mouse):
          ctx.data.focusIndex = i
          break

    # Focus change with up/down
    var focusChange = case key
      of iw.Key.Up: -1
      of iw.Key.Down: 1
      else: 0

    if focusChange != 0 and ctx.data.focusAreas[].len > 0:
      if ctx.data.focusIndex + focusChange in 0 ..< ctx.data.focusAreas[].len:
        ctx.data.focusIndex += focusChange

    # Input editing
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

    renderRoot(
      nw.Box(
        direction: nw.Direction.Vertical,
        children: nw.seq(
          nw.Box(
            direction: nw.Direction.Horizontal,
            children: nw.seq(PeersPanel(), ChatsPanel())
          ),
          MessagesPanel()
        )
      ),
      ctx
    )

    if mouseQueue.len == 0 and keyQueue.len == 0:
      break

    iw.clear(ctx.tb)

# ------------------------
# Init / main loop
# ------------------------

proc deinit() =
  iw.deinit()
  terminal.showCursor()

proc init(ctx: var nw.Context[State]) =
  terminal.enableTrueColors()
  iw.init()
  setControlCHook(
    proc () {.noconv.} =
      deinit()
      quit(0)
  )
  terminal.hideCursor()
  ctx = nw.initContext[State]()
  new ctx.data.focusAreas
  ctx.data.peers = @["peer1", "peer2"]
  ctx.data.chats = @["chat1", "chat2"]
  ctx.data.messages = @["Welcome to nim universal-connectivity-app!"]
  ctx.data.inputBuffer = " type here"

proc tick(ctx: var nw.Context[State], prevTb: var iw.TerminalBuffer, mouseInfo: var iw.MouseInfo) =
  let key = iw.getKey(mouseInfo)
  if key == iw.Key.Mouse:
    onMouse(mouseInfo)
  elif key != iw.Key.None:
    onKey(key)
  ctx.tb = iw.initTerminalBuffer(terminal.terminalWidth(), terminal.terminalHeight())
  tick(ctx)
  iw.display(ctx.tb, prevTb)

proc main() =
  var
    ctx: nw.Context[State]
    prevTb: iw.TerminalBuffer
    mouseInfo: iw.MouseInfo
  init(ctx)
  while true:
    try:
      tick(ctx, prevTb, mouseInfo)
      prevTb = ctx.tb
    except Exception as ex:
      deinit()
      raise ex
    os.sleep(5)

when isMainModule:
  main()

