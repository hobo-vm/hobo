# USB passthrough (a YubiKey in a guest): spike

Can hobo hand a host USB device to a guest? macOS 27 adds `VZUSBPassthroughDevice`, whose
configuration takes an `AAUSBAccessory` from the new AccessoryAccess framework, and nothing else.

**Result: blocked at signing. AccessoryAccess needs `com.apple.developer.accessory-access.usb`,
which is a restricted entitlement: an ad-hoc signed binary carrying it is killed at launch, and
one without it cannot reach the service.** hobo's default build is ad-hoc signed
(`HOBO_SIGN_IDENTITY ?= -`), so passthrough needs a provisioning profile that grants the
entitlement. Run on 2026-11-20 on macOS 27.2 (26B5091g).

## Running it

```sh
swiftc -O main.swift -o spike
codesign --force --sign - --entitlements aa.plist spike    # or ../../entitlements.plist
./spike [--policy none|accessory|regular] list [seconds]
./spike [--policy ...] boot <disk> <console-log> <vid:pid> [--at-boot]
```

`list` registers a listener for every USB device and prints what is connected. `boot` starts a
bare Linux guest on a copy of a hobo disk with an XHCI controller, and passes the `vid:pid`
device through, at boot (`--at-boot`) or with `VZUSBController.attach` once the guest is up.
`--policy` sets the activation policy, since the `AAUSBAccessoryManager` header says to use it
only from an app that appears in the Dock.

## Results

| Signature | Entitlements | Result |
|---|---|---|
| ad-hoc | virtualization only | launches; `registerListener` fails with `AAErrorDomain` 1, "Unable to communicate with service", under every activation policy |
| ad-hoc | virtualization + `accessory-access.usb` | killed at launch (exit 137); the kernel logs "Code has restricted entitlements, but the validation of its code signature failed" |

## Not tested

Everything past registration, because no listener ever registered:

- `boot` compiles but has never run. Whether a guest sees the device, at boot or hot-attached, is
  unknown, as is whether a YubiKey works once it does.
- Whether the manager works from a process that isn't in the Dock (`_vm-run` is `.accessory`),
  and what UI it presents.
- A Developer ID signature with the entitlement and no profile. Restricted entitlements are
  granted by a profile, so it should be killed the same way.

No YubiKey was plugged in, and none of the 102 provisioning profiles on this Mac grants the
entitlement.

## To go further

A provisioning profile for a team App ID that grants `com.apple.developer.accessory-access.usb`,
covering this Mac. A profile has to be embedded in an app bundle
(`Contents/embedded.provisionprofile`), so the spike, and later whatever in hobo talks to
AccessoryAccess, has to be wrapped in one and signed with the profile's identity. Xcode 27 doesn't
list the capability among the ones it can add, so it may need requesting from Apple.
