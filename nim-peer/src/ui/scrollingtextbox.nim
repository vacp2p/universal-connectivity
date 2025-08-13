import unicode, tables, deques, sequtils, os
from illwave as iw import nil, `[]`, `[]=`, `==`, width, height
from nimwave as nw import nil

import ./context

type ScrollingTextBox* = ref object of nw.Node
  title*: string
  text*: seq[string]
  width*: int
  height*: int
  startingLine: int

proc new*(
    T: typedesc[ScrollingTextBox],
    title: string = "",
    width: int = 1,
    height: int = 1,
    text: seq[string] = @[],
): T =
  ScrollingTextBox(
    title: title, width: width, height: height, text: text, startingLine: 0
  )

proc formatText(node: ScrollingTextBox): seq[string] =
  result = @[]
  result.add(node.title.alignLeft(node.width))
  # empty line after title
  result.add(" ".alignLeft(node.width))
  if node.text.len == 0:
    return
  for line in node.text[
      node.startingLine .. min(node.startingLine + node.height, node.text.len - 1)
  ]:
    result.add(line.alignLeft(node.width))

proc scrollUp*(node: ScrollingTextBox, size: int) =
  node.startingLine = max(node.startingLine - size, 0)

proc scrollDown*(node: ScrollingTextBox, size: int) =
  node.startingLine = min(node.startingLine + size, node.text.len)

method render(node: ScrollingTextBox, ctx: var nw.Context[State]) =
  ctx = nw.slice(ctx, 0, 0, node.width, node.height)
  render(
    nw.Box(
      border: nw.Border.Single,
      direction: nw.Direction.Vertical,
      children: nw.seq(node.formatText()),
    ),
    ctx,
  )
