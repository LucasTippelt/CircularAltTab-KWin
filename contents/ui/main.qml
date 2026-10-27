import QtQuick
import org.kde.kirigami as Kirigami
import org.kde.kwin as KWin

KWin.TabBoxSwitcher {
  id: tabBox

  // index of the window focused when the switcher opened; restored on release over the center hole / outside in keep-focused mode so we don't switch to a merely-hovered one (KWin ignores currentIndex=-1 and falls back to its last valid selection)
  property int preSwitchIndex: -1

  // re-entrancy guard: while we write currentIndex, suppress KWin echoing it back into pie.current
  // (that echo re-fires onCurrentChanged and thrashed the selection between adjacent pieces)
  property bool _writingCurrentIndex: false

  // anchor center for cursor mode (centerOnScreen=false), captured at open so a resize while open
  // (e.g. closing a window drops a ring) re-anchors to the same spot instead of chasing the live cursor
  property var openAnchor: null

  Window {
    id: wnd
    width: pie.implicitWidth
    height: pie.implicitHeight
    visible: false // managed manually for smooth fade
    flags: Qt.BypassWindowManagerHint | Qt.FramelessWindowHint
    color: "transparent"

    Pie {
      id: pie
      model: tabBox.model
      bg.color: Qt.rgba(Kirigami.Theme.backgroundColor.r,
                        Kirigami.Theme.backgroundColor.g,
                        Kirigami.Theme.backgroundColor.b,
                        pie.bgAlpha)
      opacity: 0.0

      Behavior on opacity {
        NumberAnimation {
          duration: Kirigami.Units.longDuration
          easing.type: Easing.InOutQuad
          // unmap only once fully transparent
          onFinished: if ( pie.opacity===0.0 ) { wnd.visible =false; }
        }
      }

      // closing a window while open can drop a ring (9->8) and resize the pie; re-derive size+position, but DEFERRED:
      // positionPie() writes screenFit, which must not happen inside this binding's own delivery chain - QML's binding-loop
      // detection would abort the update in progress. The timer coalesces bursts into one pass; x/y were set once at show time,
      // so without the re-derive the top-left stays put and the center drifts off-anchor.
      onImplicitWidthChanged: if ( tabBox.visible ) { requestReposition(); }

      onClicked: {
        // ignore clicks on the center hole / gaps (no piece under cursor)
        // model.activate() is undocumented KWin API - no stability guarantee.
        // For click activation only; keyboard flow uses currentIndex + Alt-release.
        if ( tabBox.model && pie.current>=0 ) { tabBox.model.activate(pie.current); }
      }

      onCloseRequested: (idx)=>{
        // model.close() is undocumented KWin API - no stability guarantee.
        // No documented alternative exists for closing windows from a TabBox switcher.
        if ( tabBox.model && idx>=0 ) { tabBox.model.close(idx); }
      }

      onCurrentChanged: {
        if ( current<0 ) {
          const keep =pie.releaseOutside==="keepFocused";
          if ( keep && tabBox.preSwitchIndex>=0 && (pie.hoverCenter || pie.mouseOutsidePie) ) {
            // pin activation to the originally-focused window so release keeps it
            if ( tabBox.currentIndex!==tabBox.preSwitchIndex ) {
              tabBox._writingCurrentIndex =true;
              tabBox.currentIndex =tabBox.preSwitchIndex;
              tabBox._writingCurrentIndex =false;
            }
          } else { current =tabBox.currentIndex; }   // hold keyboard/wheel/last-hovered selection (upstream behavior)
        } else if ( tabBox.currentIndex!==current ) {
          tabBox._writingCurrentIndex =true;
          tabBox.currentIndex =current;
          tabBox._writingCurrentIndex =false;
        }
      }

      Item {
        id: centerItem
        anchors.centerIn: parent
        width: pie.inRadius*2
        height: pie.inRadius*2
        z: 10

        readonly property double targetAngle: pie.currentAngle
        readonly property bool hasTarget: !isNaN(targetAngle)
        // hold last angle when cursor leaves (no snap-to-top flicker)
        property double lastAngle: 0
        onTargetAngleChanged: if ( hasTarget ) { lastAngle =targetAngle; }

        Canvas {
          id: needle
          anchors.fill: parent
          visible: centerItem.hasTarget
          rotation: centerItem.lastAngle
          onPaint: {
            let ctx =getContext("2d");
            ctx.reset();
            const cx =width/2.0;
            const tip =8.0;
            const baseY =height*0.30;
            const bw =width*0.08;
            ctx.beginPath();
            ctx.moveTo(cx, tip);
            ctx.lineTo(cx-bw, baseY);
            ctx.lineTo(cx+bw, baseY);
            ctx.closePath();
            ctx.fillStyle =Kirigami.Theme.highlightColor;
            ctx.fill();
          }
          Behavior on rotation {
            RotationAnimation {
              duration: Kirigami.Units.longDuration
              direction: RotationAnimation.Shortest
            }
          }
          onVisibleChanged: requestPaint()
          Component.onCompleted: requestPaint()
        }

        Rectangle {
          id: captionBg
          anchors.centerIn: captionLabel
          width: Math.min(captionLabel.implicitWidth, captionLabel.width) + Kirigami.Units.largeSpacing * 2
          height: captionLabel.implicitHeight + Kirigami.Units.smallSpacing
          radius: Kirigami.Units.cornerRadius
          color: Qt.rgba(Kirigami.Theme.backgroundColor.r,
                         Kirigami.Theme.backgroundColor.g,
                         Kirigami.Theme.backgroundColor.b,
                         0.75)
          visible: captionLabel.text !== ""
        }

        Text {
          id: captionLabel
          anchors.horizontalCenter: parent.horizontalCenter
          anchors.top: parent.top
          // below needle tip when pointing down (tip at ~inRadius*1.92)
          anchors.topMargin: pie.inRadius*1.85
          // wider than center hole so long titles aren't clipped early
          width: pie.inRadius*6
          horizontalAlignment: Text.AlignHCenter
          wrapMode: Text.Wrap
          maximumLineCount: 3
          elide: Text.ElideRight
          font.family: Kirigami.Theme.defaultFont.family
          font.pointSize: Math.round(Kirigami.Theme.defaultFont.pointSize*pie.captionFontScale)
          color: Kirigami.Theme.textColor
          text: pie.currentCaption
        }
      }
    }
  }

  // (re)compute the screen-fit clamp + wnd position from current geometry: fit-to-screen first, then center on the anchor
  // point (screen center for centerOnScreen, open-time cursor otherwise), then clamp to the active screen.
  // All sizing is ARITHMETIC via pie.extentAtFit(f): geometry is linear in screenFit, so extentAtFit(1.0) gives the exact
  // unclamped width and hence the clamp factor; the final size/position derive from the just-written fit. positionPie() never
  // reads implicitWidth/Height - they can be mid-update when this runs during a resize while open. Recomputing everything
  // from current geometry on every call keeps it idempotent across the show and resize-while-open paths; the latter calls
  // here deferred (requestReposition/repositionTimer) so the screenFit write never happens inside an implicitWidth binding's
  // delivery chain, which QML's binding-loop detection would abort.
  function positionPie() {
    let g =tabBox.screenGeometry;
    const validScreen =g && g.width>0 && g.height>0;
    if ( validScreen ) {
      // natural (unclamped) width at f=1: geometry is linear in screenFit, so this gives the exact clamp factor.
      // same expression as Pie.qml's implicitWidth (radialExtent*2 + 0.14*(radialExtent+inRadius))
      const e1 =pie.extentAtFit(1.0);
      const w1 =e1*2+0.14*(e1+pie.baseInRadius*pie.scale);
      // shrink further if the natural size (many windows -> many rings in "thickness" mode) would overflow the screen;
      // ring sizes themselves no longer depend on window count
      const margin =0.95;
      const fit =Math.min(1.0, g.width*margin/w1, g.height*margin/w1);
      if ( Math.abs(fit-pie.screenFit)>1e-9 ) { pie.screenFit =fit; }   // write only on change - avoids churn and spurious resize events
    }
    // true size after the write above - arithmetic from the just-written value, so this stays correct even if the binding
    // cascade settles one frame late (inRadius at the new fit = baseInRadius*scale*screenFit)
    const e =pie.extentAtFit(pie.screenFit);
    const w =e*2+0.14*(e+pie.baseInRadius*pie.scale*pie.screenFit);
    // center on screen or cursor, then clamp to the screen so the pie never opens off-screen
    let ax, ay;
    if ( pie.centerOnScreen && validScreen ) {
      ax =g.x+g.width/2;
      ay =g.y+g.height/2;
    } else if ( tabBox.openAnchor ) {
      ax =tabBox.openAnchor.x;
      ay =tabBox.openAnchor.y;
    } else {
      ax =KWin.Workspace.cursorPos.x;
      ay =KWin.Workspace.cursorPos.y;
    }
    wnd.x =ax-w/2;
    wnd.y =ay-w/2;
    if ( validScreen ) {
      wnd.x =Math.max(g.x, Math.min(wnd.x, g.x+g.width-w));
      wnd.y =Math.max(g.y, Math.min(wnd.y, g.y+g.height-w));
    }
  }

  // deferred, coalesced repositioning while open - see positionPie() for why this must not run inside onImplicitWidthChanged
  Timer { id: repositionTimer; interval: 0; onTriggered: tabBox.positionPie(); }
  function requestReposition() { if ( !repositionTimer.running ) { repositionTimer.start(); } }

  onVisibleChanged: {
    if ( visible ) {
      // invalidate the previous session's capture until showSelectTimer identifies the currently-focused window by
      // identity (KWin.Workspace.activeWindow). Reading currentIndex here is unreliable - it carries leftover state
      // from before open and gets polluted by hover-follow within the settle window.
      preSwitchIndex =-1;
      // reset current BEFORE updateData so bindings re-evaluate after delegates are created
      pie.current =-1;
      tabBox.openAnchor =Qt.point(KWin.Workspace.cursorPos.x, KWin.Workspace.cursorPos.y);
      pie.updateData();
      positionPie();   // synchronous here is safe: show-time sizing never runs inside a binding delivery chain; any resize it triggers re-enters only via the deferred requestReposition()
      wnd.visible =true;
      pie.opacity =1.0;
      // restore current after Repeater created delegates, otherwise itemAt(current)==null
      showSelectTimer.restart();
    } else {
      // last-moment backstop: releasing over a pinning zone (center hole, or outside in keep-focused mode) must keep the original window
      if ( pie.releaseOutside==="keepFocused" && tabBox.preSwitchIndex>=0
           && (pie.hoverCenter || pie.mouseOutsidePie) ) {
        tabBox._writingCurrentIndex =true;
        tabBox.currentIndex =tabBox.preSwitchIndex;
        tabBox._writingCurrentIndex =false;
      }
      pie.opacity =0.0;
    }
  }

  Timer {
    id: showSelectTimer
    interval: 50
    onTriggered: {
      var aw =KWin.Workspace.activeWindow;
      var activeIdx =pie.findActiveIndex();
      preSwitchIndex =(activeIdx>=0) ? activeIdx : tabBox.currentIndex;
      if ( preSwitchIndex>=0 ) { pie.current =preSwitchIndex; }
    }
  }

  // While the cursor sits in a pinning zone (center hole, or outside the pie in keep-focused mode), keep re-asserting that the
  // originally-focused window stays selected. A one-shot pin can lose to KWin's own release-time selection - most reliably on the
  // first open after a restart - so refresh it ~40x/s until we leave the zone or close. This only touches currentIndex (never
  // activates), so it cannot move focus or switch screens like model.activate() did.
  Timer {
    id: deadZonePinTimer
    interval: 25
    repeat: true
    running: tabBox.visible && tabBox.preSwitchIndex>=0
        && pie.releaseOutside==="keepFocused" && (pie.hoverCenter || pie.mouseOutsidePie)
    onTriggered: {
      if ( !(pie.hoverCenter || pie.mouseOutsidePie) ) { return; }   // left the pinning zone since last evaluation - don't yank selection back
      if ( tabBox.currentIndex!==tabBox.preSwitchIndex ) {
        tabBox._writingCurrentIndex =true;
        tabBox.currentIndex =tabBox.preSwitchIndex;
        tabBox._writingCurrentIndex =false;
      }
    }
  }

  onCurrentIndexChanged: {
    if ( tabBox._writingCurrentIndex ) { return; }   // our own write's echo - break the feedback loop
    const pin =pie.releaseOutside==="keepFocused" && tabBox.preSwitchIndex>=0 && (pie.hoverCenter || pie.mouseOutsidePie);
    if ( pin && tabBox.currentIndex!==tabBox.preSwitchIndex ) {
      tabBox._writingCurrentIndex =true;
      tabBox.currentIndex =tabBox.preSwitchIndex;
      tabBox._writingCurrentIndex =false;
    } else {
      pie.current =tabBox.currentIndex;
    }
  }
}
