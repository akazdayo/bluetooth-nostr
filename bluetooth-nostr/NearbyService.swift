import CoreBluetooth
import Foundation
import Combine

/// BLE GATT carries a private, length-prefixed protocol; event signatures remain NIP-01.
final class NearbyService: NSObject, ObservableObject {
    static let serviceID = CBUUID(string: "A0F0F130-6A39-4A1A-9B2B-E491C14465A0")
    private static let inboundID = CBUUID(string: "A0F0F131-6A39-4A1A-9B2B-E491C14465A0")
    private static let outboundID = CBUUID(string: "A0F0F132-6A39-4A1A-9B2B-E491C14465A0")
    @Published private(set) var status = "停止中"
    @Published private(set) var discoveredCount = 0
    @Published private(set) var isRunning = false
    @Published private(set) var receivedCount = 0
    private weak var store: EventStore?
    private var central: CBCentralManager?
    private var peripheral: CBPeripheralManager?
    private var outbound: CBMutableCharacteristic?
    private var serviceAdded = false, addingService = false, advertising = false
    private var seen = Set<UUID>()
    private var connections: [UUID: CentralPeer] = [:]
    private var subscribers: [UUID: PeripheralPeer] = [:]
    private var reconnecting = Set<UUID>()

    private final class CentralPeer {
        let device: CBPeripheral
        var input: CBCharacteristic?
        var output: CBCharacteristic?
        var decoder = PeerDecoder()
        var queue = Data()
        var writing = false
        var ready = false
        init(_ device: CBPeripheral) { self.device = device }
    }
    private final class PeripheralPeer {
        let device: CBCentral
        var decoder = PeerDecoder()
        var queue = Data()
        init(_ device: CBCentral) { self.device = device }
    }

