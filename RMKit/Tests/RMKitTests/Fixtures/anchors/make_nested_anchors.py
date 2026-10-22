"""Writes nested-anchors.rm with rmscene and prints rmc's offsets for its strokes.

Run with rmscene and rmc installed: python make_nested_anchors.py
Synthetic, no user data. Adapted from a reviewer's script for Remora.

Text: "Hi" + 3 deleted chars, then "\\nYo" as a heading, box at (-400, 500).
Groups: 0:20 anchored to a deleted char (1,21), with 0:30 nested inside it
anchored to "Y" (1,31); 0:40 anchored to an id the text doesn't have.
One stroke in each group (x = y = 1, 2, 3) and a highlight in 0:20.
rmc: (10, 412), (15, 894), (7, 0); top 412, bottom 632.
"""
import io, logging
logging.disable(logging.CRITICAL)
from rmscene import scene_stream as ss, scene_items as si
from rmscene.tagged_block_common import CrdtId, LwwValue
from rmscene.crdt_sequence import CrdtSequence, CrdtSequenceItem
from rmscene import read_tree
from rmc.exporters.svg import build_anchor_pos, get_anchor

def C(a, b): return CrdtId(a, b)
T = C(0, 999)
items = [CrdtSequenceItem(C(1, 10), C(0, 0), C(0, 0), 0, "Hi"),
         CrdtSequenceItem(C(1, 20), C(1, 11), C(0, 0), 3, ""),
         CrdtSequenceItem(C(1, 30), C(1, 22), C(0, 0), 0, "\nYo")]
text = si.Text(items=CrdtSequence(items),
               styles={C(0, 0): LwwValue(T, si.ParagraphStyle.PLAIN), C(1, 30): LwwValue(T, si.ParagraphStyle.HEADING)},
               pos_x=-400.0, pos_y=500.0, width=900.0)

def group(nid, anchor=None, ox=0.0):
    g = si.Group(node_id=nid, label=LwwValue(T, "g"), visible=LwwValue(T, True))
    if anchor is not None:
        g.anchor_id = LwwValue(T, anchor); g.anchor_type = LwwValue(T, 2)
        g.anchor_threshold = LwwValue(T, 10.0); g.anchor_origin_x = LwwValue(T, ox)
    return g

def line(x):
    return si.Line(color=si.PenColor.BLACK, tool=si.Pen.BALLPOINT_1, points=[si.Point(x, x, 0, 0, 10, 100)],
                   thickness_scale=1.0, starting_length=0.0)

blocks = [ss.RootTextBlock(C(0, 0), text)]
blocks += [ss.SceneTreeBlock(n, C(0, 0), True, par)
           for n, par in [(C(0, 11), C(0, 1)), (C(0, 20), C(0, 11)), (C(0, 30), C(0, 20)), (C(0, 40), C(0, 11))]]
for g in [group(C(0, 11)), group(C(0, 20), C(1, 21), 10.0), group(C(0, 30), C(1, 31), 5.0), group(C(0, 40), C(5, 5), 7.0)]:
    blocks.append(ss.TreeNodeBlock(g))
def gi(parent, iid, child): return ss.SceneGroupItemBlock(parent, CrdtSequenceItem(iid, C(0, 0), C(0, 0), 0, child))
def li(parent, iid, x): return ss.SceneLineItemBlock(parent, CrdtSequenceItem(iid, C(0, 0), C(0, 0), 0, line(x)))
glyph = si.GlyphRange(start=None, length=2, text="Hi", color=si.PenColor.YELLOW, rectangles=[si.Rectangle(4.0, 6.0, 20.0, 30.0)])
blocks += [gi(C(0, 1), C(0, 12), C(0, 11)), gi(C(0, 11), C(0, 21), C(0, 20)), gi(C(0, 20), C(0, 31), C(0, 30)),
           gi(C(0, 11), C(0, 41), C(0, 40)),
           li(C(0, 20), C(0, 50), 1.0), li(C(0, 30), C(0, 51), 2.0), li(C(0, 40), C(0, 52), 3.0),
           ss.SceneGlyphItemBlock(C(0, 20), CrdtSequenceItem(C(0, 53), C(0, 50), C(0, 0), 0, glyph))]
buf = io.BytesIO()
ss.write_blocks(buf, blocks)
open("nested-anchors.rm", "wb").write(buf.getvalue())

tree = read_tree(io.BytesIO(buf.getvalue()))
anchors = build_anchor_pos(tree.root_text)
def walk(g, off):
    ax, ay = get_anchor(g, anchors)
    off = (off[0] + ax, off[1] + ay)
    for c in g.children.values():
        if isinstance(c, si.Group): walk(c, off)
        elif isinstance(c, si.Line): print("rmc offset for the stroke at x=%s:" % c.points[0].x, off)
walk(tree.root, (0, 0))
