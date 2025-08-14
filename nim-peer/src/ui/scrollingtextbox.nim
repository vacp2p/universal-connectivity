import unicode
from nimwave as nw import nil

import ./context

type ScrollingTextBox* = ref object of nw.Node
  title*: string
  text*: seq[string]
  width*: int
  height*: int
  startingLine: int
  border*: nw.Border

proc new*(
    T: typedesc[ScrollingTextBox],
    title: string = "",
    width: int = 3,
    height: int = 3,
    text: seq[string] = @[],
): T =
  var height = height
  if height < 3:
    height = 3
  var width = width
  if width < 3:
    width = 3
  # height and width - 2 to account for size of box lines (top and botton)
  ScrollingTextBox(
    title: title,
    width: width - 2,
    height: height - 2,
    text: text,
    startingLine: 0,
    border: nw.Border.Single,
  )

proc formatText(node: ScrollingTextBox): seq[string] =
  result = @[]
  result.add(node.title.alignLeft(node.width))
  # empty line after title
  result.add(" ".alignLeft(node.width))
  for i in node.startingLine ..< node.startingLine + node.height - 2:
    if i < node.text.len:
      result.add(node.text[i].alignLeft(node.width))
    else:
      result.add(" ".alignLeft(node.width))

proc scrollUp*(node: ScrollingTextBox, speed: int) =
  node.startingLine = max(node.startingLine - speed, 0)

proc scrollDown*(node: ScrollingTextBox, speed: int) =
  let lastStartingLine = max(0, node.text.len - node.height + 2)
  node.startingLine = min(node.startingLine + speed, lastStartingLine)

proc tail(node: ScrollingTextBox) =
  ## focuses window in lowest frame
  node.startingLine = max(0, node.text.len - node.height + 2)

proc chunkString(s: string, chunkSize: int): seq[string] =
  result = @[]
  var i = 0
  while i < s.len:
    let endIdx = min(i + chunkSize - 1, s.len - 1)
    result.add(s[i .. endIdx])
    i += chunkSize

proc push*(node: ScrollingTextBox, newLine: string) =
  for chunk in chunkString(newLine, node.width):
    node.text.add(chunk)
  node.tail()

method render(node: ScrollingTextBox, ctx: var nw.Context[State]) =
  ctx = nw.slice(ctx, 0, 0, node.width + 2, node.height + 2)
  render(
    nw.Box(
      border: node.border,
      direction: nw.Direction.Vertical,
      children: nw.seq(node.formatText()),
    ),
    ctx,
  )