    func bind(_ store: EventStore) {
        guard self.store !== store else { return }
        self.store = store
        store.onChanged = { [weak self] in self?.broadcastInventory() }
    }
    func start() {
        guard !isRunning else { return }
        isRunning = true; seen.removeAll(); discoveredCount = 0
        status = "Bluetooth を準備中"
        if central == nil { central = CBCentralManager(delegate: self, queue: nil, options: [CBCentralManagerOptionRestoreIdentifierKey: "nostr.central.v1"]) }
        if peripheral == nil { peripheral = CBPeripheralManager(delegate: self, queue: nil, options: [CBPeripheralManagerOptionRestoreIdentifierKey: "nostr.peripheral.v1"]) }
        refresh()
    }
    func stop() {
        isRunning = false; central?.stopScan(); peripheral?.stopAdvertising(); advertising = false
        for peer in connections.values { central?.cancelPeripheralConnection(peer.device) }
        connections.removeAll(); subscribers.removeAll(); reconnecting.removeAll(); status = "停止中"
    }
    private func refresh() {
        guard isRunning else { return }
        if central?.state == .unauthorized || peripheral?.state == .unauthorized { status = "Bluetooth の使用が許可されていません"; return }
        guard central?.state == .poweredOn, peripheral?.state == .poweredOn else { status = "Bluetooth が利用可能になるのを待っています"; return }
        if central?.isScanning == false { central?.scanForPeripherals(withServices: [Self.serviceID], options: nil) }
        if !serviceAdded && !addingService {
            let input = CBMutableCharacteristic(type: Self.inboundID, properties: [.write], value: nil, permissions: [.writeable])
            let output = CBMutableCharacteristic(type: Self.outboundID, properties: [.notify], value: nil, permissions: [.readable])
            let service = CBMutableService(type: Self.serviceID, primary: true)
            service.characteristics = [input, output]; outbound = output; addingService = true
            peripheral?.add(service)
        } else if serviceAdded && !advertising {
            peripheral?.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [Self.serviceID]])
            advertising = true
        }
        status = "近くの端末を探索中"
    }
    private func inventory(_ send: (PeerMessage) -> Void) {
        let ids = store?.shareable.map(\.id) ?? []
        for start in stride(from: 0, to: ids.count, by: PeerFraming.maxIDs) {
            send(PeerMessage("inventory", ids: Array(ids[start..<min(start + PeerFraming.maxIDs, ids.count)])))
        }
    }
    private func broadcastInventory() {
        for peer in connections.values where peer.ready { inventory { enqueue($0, to: peer) } }
        for peer in subscribers.values { inventory { enqueue($0, to: peer) } }
    }
    private func process(_ message: PeerMessage, send: (PeerMessage) -> Void) throws {
        switch message.type {
        case "inventory":
            guard let ids = message.ids, ids.count <= PeerFraming.maxIDs, message.events == nil else { throw NostrError.encoding }
            let known = Set(store?.events.map(\.id) ?? [])
            let missing = ids.filter { Data(strictHex: $0, bytes: 32) != nil && !known.contains($0) }
            if !missing.isEmpty { send(PeerMessage("request", ids: Array(Set(missing)))) }
        case "request":
            guard let ids = message.ids, ids.count <= PeerFraming.maxIDs, message.events == nil else { throw NostrError.encoding }
            let wanted = Set(ids)
            for event in store?.shareable ?? [] where wanted.contains(event.id) { send(PeerMessage("event", events: [event])) }
        case "event":
            guard message.ids == nil, let events = message.events, events.count == 1 else { throw NostrError.encoding }
            if store?.accept(events[0]) == true { receivedCount += 1 }
        default: throw NostrError.encoding
        }
    }
    private func enqueue(_ message: PeerMessage, to peer: CentralPeer) {
        guard let frame = try? PeerFraming.encode(message), peer.queue.count + frame.count <= PeerFraming.maxQueued else { central?.cancelPeripheralConnection(peer.device); return }
        peer.queue.append(frame); flush(peer)
    }
    private func flush(_ peer: CentralPeer) {
        guard peer.ready, !peer.writing, !peer.queue.isEmpty, let input = peer.input else { return }
        let count = min(peer.queue.count, peer.device.maximumWriteValueLength(for: .withResponse))
        guard count > 0 else { return }
        let chunk = Data(peer.queue.prefix(count)); peer.queue.removeFirst(count); peer.writing = true
        peer.device.writeValue(chunk, for: input, type: .withResponse)
    }
    private func enqueue(_ message: PeerMessage, to peer: PeripheralPeer) {
        guard let frame = try? PeerFraming.encode(message), peer.queue.count + frame.count <= PeerFraming.maxQueued else { subscribers.removeValue(forKey: peer.device.identifier); return }
        peer.queue.append(frame); flush(peer)
    }
    private func flush(_ peer: PeripheralPeer) {
        guard let peripheral, let outbound, isRunning else { return }
        while !peer.queue.isEmpty {
            let count = min(peer.queue.count, peer.device.maximumUpdateValueLength)
            guard count > 0 else { return }
            if !peripheral.updateValue(Data(peer.queue.prefix(count)), for: outbound, onSubscribedCentrals: [peer.device]) { return }
            peer.queue.removeFirst(count)
        }
    }
    private func reconnect(_ device: CBPeripheral) {
        guard isRunning, reconnecting.insert(device.identifier).inserted else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self else { return }
            self.reconnecting.remove(device.identifier)
            guard self.isRunning, self.central?.state == .poweredOn, self.connections[device.identifier] == nil else { return }
            self.connections[device.identifier] = CentralPeer(device); self.central?.connect(device)
        }
    }
}

