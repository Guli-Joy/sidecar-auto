#!/bin/bash
# Detect a physically enumerated Apple iPad USB data device.
#
# Exit status:
#   0  exactly one iPad matched (or a configured USB serial matched)
#   1  no matching iPad USB device; caller may choose wireless
#   2  the IORegistry probe failed; caller should log the probe failure
#   3  multiple iPads matched; caller should avoid guessing the target
#
# A power-only cable does not create an IOUSBHostDevice and therefore cannot
# match. Apple VID plus an iPad product descriptor excludes hubs, displays,
# storage, and unrelated USB devices. Sidecar's friendly device name is not
# exposed in USB descriptors; set IPAD_USB_SERIAL_NUMBER in the shared config
# if more than one iPad may be attached or the target must be pinned exactly.

set -u

CONFIG="${SIDECAR_AUTO_CONFIG:-$HOME/.config/sidecar-auto/config}"
[ -r "$CONFIG" ] && . "$CONFIG"

: "${IPAD_USB_SERIAL_NUMBER:=}"
: "${IOREG_BIN:=/usr/sbin/ioreg}"

if [ ! -x "$IOREG_BIN" ]; then
    printf 'USB_PROBE_ERROR\tioreg not executable: %s\n' "$IOREG_BIN"
    exit 2
fi

# ioreg's IOUSBHostDevice nodes represent USB devices that have enumerated on
# the data bus. Match Apple VID 0x05ac (decimal 1452) and an iPad descriptor.
# The parser starts a fresh block at every IOUSBHostDevice node, so a hub or
# another nested device cannot inherit the iPad's properties.
registry_output="$($IOREG_BIN -p IOUSB -r -c IOUSBHostDevice -l -w 0 2>/dev/null)"
probe_status=$?
if [ "$probe_status" -ne 0 ]; then
    printf 'USB_PROBE_ERROR\tioreg query failed (status=%s)\n' "$probe_status"
    exit 2
fi

# An empty IORegistry result is a valid "no USB device" result. This is
# common on a Mac with no USB peripherals and must select wireless in auto
# mode instead of being reported as a probe failure.

match_output="$(printf '%s\n' "$registry_output" | awk -v wanted_serial="$IPAD_USB_SERIAL_NUMBER" '
function unquote(value) {
    sub(/^[[:space:]]*/, "", value)
    sub(/[[:space:]]*$/, "", value)
    if (value ~ /^".*"$/) {
        sub(/^"/, "", value)
        sub(/"$/, "", value)
    }
    return value
}
function flush_device(    product, name) {
    if (!in_device) return
    product = usb_product
    if (product == "") product = registry_name
    # A configured serial is an explicit pairing override. It also covers
    # iPadOS recovery/lockdown descriptors whose product text is not "iPad".
    if (vendor_id == "1452" &&
        (tolower(product) ~ /ipad/ ||
         (wanted_serial != "" && usb_serial == wanted_serial))) {
        if (wanted_serial == "" || usb_serial == wanted_serial) {
            name = registry_name
            sub(/@.*/, "", name)
            if (name == "") name = product
            printf "%s\t%s\n", name, usb_serial
        }
    }
}
/\+-o .*<class IOUSBHostDevice,/ {
    flush_device()
    in_device = 1
    registry_name = ""
    usb_product = ""
    usb_serial = ""
    vendor_id = ""
    if (in_device) {
        registry_name = $0
        sub(/^.*\+-o /, "", registry_name)
        sub(/[[:space:]]+<class.*/, "", registry_name)
    }
    next
}
in_device && /"idVendor"[[:space:]]*=/ {
    value = $0; sub(/^.*"idVendor"[[:space:]]*=[[:space:]]*/, "", value); vendor_id = unquote(value)
}
in_device && /"USB Product Name"[[:space:]]*=/ {
    value = $0; sub(/^.*"USB Product Name"[[:space:]]*=[[:space:]]*/, "", value); usb_product = unquote(value)
}
in_device && /"kUSBProductString"[[:space:]]*=/ {
    value = $0; sub(/^.*"kUSBProductString"[[:space:]]*=[[:space:]]*/, "", value)
    if (usb_product == "") usb_product = unquote(value)
}
in_device && /"USB Serial Number"[[:space:]]*=/ {
    value = $0; sub(/^.*"USB Serial Number"[[:space:]]*=[[:space:]]*/, "", value); usb_serial = unquote(value)
}
in_device && /"kUSBSerialNumberString"[[:space:]]*=/ {
    value = $0; sub(/^.*"kUSBSerialNumberString"[[:space:]]*=[[:space:]]*/, "", value)
    if (usb_serial == "") usb_serial = unquote(value)
}
END { flush_device() }
')"
awk_status=$?
if [ "$awk_status" -ne 0 ]; then
    printf 'USB_PROBE_ERROR\tfailed to parse IORegistry output\n'
    exit 2
fi

match_count="$(printf '%s\n' "$match_output" | awk 'NF { n++ } END { print n+0 }')"
if [ "$match_count" -eq 1 ]; then
    printf 'USB_IPAD_MATCHED\t%s\n' "$match_output"
    exit 0
fi
if [ "$match_count" -eq 0 ]; then
    if [ -n "$IPAD_USB_SERIAL_NUMBER" ]; then
        printf 'USB_IPAD_NOT_FOUND\tno enumerated iPad matched configured USB serial\n'
    else
        printf 'USB_IPAD_NOT_FOUND\tno Apple iPad USB data device found\n'
    fi
    exit 1
fi

printf 'USB_IPAD_AMBIGUOUS\t%d iPads enumerated; set IPAD_USB_SERIAL_NUMBER to select one\n' "$match_count"
exit 3
