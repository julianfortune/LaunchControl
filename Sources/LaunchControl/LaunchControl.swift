import Foundation
import CoreMIDI

// Source: http://mattg411.com/coremidi-swift-programming/

// `LaunchControl` (shorter version of "Launch Control Center") as a nod to
// rocket terminology.

// Currently only supports the standard RGB launchpad.

class LaunchControl {

    /// A color used with to illuminate the Launchpad buttons
    struct LaunchpadColor {
        // Default color values
        static let Blue = LaunchpadColor(red: 0, green: 0, blue: 63)
        static let Gold = LaunchpadColor(red: 63, green: 31, blue: 0)
        static let Green = LaunchpadColor(red: 0, green: 63, blue: 0)
        static let Red = LaunchpadColor(red: 63, green: 0, blue: 0)
        static let Peach = LaunchpadColor(red: 63, green: 20, blue: 10)
        static let Yellow = LaunchpadColor(red: 63, green: 51, blue: 0)
        
        // Color value for turning light off
        static let Off = LaunchpadColor(red: 0, green: 0, blue: 0)
        
        var red: Int   = 0 // [0, 63]
        var green: Int = 0 // [0, 63]
        var blue: Int  = 0 // [0, 63]

        init() {}
        
        /// Create a launchpad color with the specified color values.
        /// - Parameters:
        ///   - red: The red intensity value [0, 63]
        ///   - green: The green intensity value [0, 63]
        ///   - blue: The blue intensity value [0, 63]
        init(red: Int, green: Int, blue: Int) {
            if red > 63 || green > 63 || blue > 63 {
                print("Warning! RGB value out of range (0,63) : red", red, "green:", green, "blue:", blue)
            } else {
                self.red = red
                self.green = green
                self.blue = blue
            }
        }
    }

    class LaunchpadButton {

        // Diagram of rows and columns with buttons
        //
        // top > o  o  o  o  o  o  o  o
        //    7 | [] [] [] [] [] [] [] [] o
        //    6 | [] [] [] [] [] [] [] [] o
        //    5 | [] [] [] [] [] [] [] [] o
        //    4 | [] [] []  pad  [] [] [] o
        //    3 | [] [] [] [] [] [] [] [] o
        //    2 | [] [] [] [] [] [] [] [] o
        //    1 | [] [] [] [] [] [] [] [] o
        //    0 | [] [] [] [] [] [] [] [] o
        //        —— —— —— —— —— —— —— —— ^
        //       0  1  2  3  4  5  6  7 side
        
        // - MIDI Status byte -
        // * 144 = channel 1 note on (Pads and side)
        // * 176 = channel 1 control change (Top)
        // * Source: https://www.midi.org/specifications-old/item/table-2-expanded-messages-list-status-bytes
        
        //LaunchpadButton(MIDIKeyValue: 11) // Pad; Bottom left corner
        //LaunchpadButton(MIDIKeyValue: 48) // Pad
        //LaunchpadButton(MIDIKeyValue: 89) // Side row; top one
        //LaunchpadButton(MIDIKeyValue: 105) // Top row; second one in

        enum LaunchpadButtonType {
            case pad
            case top
            case side
        }

        var type: LaunchpadButtonType = .pad
        var row: Int = 0
        var column: Int = 0
        var midiKeyValue: Int = 0

        init(midiKeyValue: Int) {
            self.midiKeyValue = midiKeyValue

            let adjustedValue = midiKeyValue - 11
            let row = Int(adjustedValue/10)
            let column = adjustedValue - (10 * row)

            self.row = row
            self.column = column

            if row == 9 {
                self.type = .top
                self.row = 8
            } else if column == 8 {
                self.type = .side
            } else {
                self.type = .pad
            }
        }
        
        init(row: Int, column: Int) {
            self.midiKeyValue = column + (10 * row) + 11

            self.row = row
            self.column = column

            if row == 8 {
                self.type = .top
            } else if column == 8 {
                self.type = .side
            } else {
                self.type = .pad
            }
        }
    }

