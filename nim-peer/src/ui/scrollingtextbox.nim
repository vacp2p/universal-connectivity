import unicode, tables, deques, strutils, sequtils, os
from illwave as iw import nil, `[]`, `[]=`, `==`, width, height
from nimwave as nw import nil
from terminal import nil

type ScrollingTextBox* = ref object of nw.Node
  text*: seq[string]
