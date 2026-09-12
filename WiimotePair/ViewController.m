// Copyright 2024 Dolphin Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#import "ViewController.h"

#import "IOBluetoothCoreBluetoothCoordinator+Private.h"
#import "IOBluetoothDevice+Private.h"
#import "IOBluetoothDevicePair+Private.h"

@implementation ViewController {
    CBCentralManager* _centralManager;
    IOBluetoothDeviceInquiry* _deviceInquiry;
    IOBluetoothDevicePair* _devicePair;
    NSMutableArray<NSString*>* _debugLog;
}

- (void)debugLog:(NSString*)message {
    if (_debugLog == nil) {
        _debugLog = [NSMutableArray array];
    }
    NSLog(@"[WiimotePair] %@", message);
    [_debugLog addObject:message];
}

- (NSString*)flushDebugLog {
    NSString* log = [_debugLog componentsJoinedByString:@"\n"];
    _debugLog = [NSMutableArray array];
    return log;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    
    [self.progressIndicator startAnimation:self];
}

- (void)viewDidAppear {
    [super viewDidAppear];
    
    if (_centralManager == nil) {
        _centralManager = [[CBCentralManager alloc] initWithDelegate:self queue:nil];
    }
}

- (void)setRepresentedObject:(id)representedObject {
    [super setRepresentedObject:representedObject];
}

- (void)showAlertWithTitle:(NSString*)title text:(NSString*)text callback:(void (^)(void))callback {
    NSAlert* alert = [[NSAlert alloc] init];
    
    [alert setMessageText:title];
    [alert setInformativeText:text];
    [alert addButtonWithTitle:@"OK"];
    
    [alert beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse response) {
        callback();
    }];
}

- (void)showPairingResultAlertWithTitle:(NSString*)title text:(NSString*)text {
    NSString* log = [self flushDebugLog];
    NSString* fullText = log.length > 0
        ? [NSString stringWithFormat:@"%@\n\n--- Debug Log ---\n%@", text, log]
        : text;
    [self showAlertWithTitle:title text:fullText callback:^{
        if (self->_deviceInquiry != nil) {
            [self->_deviceInquiry start];
        }
    }];
}

- (void)showFatalErrorAlertWithTitle:(NSString*)title text:(NSString*)text {
    [self showAlertWithTitle:title text:text callback:^{
        [NSApp terminate:self];
    }];
}

// CBCentralManagerDelegate

- (void)centralManagerDidUpdateState:(nonnull CBCentralManager*)centralManager {
    CBManagerState state = centralManager.state;
    
    if (state == CBManagerStateUnauthorized) {
        [self showFatalErrorAlertWithTitle:@"Bluetooth Permission Denied" text:@"WiimotePair is not allowed to access Bluetooth. Please allow WiimotePair to access Bluetooth in the \"Privacy & Security\" pane within the System Settings app."];
    } else if (state == CBManagerStatePoweredOff) {
        if (_deviceInquiry != nil) {
            [_deviceInquiry stop];
            _deviceInquiry = nil;
        }
        
        if (_devicePair != nil) {
            [_devicePair stop];
            _devicePair = nil;
        }
        
        [self showFatalErrorAlertWithTitle:@"Bluetooth Unavailable" text:@"Please turn Bluetooth on before running WiimotePair."];
    } else if (state == CBManagerStateUnsupported || state == CBManagerStateUnknown) {
        [self showFatalErrorAlertWithTitle:@"Unknown Bluetooth Error" text:@"CBCentralManager is in an invalid state. Relaunch WiimotePair and try again."];
    } else if (state == CBManagerStatePoweredOn) {
        if (_deviceInquiry == nil) {
            _deviceInquiry = [IOBluetoothDeviceInquiry inquiryWithDelegate:self];
            _deviceInquiry.searchType = kIOBluetoothDeviceSearchClassic;
            
            [_deviceInquiry start];
        }
    }
    
    // TODO: handle CBManagerStateResetting?
}