    static func bridge<T : AnyObject>(obj : T) -> UnsafeRawPointer {
        return UnsafeRawPointer(Unmanaged.passUnretained(obj).toOpaque())
    }

    static func bridge<T : AnyObject>(ptr : UnsafeRawPointer) -> T {
        return Unmanaged<T>.fromOpaque(ptr).takeUnretainedValue()
    }

    class Launchpad {

        // Specify MIDI device number to use for input and output
        var source: MIDIEndpointRef
        var destination: MIDIEndpointRef
        
        // References required by the CoreMIDI library
        var midiClient = MIDIClientRef()
        var inPort = MIDIPortRef()
        var outPort = MIDIPortRef()
        
        var onTouch: ((LaunchpadButton, Bool, Int) -> Void)! = nil

        init() {
            source = 0
            destination = 0

            print("Error! Need device to create LaunchpadController.")
        }

        init(deviceNumber: Int) {
            self.source = MIDIGetSource(deviceNumber)
            self.destination = MIDIGetDestination(deviceNumber)

            print("Using: \(getDisplayName(self.source))")

            MIDIClientCreate("LaunchpadClient" as CFString, nil, nil, &midiClient)

            let selfPointer = Unmanaged.passRetained(self).toOpaque()

            // Hook up the midiHandler function to recieve MIDI input
            // In depth article about this C function callback problem: https://www.rockhoppertech.com/blog/swift-midi-trampoline/
            // More on the self pointer:
            //   - https://forums.developer.apple.com/message/238250#238250
            //   - https://forums.developer.apple.com/message/191454#191454
            MIDIInputPortCreate(midiClient, "LaunchpadInPort" as CFString, { (unsafePacketList, unsafeContext, unsafeSource) in
                if let context = unsafeContext {
                    let hackySelf = Unmanaged<Launchpad>.fromOpaque(context).takeUnretainedValue()
                    hackySelf.recieveMIDI(unsafePacketList, unsafeSource)
                }
            }, selfPointer, &inPort)

            MIDIPortConnectSource(inPort, source, &source)
            MIDIOutputPortCreate(midiClient, "LaunchpadOutPort" as CFString, &outPort)
        }
        
        // Callback for CoreMIDI to receive messages arriving from LaunchPad and pass on to processing.
        private func recieveMIDI(_ unsafePacketList: UnsafePointer<MIDIPacketList>, _ unsafeSource: UnsafeMutableRawPointer?) {
            let packetList = unsafePacketList.pointee

            // Start with the first packet
            var packet: MIDIPacket = packetList.packet

            // Iterate through the packets
            for _ in 1...packetList.numPackets {
                let message = createArray(fromPacket: packet)
                processMIDI(messageArray: message)

                // Advance to the next packet
                packet = MIDIPacketNext(&packet).pointee
            }
        }
        
        // Callback to decide what to do with messages arriving from LaunchPad.
        private func processMIDI(messageArray message: [Int]) {
            for messageIndex in stride(from: 0, to: message.count, by: 3) {
                // - MIDI Status byte (message[messageIndex])
                // * 144 = channel 1 note on
                // * 176 = channel 1 control change
                if message[messageIndex] == 144 || message[messageIndex] == 176 {
                    let button = LaunchpadButton(midiKeyValue: message[messageIndex + 1])
                    let velocity = message[messageIndex + 2]
                    let on = velocity != 0

                    onTouch(button, on, velocity)
                }
            }
        }
        
        /// Sends a midi packet to the Launchpad.
        /// - Parameter packet: An instance of MIDIPacket.
        func send(_ packet: MIDIPacket) {
            var packetList = MIDIPacketList(numPackets: 1, packet: packet)
            MIDISend(outPort, destination, &packetList)
        }
        
        /// Set the illumination parameters of the button to the RGB values. To turn off the button's light, send 0's for all RGB values.
        /// - Parameters:
        ///   - button: The LaunchpadButton to illuminate.
        ///   - red: Value from 0-63.
        ///   - green: Value from 0-63.
        ///   - blue: Value from 0-63.
        func light(button: LaunchpadButton, color: LaunchpadColor) {
            let lightPacket = creatRGBPacket(launchPadKey: button.midiKeyValue, color: color)
            send(lightPacket)
        }


