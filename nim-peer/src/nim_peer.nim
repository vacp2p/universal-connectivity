import illwill, illwillWidgets, os

proc exitProc() {.noconv.} =
  illwillDeinit()
  showCursor()
  quit(0)

proc makeBoxes(w, h: int): seq[TextBox] =
  let halfH = h div 2
  let boxAW = (w * 80) div 100
  let boxBW = w - boxAW
  @[
    newTextBox("upperLeft", 0, 0, boxAW),
    newTextBox("upperRight", 0, boxAW + 1, boxBW),
    newTextBox("bottom", halfH + 1, 0, w),
  ]

proc main() =
  illwillInit(fullscreen = true, mouse = true)
  setControlCHook(exitProc)
  hideCursor()

  var w = terminalWidth()
  var h = terminalHeight()
  var tb = newTerminalBuffer(w, h)
  var boxes = makeBoxes(w, h)

  while true:
    # resize
    if tb.width != terminalWidth() or tb.height != terminalHeight():
      w = terminalWidth()
      h = terminalHeight()
      tb = newTerminalBuffer(w, h)
      boxes = makeBoxes(w, h)

    for box in boxes:
      tb.render(box)

    tb.display()
    sleep(10)

main()
