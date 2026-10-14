# foldctl

Sets the hinge angle and the orientation of the iPhone Duo simulator from the command line, the way Device Hub does.

foldctl is meant for coding agents that test apps in the simulator. Device Hub's controls need someone clicking in its window, and Xcode has no official command-line way to set the hinge angle or orientation. foldctl is a workaround until Xcode gets one, and since it relies on the private CoreDevice API, an Xcode update can break it.

![foldctl folding and unfolding the iPhone Duo simulator](https://github.com/user-attachments/assets/75edd7bc-dd46-4914-bfcb-4ccacb6e8496)

```sh
foldctl <device> [--hinge <angle>] [--orientation <orientation>]
```

- `device`: a simulator UDID, a simulator name, or `booted` when exactly one simulator is booted.
- `--hinge`: `closed` (0°), `half` (90°), `open` (180°), or any angle from 0 to 180.
- `--orientation`: `portrait`, `landscape-left`, `landscape-right`, `faceup` or `facedown`. There is no portrait-upside-down.

```sh
foldctl booted
foldctl booted --hinge closed
foldctl "iPhone Duo" --hinge half --orientation landscape-left
foldctl 12831311-220C-4D83-9D77-A176E6E9FBF1 --hinge 135
```

Without options, foldctl prints the current hinge angle and orientation, such as `iPhone Duo: hinge 90°, landscape-left`. With options, it sends the new values, waits until the simulator reports them, and prints them. It exits 0 on success, 64 on a usage error, and 1 when the device is unknown, not booted or not foldable, or when CoreDevice or the simulator does not respond within 60 seconds.

In testing, `XCUIDevice.orientation` and CoreDevice's `OrientationControl` did not rotate either display of the iPhone Duo, so foldctl sends the HID event that Device Hub uses instead.

## Requirements

- A Mac with Apple silicon.
- Xcode with the iPhone Duo simulator. foldctl compiles against the CoreDevice framework in `/Library/Developer/PrivateFrameworks`, which Xcode installs the first time it opens.

## Installation

With Homebrew:

```sh
brew install tatsuz0u/tap/foldctl
```

With npm:

```sh
npm install -g github:tatsuz0u/foldctl
```

Or clone the repository anywhere and link the `foldctl` script into a directory on your `PATH`:

```sh
git clone https://github.com/tatsuz0u/foldctl.git
ln -s "$PWD/foldctl/foldctl" ~/.local/bin/foldctl
```

Each method links a `foldctl` command to the script, which follows the link back to its folder and compiles the Swift tool into `.build/` there. Homebrew compiles it during installation and the other methods on first use. The script compiles it again whenever the sources, the interfaces or CoreDevice change.

## How it works

Device Hub's hinge and orientation controls send a vendor-defined HID event through CoreDevice, with usage page `0xFF61` and usage `0x5B`. Its data is a dictionary in binary `IOCFSerialize` form:

| Control | Dictionary |
| --- | --- |
| Hinge | `{"source": "hinge-slider-control", "type": "range", "value": <degrees>}` |
| Orientation | `{"source": "orientation-picker-control", "type": "enum", "value": "<orientation>"}` |

Inside the simulator, `dtuhidd` posts the event and the device state relay in `locationd` applies it.

foldctl does the same through the private CoreDevice API:

1. It resolves the device argument to a UDID with `simctl list devices`.
2. A `DeviceManager` that admits simulators finds the device. `DeviceManager.shared` hides them.
3. CoreDevice's motion monitor confirms that the device is foldable and streams its hinge angle and motion state.
4. After `sendBarrier()`, which waits until `dtuhidd` has built the connection's virtual HID services, foldctl sends the events.
5. It waits for the monitor to report the new hinge angle and orientation. The services hold the events until `locationd` opens them, and they go away when the process exits, so exiting right after `send` loses them.

The motion state names its properties opaquely. `propertyA` is the orientation, numbered like `UIDeviceOrientation` (1 portrait, 3 landscape-left, 4 landscape-right, 5 faceup, 6 facedown). `propertyB` is the posture that `locationd` derives from the hinge angle (1 closed, 2 partially open, 3 open flat). The posture can lag the angle, so foldctl reports the angle.

`Interfaces/` holds hand-written Swift interfaces for the few CoreDevice and CoreDeviceUtilities symbols that foldctl uses. They mirror the frameworks' exported symbols. If a CoreDevice update renames one, the build fails with a missing-symbol error; start the fix in these files.

## License

MIT. See [LICENSE](LICENSE).