        /// Create a packet for sending an RGB message to `Launchpad Mark II`.
        ///
        /// - Parameters:
        ///   - launchPadKey: The launchpad key to illuminate.
        ///   - red: Value from 0-63.
        ///   - green: Value from 0-63.
        ///   - blue: Value from 0-63.
        /// - Returns: MIDIPacket
        func creatRGBPacket(launchPadKey: Int, color: LaunchpadColor) -> MIDIPacket {
            // - Illuminate single LED with RGB values -
            // [ 0xF0, 0x00, 0x20, 0x29, 0x02, 0x18, 0x0B, <LED>, <Red>, <Green>, <Blue>, 0xF7 ]
            // To turn off send all 0x0 for RGB values
            
            let rgbMIDIArray = [0xF0, 0x00, 0x20, 0x29, 0x02, 0x18, 0x0B,           // Header information specifying the type of message for launchpad mk2
                                launchPadKey, color.red, color.green, color.blue,   // MIDI key and color information for launchpad mk2
                                0xF7]                                                 // Footer information for launchpad mk2

            return createPacket(fromArray: rgbMIDIArray)
        }


        /// Create a midi packet from an array.
        ///
        /// - Parameter packetArray: Array of values to insert into packet.
        /// - Returns: MIDIPacket
        func createPacket(fromArray packetArray: [Int]) -> MIDIPacket {
            var packet = MIDIPacket()
            
            // Convert the Int packetArray to a UInt8 array as required by MIDIPacket.
            var packetData: [UInt8] = []
            for value in packetArray {
                packetData.append(UInt8(value))
            }

            packet.timeStamp = 0 // Unclear what purpose this serves.
            packet.length = UInt16(packetData.count)
            
            // Copy the array of integers directly into the memory of the MIDIPacket since the packet data is
            // an immutable tuple (???).
            withUnsafeMutablePointer(to: &packet.data, { (destination) -> () in
                memcpy(destination, packetData, packetData.count)
            })

            return packet
        }

        /// Create a midi packet from an array.
        ///
        /// - Parameter packetArray: Array of values to insert into packet.
        /// - Returns: MIDIPacket
        func createArray(fromPacket packet: MIDIPacket) -> [Int] {
            var array: [Int] = []
            
            // Magic (???)
            let byteArray = Array(Mirror(reflecting: packet.data).children)
            
            for index in 0..<Int(packet.length) {
                if let value = byteArray[index].value as? UInt8 {
                    array.append(Int(value))
                }
            }

            return array
        }

    }

    static func getDisplayName(_ object: MIDIObjectRef) -> String {
        var nameReference: Unmanaged<CFString>?
        var name: String = ""

        let error = MIDIObjectGetStringProperty(object, kMIDIPropertyDisplayName, &nameReference)

        if error == OSStatus(noErr) {
            name = nameReference!.takeRetainedValue() as String
        }

        return name
    }

    static func getMIDIDestinationNames() -> [MIDIDeviceRef : String] {
        var names = [MIDIEndpointRef : String]()

        let midiDeviceCount = MIDIGetNumberOfDestinations()

        for deviceIndex in 0...midiDeviceCount {
            let device : MIDIDeviceRef = MIDIGetDestination(deviceIndex)

            if device != 0 {
                names[device] = getDisplayName(device)
            }
        }

        return names
    }

    static func getMIDISourceNames() -> [MIDIDeviceRef : String] {
        var names = [MIDIEndpointRef : String]()

        let midiDeviceCount = MIDIGetNumberOfDestinations()

        for deviceIndex in 0...midiDeviceCount {
            let device : MIDIDeviceRef = MIDIGetSource(deviceIndex)

            if device != 0 {
                names[device] = getDisplayName(device)
            }
        }

        return names
    }
}