// IOBluetoothDeviceInquiryDelegate

- (void)deviceInquiryDeviceFound:(IOBluetoothDeviceInquiry*)sender device:(IOBluetoothDevice*)device {
    // Skip unsupported devices.
    if (![device.name containsString:@"Nintendo RVL-CNT-01"]) {
        // Clear devices to enable rediscovery if the name changes.
        [_deviceInquiry clearFoundDevices];
        return;
    }
    
    // Skip already paired devices.
    if (device.isPaired) {
        return;
    }
    
    _debugLog = [NSMutableArray array];
    [self debugLog:[NSString stringWithFormat:@"Device found: %@ (%@)", device.name, device.addressString]];
    id classicPeer = [device classicPeer];
    NSNumber* deviceType = [classicPeer valueForKey:@"deviceType"];
    [self debugLog:[NSString stringWithFormat:@"classOfDevice: 0x%06X, deviceType: %@", device.classOfDevice, deviceType]];
    [_deviceInquiry stop];
    
    _devicePair = [IOBluetoothDevicePair pairWithDevice:device];
    _devicePair.delegate = self;
    
    // We need to call this private API to ensure that the delegate is always queried for the PIN.
    [_devicePair setUserDefinedPincode:true];
    [self debugLog:@"setUserDefinedPincode: called"];
    
    IOReturn pairResult = [_devicePair start];
    [self debugLog:[NSString stringWithFormat:@"pair start: 0x%08X (%s)", pairResult, mach_error_string(pairResult)]];
    if (pairResult != kIOReturnSuccess) {
        char* pairResultString = mach_error_string(pairResult);
        
        [self showPairingResultAlertWithTitle:@"Pairing Error" text:[NSString stringWithFormat:@"An error occurred while starting the pairing process: \"%s\".", pairResultString]];
        
        return;
    }
}

- (void)deviceInquiryComplete:(IOBluetoothDeviceInquiry*)sender error:(IOReturn)error aborted:(BOOL)aborted {
    // Restart inquiries that have timed out.
    if (!aborted) {
        [sender clearFoundDevices];
        [sender start];
    }
}

// IOBluetoothDevicePairDelegate

- (void)devicePairingPINCodeRequest:(id)sender {
    IOBluetoothDevicePair* pair = (IOBluetoothDevicePair*)sender;
    [self debugLog:@"PIN request received ✓"];

    IOBluetoothHostController* controller = [IOBluetoothHostController defaultController];
    
    NSString* controllerAddressStr = [controller addressAsString];
    [self debugLog:[NSString stringWithFormat:@"Controller address: %@", controllerAddressStr]];
    
    BluetoothDeviceAddress controllerAddress;
    IOBluetoothNSStringToDeviceAddress(controllerAddressStr, &controllerAddress);

    BluetoothPINCode code;
    memset(&code, 0, sizeof(code));

    // When using the SYNC button, the PIN is the address of the Bluetooth controller in reverse.
    for (int i = 0; i < 6; i++) {
        code.data[i] = controllerAddress.data[5 - i];
    }

    uint64_t key;
    memcpy(&key, code.data, sizeof(key));
    [self debugLog:[NSString stringWithFormat:@"PIN bytes: %02X %02X %02X %02X %02X %02X",
                    code.data[0], code.data[1], code.data[2],
                    code.data[3], code.data[4], code.data[5]]];

    // replyPINCodeWithNumber: exists on older macOS too but behaves correctly only on macOS 26+
    // (where it routes through the XPC pairing agent). On macOS 12-15 it corrupts binary PINs
    // internally. Use an explicit version check rather than respondsToSelector:.
    BOOL isMacOS26OrLater = [NSProcessInfo.processInfo
        isOperatingSystemAtLeastVersion:(NSOperatingSystemVersion){26, 0, 0}];
    if (isMacOS26OrLater) {
        [self debugLog:@"Path: replyPINCodeWithNumber: (macOS 26+)"];
        [pair replyPINCodeWithNumber:@(key)];
    } else {
        NSUInteger pairingType = [pair currentPairingType];
        [self debugLog:[NSString stringWithFormat:@"Path: pairPeer:forType:withKey: (pairingType=%lu)", (unsigned long)pairingType]];
        IOBluetoothCoreBluetoothCoordinator* coordinator = [IOBluetoothCoreBluetoothCoordinator sharedInstance];
        [self debugLog:[NSString stringWithFormat:@"Coordinator: %@", coordinator ? @"found" : @"nil (!)"]];
        IOBluetoothDevice* device = [sender device];
        [coordinator pairPeer:[device classicPeer]
                      forType:pairingType
                      withKey:@(key)];
    }
}

