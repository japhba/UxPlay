#!/usr/bin/env python3
import sys
import os
import socket
import struct
import time
from Foundation import NSObject, NSData, NSRunLoop
from CoreBluetooth import (
    CBPeripheralManager,
    CBManagerStatePoweredOn,
    CBAdvertisementDataLocalNameKey,
    CBAdvertisementDataManufacturerDataKey
)
import objc

BLE_FILE_PATH = os.path.expanduser("~/.uxplay.ble")

def get_best_ip():
    """
    Finds the best IP address to broadcast.
    Prioritizes non-local (192.x, 172.x, 10.x) over 127.0.0.1.
    """
    # Attempt 1: Standard socket connect (works if Internet is up)
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        if ip != "127.0.0.1":
            return ip
    except Exception:
        pass

    # Attempt 2: Iterate interfaces (better for ad-hoc/USB networks without internet)
    try:
        # Get all IPs using getaddrinfo on the hostname
        hostname = socket.gethostname()
        ip_list = socket.gethostbyname_ex(hostname)[2]
        
        # Filter for the most likely useful IP (e.g., 192.168.x.x from USB sharing)
        for ip in ip_list:
            if ip.startswith("192.168."): # Bridge/USB networks often use this
                return ip
            if ip.startswith("10."):      # Enterprise/VPN
                return ip
            if ip.startswith("172."):     # Enterprise/Docker
                return ip
        
        # Fallback to the first non-loopback found
        for ip in ip_list:
            if ip != "127.0.0.1":
                return ip
    except Exception:
        pass

    return "127.0.0.1" # Last resort

def get_uxplay_port():
    if not os.path.exists(BLE_FILE_PATH):
        print(f"Error: {BLE_FILE_PATH} not found. Run UxPlay first.")
        return None
    
    with open(BLE_FILE_PATH, "rb") as f:
        content = f.read()
        
    # Try text parsing
    try:
        text_chunk = content.split(b'\n')[0].split(b'\x00')[0]
        port_str = text_chunk.decode('ascii')
        if port_str.isdigit():
            return int(port_str)
    except Exception:
        pass 

    # Try binary parsing (Big Endian)
    if len(content) >= 2:
        try:
            port = struct.unpack(">H", content[:2])[0]
            if 1024 <= port <= 65535:
                return port
        except Exception:
            pass

    print("Error: Could not parse port.")
    return None

class BeaconDelegate(NSObject):
    def peripheralManagerDidUpdateState_(self, manager):
        if manager.state() == CBManagerStatePoweredOn:
            self.start_advertising(manager)

    def start_advertising(self, manager):
        port = get_uxplay_port()
        if not port:
            print("Failed to get port. Exiting.")
            sys.exit(1)

        ip_str = get_best_ip()
        print(f"Broadcasting: UxPlay @ {ip_str}:{port}")

        company_id = struct.pack(">H", 0x004C) 
        prefix = b'\x09\x08'
        magic = b'\x13\x30'
        ip_bytes = socket.inet_aton(ip_str)
        port_bytes = struct.pack(">H", port)
        
        full_payload = company_id + prefix + magic + ip_bytes + port_bytes
        payload_nsdata = NSData.dataWithBytes_length_(full_payload, len(full_payload))
        
        adv_data = {
            CBAdvertisementDataLocalNameKey: "UxPlay",
            CBAdvertisementDataManufacturerDataKey: payload_nsdata
        }
        
        manager.startAdvertising_(adv_data)
        print("Beacon active. (Ctrl+C to stop)")

def main():
    delegate = BeaconDelegate.alloc().init()
    manager = CBPeripheralManager.alloc().initWithDelegate_queue_(delegate, None)
    try:
        NSRunLoop.currentRunLoop().run()
    except KeyboardInterrupt:
        pass

if __name__ == "__main__":
    main()