extension NearbyService: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) { refresh() }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard isRunning else { return }
        seen.insert(peripheral.identifier); discoveredCount = seen.count
        guard connections[peripheral.identifier] == nil, !reconnecting.contains(peripheral.identifier), connections.count < 8 else { return }
        connections[peripheral.identifier] = CentralPeer(peripheral); central.connect(peripheral)
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard isRunning, connections[peripheral.identifier] != nil else { central.cancelPeripheralConnection(peripheral); return }
        peripheral.delegate = self; peripheral.discoverServices([Self.serviceID])
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) { connections.removeValue(forKey: peripheral.identifier); reconnect(peripheral) }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) { connections.removeValue(forKey: peripheral.identifier); reconnect(peripheral) }
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        guard UserDefaults.standard.bool(forKey: "nearbyEnabled") else { return }
        isRunning = true
        for device in dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? [] {
            connections[device.identifier] = CentralPeer(device); device.delegate = self
            if device.state == .connected { device.discoverServices([Self.serviceID]) }
        }
        refresh()
    }
}

extension NearbyService: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == Self.serviceID }) else { central?.cancelPeripheralConnection(peripheral); return }
        peripheral.discoverCharacteristics([Self.inboundID, Self.outboundID], for: service)
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil, let peer = connections[peripheral.identifier], let input = service.characteristics?.first(where: { $0.uuid == Self.inboundID }), let output = service.characteristics?.first(where: { $0.uuid == Self.outboundID }) else { central?.cancelPeripheralConnection(peripheral); return }
        peer.input = input; peer.output = output; peripheral.setNotifyValue(true, for: output)
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, characteristic.isNotifying, let peer = connections[peripheral.identifier] else { central?.cancelPeripheralConnection(peripheral); return }
        peer.ready = true; inventory { enqueue($0, to: peer) }; flush(peer)
    }
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let peer = connections[peripheral.identifier] else { return }
        if error != nil { central?.cancelPeripheralConnection(peripheral); return }
        peer.writing = false; flush(peer)
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let data = characteristic.value, let peer = connections[peripheral.identifier] else { central?.cancelPeripheralConnection(peripheral); return }
        do { for message in try peer.decoder.append(data) { try process(message) { enqueue($0, to: peer) } } }
        catch { central?.cancelPeripheralConnection(peripheral) }
    }
}

extension NearbyService: CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        if peripheral.state != .poweredOn { serviceAdded = false; addingService = false; advertising = false; subscribers.removeAll() }
        refresh()
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        addingService = false
        guard error == nil else { status = "Bluetooth サービスを公開できませんでした"; return }
        serviceAdded = true; refresh()
    }
    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if error != nil { advertising = false; status = "Bluetooth の広告を開始できませんでした" }
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        guard isRunning, characteristic.uuid == Self.outboundID, subscribers.count < 8 else { return }
        let peer = PeripheralPeer(central); subscribers[central.identifier] = peer
        inventory { enqueue($0, to: peer) }
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) { subscribers.removeValue(forKey: central.identifier) }
    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) { for peer in subscribers.values { flush(peer) } }
    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        guard let first = requests.first else { return }
        guard isRunning, requests.allSatisfy({ $0.characteristic.uuid == Self.inboundID && $0.offset == 0 && $0.central.identifier == first.central.identifier }), let peer = subscribers[first.central.identifier] else { peripheral.respond(to: first, withResult: .unlikelyError); return }
        do {
            for request in requests {
                guard let data = request.value else { throw NostrError.encoding }
                for message in try peer.decoder.append(data) { try process(message) { enqueue($0, to: peer) } }
            }
            peripheral.respond(to: first, withResult: .success)
        } catch { subscribers.removeValue(forKey: first.central.identifier); peripheral.respond(to: first, withResult: .unlikelyError) }
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, willRestoreState dict: [String: Any]) {
        let services = dict[CBPeripheralManagerRestoredStateServicesKey] as? [CBMutableService] ?? []
        let service = services.first { $0.uuid == Self.serviceID }
        outbound = service?.characteristics?.first { $0.uuid == Self.outboundID } as? CBMutableCharacteristic
        serviceAdded = outbound != nil; advertising = peripheral.isAdvertising
        if UserDefaults.standard.bool(forKey: "nearbyEnabled") { isRunning = true; refresh() }
    }
}