- (void)devicePairingFinished:(id)sender error:(IOReturn)error {
    [self debugLog:[NSString stringWithFormat:@"Pairing finished: 0x%08X (%s)", error, mach_error_string(error)]];
    IOBluetoothDevice* device = [sender device];
    id classicPeer = [device classicPeer];
    NSNumber* deviceType = [classicPeer valueForKey:@"deviceType"];
    [self debugLog:[NSString stringWithFormat:@"Post-pair classOfDevice: 0x%06X, deviceType: %@", device.classOfDevice, deviceType]];

    if (error == kIOReturnSuccess) {
        // On macOS 26, the standard Wiimote (RVL-CNT-01) gets deviceType=49 (Pointing Device),
        // causing macOS to claim exclusive HID access and blocking Dolphin. The Wii Remote Plus
        // (RVL-CNT-01-TR) correctly gets deviceType=26 (Game Controller). Force the correct type.
        BOOL correctedDeviceType = NO;
        if ([deviceType integerValue] == 49) {
            [classicPeer setValue:@(26) forKey:@"deviceType"];
            [self debugLog:@"Corrected deviceType: 49 → 26 (Game Controller)"];
            correctedDeviceType = YES;
        }

        // On macOS 26, bluetoothd's in-memory link-key state can be stale after re-pairing a
        // device that was previously paired to another host (e.g. a real Wii or Wii U). Opening
        // a connection forces bluetoothd to reload the link key from its on-disk database,
        // equivalent to toggling Bluetooth off/on but without disrupting other peripherals.
        // Skip this for devices where we corrected deviceType (standard Wiimote): opening a
        // connection there causes a reconnect loop due to the unresolved Magic Trackpad issue.
        BOOL isMacOS26OrLater = [NSProcessInfo.processInfo
            isOperatingSystemAtLeastVersion:(NSOperatingSystemVersion){26, 0, 0}];
        if (isMacOS26OrLater && !correctedDeviceType) {
            [self debugLog:@"Opening connection to refresh bluetoothd link-key cache (macOS 26+)"];
            IOReturn openResult = [device openConnection:self];
            [self debugLog:[NSString stringWithFormat:@"openConnection: 0x%08X (%s)", openResult, mach_error_string(openResult)]];
        }
    }

    [_devicePair stop];
    _devicePair = nil;

    if (error != kIOReturnSuccess) {
        char* pairResultString = mach_error_string(error);
        
        [self showPairingResultAlertWithTitle:@"Pairing Error" text:[NSString stringWithFormat:@"An error occurred while attempting to pair: \"%s\".", pairResultString]];
    } else {
        [self showPairingResultAlertWithTitle:@"Paired" text:@"The Wii Remote has been paired with your Mac."];
    }
}

// IOBluetoothDevice openConnection: async callback
- (void)connectionComplete:(IOBluetoothDevice*)device status:(IOReturn)status {
    NSLog(@"[WiimotePair] connectionComplete: 0x%08X (%s)", status, mach_error_string(status));
    // Release the connection immediately so Dolphin can claim the HID profile.
    if (status == kIOReturnSuccess) {
        [device closeConnection];
        NSLog(@"[WiimotePair] Link-key cache refreshed, connection released for Dolphin");
    }
}

@end
