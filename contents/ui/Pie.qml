import QtQuick
import org.kde.kirigami as Kirigami
import org.kde.kwin as KWin

Rectangle {
  id: pie
  color: "transparent"

  property alias model: pieces.model
  property int current: -1
  // true while the cursor is in the empty center hole; with releaseOutside "keepFocused" this pins activation to the originally-focused window on Alt-release
  property bool hoverCenter: false
  // true while the cursor is outside the whole pie disc (beyond the outer ring); what releasing Alt does there depends on releaseOutside
  property bool mouseOutsidePie: false
  // when true, being in a no-selection zone (center hole or outside the pie disc) also clears the visual selection so nothing
  // highlights there; derived from releaseOutside, which pins activation to the originally-focused window while "keepFocused" -
  // no other piece should light up there. Under "activateLast" these zones keep the held selection highlighted (like hovering a piece).
  readonly property bool clearSelectionOutside: releaseOutside==="keepFocused"
  // index shown as selected in the pieces; -1 only over a no-selection zone when clearing is enabled, so nothing highlights there
  readonly property int activePieceIndex: ((hoverCenter || mouseOutsidePie) && clearSelectionOutside) ? -1 : current
  property var ringPieces: []

  // user-tunable visual preferences
  property double selectedScale: 1.06
  property double nonSelectedOpacity: 0.6
  property double minimizedOpacity: 0.7
  property double bgAlpha: 0.72
  property double captionFontScale: 1.5
  property bool centerOnScreen: true
  // "thickness" mode: uniform ring thickness multiplier; "size" mode: outer-ring boost factor
  property double outerRingScale: 1.4
  // overall scale of the whole pie (rings + center hole)
  property double scale: 1.0   // overall scale of the whole pie (rings + center hole). Recommended Valuerange: 0.5-2.0
  property string sizeMode: "thickness"   // "thickness" | "size"; See README/CHANGELOG 
  property string releaseOutside: "activateLast"   // "activateLast" | "keepFocused"; what releasing Alt outside the pie does; See README/CHANGELOG 

  // max slices per ring before spilling to the next ring (≈ 360/maxPerRing° min arc)
  readonly property int maxPerRing: 8

  // base sizes (DPI-aware); scale/screenFit scale them uniformly, never by window count
  readonly property double baseRingHeight: Kirigami.Units.gridUnit*12
  readonly property double baseInRadius: Kirigami.Units.gridUnit*2
  readonly property double baseRingSpacing: Kirigami.Units.gridUnit*0.5
  // extra shrink so the circle fits the active screen; set by main.qml before showing
  property double screenFit: 1.0

  readonly property int ringsCount: _private.ringPieces.length

  // uniform single-ring thickness (today's outer-ring look)
  readonly property double unitThickness: baseRingHeight*outerRingScale*scale*screenFit
  // "size" mode target: exactly today's single-ring footprint, so R=1 looks identical in both modes
  readonly property double targetE: (baseInRadius+baseRingHeight*outerRingScale)*scale*screenFit

  readonly property double inRadius: baseInRadius*scale*screenFit
  readonly property double ringSpacing: baseRingSpacing*scale*screenFit
  // inner/base ring thickness: uniform in "thickness" mode; solved so the pie fits targetE in "size" mode,
  // floored for pathological ring counts so Canvas math never sees a <=0 thickness
  readonly property double ringHeight: (sizeMode!=="size" || ringsCount<=0) ? unitThickness : Math.max((targetE-inRadius-(ringsCount-1)*ringSpacing)/((ringsCount-1)+outerRingScale), unitThickness*0.1)

  function ringHeightFor(ring) {
    if ( sizeMode==="size" && ringsCount>0 && ring===ringsCount-1 ) { return ringHeight*outerRingScale; }
    return ringHeight;
  }

  // total radius from center to outer edge (= targetE in "size" mode unless the floor clamp kicks in).
  // Pure function of (f, ringsCount, sizeMode, scale): main.qml computes screen-fit clamping and window positioning
  // arithmetically via extentAtFit() instead of reading implicitWidth/Height - those bindings can be mid-update when
  // positionPie() runs during a resize while open, so the sizing math must not depend on their current value.
  function extentAtFit(f) {
    const iR =baseInRadius*scale*f;
    if ( ringsCount<=0 ) { return iR; }
    const sP =baseRingSpacing*scale*f;
    const uT =baseRingHeight*outerRingScale*scale*f;
    if ( sizeMode==="size" ) {
      const tE =(baseInRadius+baseRingHeight*outerRingScale)*scale*f;
      const h  =Math.max((tE-iR-(ringsCount-1)*sP)/((ringsCount-1)+outerRingScale), uT*0.1);
      return iR+((ringsCount-1)+outerRingScale)*h+(ringsCount-1)*sP;
    }
    return iR+ringsCount*uT+(ringsCount-1)*sP;
  }

  readonly property double radialExtent: extentAtFit(screenFit)

  property alias bg: bg

  // angle and caption of the selected piece - drives the center pointer/label
  readonly property double currentAngle: (current>=0 && current<pieces.count && pieces.itemAt(current))
      ? pieces.itemAt(current).rotation : NaN
  readonly property string currentCaption: (current>=0 && current<pieces.count && pieces.itemAt(current))
      ? pieces.itemAt(current).caption : ""

  signal clicked(var mouse);
  signal closeRequested(int idx);

  // base size + padding for 1.06x scale (wider piece = chord1 + 2*offset); only R-1 gaps between R rings
  implicitHeight: radialExtent*2+0.14*(radialExtent+inRadius)
  implicitWidth: implicitHeight

  QtObject {
    id: _private
    property var pieceToRing: []
    property var ringPieces: []
    property var idxsInRing: []

    function updateData() {
      let pr =[0], rp =[0], ir =[0];
      for (let i=0, summ =0, j =0, ring =0; i<pieces.count; ++i, ++j) {
        if ( ring<pie.ringPieces.length && i>=summ+pie.ringPieces[ring] ) { summ +=pie.ringPieces[ring]; ring++; rp[ring] =0; j =0; }
        pr[i] =ring;
        ir[i] =j;
        rp[ring]++;
      }
      _private.pieceToRing =pr;
      _private.ringPieces =rp;
      _private.idxsInRing =ir;
    }
  }

  onRingPiecesChanged: {
    _private.updateData();
  }

  // Hit-test uses STABLE uniform layout (home sectors), not animated geometry.
  // Otherwise hovering "jumps": the hovered piece scales and moves from under
  // the cursor, landing on a neighbor and thrashing the selection.
  function getPieIdx(x, y) {
    const tx =x-width/2;
    const ty =y-height/2;
    const d =tx*tx+ty*ty;
    let mouseAngle =(Math.atan2(tx, -ty)*180.0/Math.PI+360)%360;
    for (let i=0; i<pieces.count; ++i) {
      const ring =_private.pieceToRing[i];
      const n =_private.ringPieces[ring];
      const j =_private.idxsInRing[i];
      const rIn =inRadius+(ringHeight+ringSpacing)*ring;
      const rOut =rIn+ringHeightFor(ring);
      if ( d<rIn*rIn || d>rOut*rOut ) { continue; }
      const central =Math.min(180.0, 360.0/n);
      const startAngle =j*central-central/2.0;
      const endAngle =j*central+central/2.0;
      if ( startAngle<0 || endAngle>360 ) {
        if ( (mouseAngle>=(startAngle+360)%360 || mouseAngle<(endAngle%360)) ) { return i; }
      } else {
        if ( mouseAngle>=startAngle && mouseAngle<endAngle ) { return i; }
      }
    }
    return -1;
  }

  // the empty center hole as a zone, widened by one grid unit so it's generous to hover
  // (the geometric hole alone is only ~16px radius at scale 1 - far too small a target)
  function inCenterHole(x, y) {
    const tx =x-width/2;
    const ty =y-height/2;
    const r =inRadius + Kirigami.Units.gridUnit;
    return (tx*tx+ty*ty) <= r*r;
  }

  function updateData() {
    let rp = computeRingPieces();
    if ( JSON.stringify(rp) !== JSON.stringify(pie.ringPieces) ) {
      pie.ringPieces = rp;
    } else {
      _private.updateData();
    }
  }

  // returns a per-ring capacity array summing EXACTLY to pieces.count
  function computeRingPieces() {
    let n = pieces.count;
    if ( n <= 0 ) { return []; }
    let rings = Math.ceil(n / maxPerRing);
    let base  = Math.floor(n / rings);
    let rem   = n % rings;
    let arr = [];
    for ( let r = 0; r < rings; r++ ) {
      arr.push(base + (r >= rings - rem ? 1 : 0));
    }
    return arr;
  }

  // cycle selection by step (+1 / -1), wrapping; shared by wheel + arrow keys
  function cycle(step) {
    if ( pieces.count<=0 ) { return; }
    if ( pie.current<0 ) { pie.current =(step>0)? 0 : pieces.count-1; }
    else { pie.current =(pie.current+step+pieces.count)%pieces.count; }
  }

  // model index of the currently-focused window, matched BY IDENTITY against KWin.Workspace.activeWindow. Used to
  // capture "the original window" on open without trusting currentIndex (which carries leftover/polluted state).
  function findActiveIndex() {
    var aw =KWin.Workspace.activeWindow;
    if (!aw) { return -1; }
    var target =String(aw.internalId);
    for (var i=0;i<pieces.count;i++) {
      var it =pieces.itemAt(i);
      if (it && String(it.windowId)===target) { return i; }
    }
    return -1;
  }

  Kirigami.PlaceholderMessage {
    anchors.centerIn: parent
    width: parent.width*0.5
    // render above the opaque bg disc (a later sibling), otherwise it's hidden
    z: 100
    visible: pieces.count===0
    text: "No active windows."
  }

  MouseArea {
    id: mouseHandler
    anchors.fill: parent
    acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
    hoverEnabled: true

    Rectangle {
      id: bg
      anchors.fill: parent
      // bg covers only the pie content, not the scale padding
      anchors.margins: 0.07*(radialExtent+inRadius)
      radius: width/2
      color: "transparent"
    }

    onClicked: (mouse)=>{
      if ( mouse.button===Qt.MiddleButton ) { pie.closeRequested(pie.current); }
      else { pie.clicked(mouse); }
    }

    onWheel: (wheel)=>{
      pie.cycle(wheel.angleDelta.y>0 ? -1 : 1);
    }

    onPositionChanged: (mouse) => {
      mouse.accepted =false;
      if ( !containsMouse ) { return; }
      const idx =getPieIdx(mouse.x, mouse.y);
      const inHole =inCenterHole(mouse.x, mouse.y);
      pie.hoverCenter =idx<0 && inHole;
      // outside the whole pie disc (beyond the outer ring) is a no-selection zone too
      const tx=mouse.x-width/2, ty=mouse.y-height/2;
      pie.mouseOutsidePie =idx<0 && !inHole && (tx*tx+ty*ty)>radialExtent*radialExtent;
      // with releaseOutside "activateLast" (!clearSelectionOutside) keep the held selection while outside: onCurrentChanged's hold branch
      // (current<0 -> current=currentIndex) restores it, and clearing here would flicker the highlight between pointer events. Pinning is
      // unaffected: the close-time backstop re-pins currentIndex to preSwitchIndex regardless of pie.current.
      if ( !(idx<0 && !clearSelectionOutside) ) { pie.current =idx; }
    }

    onContainsMouseChanged: {
      if ( !containsMouse ) {
        pie.hoverCenter =false;
        pie.mouseOutsidePie =true;
        // same rule as above: with releaseOutside "activateLast" keep the held selection while outside so Alt-release activates the last hovered piece
        if ( clearSelectionOutside ) { pie.current =-1; }
      }
    }

    Repeater {
      id: pieces

      onModelChanged: {
        pie.updateData();
      }

      onCountChanged: {
        pie.updateData();
      }

      Component.onCompleted: {
        pie.updateData();
      }

      delegate: Piece {
        id: pieceDelegate

        // guard against NaN (360/undefined) which permanently latches Behavior animations
        readonly property int ringIdx: _private.pieceToRing[index] || 0
        readonly property int piecesInRing: _private.ringPieces[ringIdx] || 1
        readonly property int idxInRing: _private.idxsInRing[index] || 0
        // cap at 180°: a lone window's 360° slice is degenerate (chord→0), and the
        // chord (= preview width) is widest at 180°, so this gives the biggest preview.
        // Only bites when piecesInRing==1; for 2+ windows 360/n is already ≤180.
        readonly property double centralAngle: Math.min(180.0, 360.0/piecesInRing)

        // lookup live KWin::Window for real-time caption (ClientModel never emits dataChanged)
        readonly property var kwinWindow: {
            var windows = KWin.Workspace.windows;
            for (var i = 0; i < windows.length; i++) {
                if (String(windows[i].internalId) === String(model.windowId)) {
                    return windows[i];
                }
            }
            return null;
        }
        caption: kwinWindow ? kwinWindow.caption : model.caption
        minimized: model.minimized
        isSelected: pie.activePieceIndex === index
        // selected piece renders on top so accent ring isn't covered by neighbors
        z: isSelected ? 1 : 0
        opacity: (pie.activePieceIndex>=0 && pie.activePieceIndex!==index)? pie.nonSelectedOpacity : (model.minimized? pie.minimizedOpacity : 1.0)
        // scale from center to avoid clipping outside the window
        transformOrigin: Item.Center
        scale: (pie.activePieceIndex===index)? pie.selectedScale : 1.0
        Behavior on opacity { NumberAnimation { duration: Kirigami.Units.shortDuration; } }
        Behavior on scale { NumberAnimation { duration: Kirigami.Units.shortDuration; } }

        rIn: pie.inRadius+((pie.ringHeight+pie.ringSpacing)*ringIdx)
        rOut: rIn+pie.ringHeightFor(ringIdx)
        offset: 0.8*piecesInRing
        angle: centralAngle
        x: pie.width/2-width/2
        y: pie.height/2-height
        rotation: idxInRing*centralAngle

        windowId: model.windowId
        icon.source: model.icon

        Behavior on angle {
          NumberAnimation { duration: Kirigami.Units.shortDuration; }
        }

        Behavior on rotation {
          NumberAnimation { duration: Kirigami.Units.shortDuration; }
        }
      }
    }
  }
}
