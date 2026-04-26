/* NeXiS Hypervisor — Calamares Installation Slideshow */
import QtQuick 2.0
import calamares.slideshow 1.0

Presentation {
    id: presentation

    function onActivate() { }
    function onLeave()    { }

    Slide {
        anchors.fill: parent

        Rectangle {
            anchors.fill: parent
            color: "#080807"
        }

        Column {
            anchors.centerIn: parent
            spacing: 24

            Image {
                source: "logo.png"
                width:  96
                height: 96
                anchors.horizontalCenter: parent.horizontalCenter
            }

            Text {
                text:           "Installing NeXiS Hypervisor"
                color:          "#F87200"
                font.family:    "JetBrains Mono"
                font.pointSize: 16
                font.bold:      true
                letterSpacing:  3
                anchors.horizontalCenter: parent.horizontalCenter
            }

            Text {
                text:           "Neural Execution and Cross-device Inference System"
                color:          "#887766"
                font.family:    "JetBrains Mono"
                font.pointSize: 9
                anchors.horizontalCenter: parent.horizontalCenter
            }

            Rectangle {
                width:  320
                height: 1
                color:  "#2A2A1A"
                anchors.horizontalCenter: parent.horizontalCenter
            }

            Column {
                spacing: 10
                anchors.horizontalCenter: parent.horizontalCenter

                Repeater {
                    model: [
                        "QEMU/KVM virtualisation layer",
                        "LXC container runtime",
                        "Web management interface  ·  HTTPS :8443",
                        "NeXiS Controller SSO integration",
                        "Proxmox-style cluster support",
                    ]
                    Text {
                        text:           "·  " + modelData
                        color:          "#887766"
                        font.family:    "JetBrains Mono"
                        font.pointSize: 9
                        anchors.horizontalCenter: parent.horizontalCenter
                    }
                }
            }
        }
    }
}
