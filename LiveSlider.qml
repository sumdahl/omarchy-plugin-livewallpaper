import QtQuick
import qs.Commons
import qs.Ui

// A PanelSlider with a label and a readout.
//
// Two things it exists to get right. It commits on release, not on move — a
// drag is one write to disk and one shell reload, not sixty. And it stops
// following the external value while the knob is held, so a reload landing
// mid-drag cannot yank the knob out from under the pointer.
Item {
  id: root

  property QtObject bar: null
  property string label: ""
  property string suffix: ""
  property real value: 0
  property real minimum: 0
  property real maximum: 1
  property real step: 0.05
  property bool integer: false
  property int decimals: 2

  signal commit(real value)

  implicitHeight: labelText.implicitHeight + slider.implicitHeight + Style.space(4)

  property bool holding: false
  property real shown: value

  onValueChanged: if (!holding) shown = value

  function format(v) {
    return (integer ? Math.round(v).toString() : Number(v).toFixed(decimals)) + suffix
  }

  Text {
    id: labelText
    anchors.left: parent.left
    anchors.top: parent.top
    text: root.label
    color: Color.popups.text
    font.pixelSize: Style.font.body
  }

  Text {
    id: valueText
    anchors.right: parent.right
    anchors.top: parent.top
    text: root.format(root.shown)
    color: Color.popups.text
    opacity: 0.7
    font.pixelSize: Style.font.body
  }

  PanelSlider {
    id: slider
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    bar: root.bar
    minimum: root.minimum
    maximum: root.maximum
    step: root.step
    integer: root.integer
    value: root.shown

    onMoved: function (v) {
      root.holding = true
      root.shown = v
    }

    onReleased: function (v) {
      root.holding = false
      root.shown = v
      root.commit(root.integer ? Math.round(v) : Number(v.toFixed(root.decimals)))
    }
  }
}
