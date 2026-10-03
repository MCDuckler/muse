package dev.muse.muse

import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbConstants
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbDeviceConnection
import android.hardware.usb.UsbEndpoint
import android.hardware.usb.UsbInterface
import android.hardware.usb.UsbManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * DJ consoles that are USB HID devices, on an OTG cable.
 *
 * A Hercules RMX has no MIDI interface, so Android's own MIDI service never sees it;
 * what it has is a HID interface with an interrupt IN endpoint that says the state of
 * every button and knob in one 25-byte report, and an output report for the lights.
 * This reads the one and writes the other, and nothing more: the layout that gives
 * the bytes their meaning lives on the Dart side.
 *
 * Channels: `muse/hid` (list / open / write / close), `muse/hid/packets` (every report,
 * as {id, bytes}), `muse/hid/changes` (something was plugged in or pulled out).
 */
class Hid(private val activity: Activity) {

    private val usb get() = activity.getSystemService(Context.USB_SERVICE) as UsbManager
    private val main = Handler(Looper.getMainLooper())
    private val open = HashMap<String, Session>()
    private var packets: EventChannel.EventSink? = null
    private var changes: EventChannel.EventSink? = null
    private var receiver: BroadcastReceiver? = null

    private val permissionAction = "dev.muse.muse.USB_PERMISSION"

    /** What [open] is waiting on: a permission answer for this device name. */
    private val pending = HashMap<String, MethodChannel.Result>()

    val packetHandler = object : EventChannel.StreamHandler {
        override fun onListen(arguments: Any?, events: EventChannel.EventSink?) { packets = events }
        override fun onCancel(arguments: Any?) { packets = null }
    }

    val changeHandler = object : EventChannel.StreamHandler {
        override fun onListen(arguments: Any?, events: EventChannel.EventSink?) { changes = events; listen() }
        override fun onCancel(arguments: Any?) { changes = null }
    }

    fun handle(call: io.flutter.plugin.common.MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "list" -> result.success(list())
            "open" -> open(call.argument<String>("id")!!, result)
            "write" -> {
                val id = call.argument<String>("id")!!
                val bytes = call.argument<ByteArray>("bytes")!!
                val s = open[id]
                if (s == null) result.error("closed", "$id is not open", null)
                else { s.write(bytes); result.success(null) }
            }
            "close" -> { open.remove(call.argument<String>("id")!!)?.close(); result.success(null) }
            else -> result.notImplemented()
        }
    }

    /** Every attached USB device with a HID interface. */
    private fun list(): List<Map<String, Any?>> = usb.deviceList.values
        .filter { hidInterface(it) != null }
        .map {
            mapOf(
                "id" to it.deviceName,
                "name" to (it.productName ?: it.deviceName),
                "vid" to it.vendorId,
                "pid" to it.productId,
            )
        }

    private fun hidInterface(d: UsbDevice): UsbInterface? {
        for (i in 0 until d.interfaceCount) {
            val iface = d.getInterface(i)
            if (iface.interfaceClass == UsbConstants.USB_CLASS_HID) return iface
        }
        return null
    }

    private fun open(id: String, result: MethodChannel.Result) {
        if (open.containsKey(id)) { result.success(true); return }
        val device = usb.deviceList[id] ?: run { result.success(false); return }
        if (!usb.hasPermission(device)) {
            // Ask, and finish in the receiver. Plugging the console in while the app's
            // usb_devices.xml names it gets the permission without this dialog.
            listen()
            pending[id] = result
            val flags = if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0
            val intent = Intent(permissionAction).setPackage(activity.packageName)
            usb.requestPermission(device, PendingIntent.getBroadcast(activity, 0, intent, flags))
            return
        }
        result.success(start(device))
    }

    private fun start(device: UsbDevice): Boolean {
        val iface = hidInterface(device) ?: return false
        val conn = usb.openDevice(device) ?: return false
        if (!conn.claimInterface(iface, true)) { conn.close(); return false }
        var input: UsbEndpoint? = null
        var output: UsbEndpoint? = null
        for (e in 0 until iface.endpointCount) {
            val ep = iface.getEndpoint(e)
            if (ep.type != UsbConstants.USB_ENDPOINT_XFER_INT) continue
            if (ep.direction == UsbConstants.USB_DIR_IN) input = ep else output = ep
        }
        if (input == null) { conn.releaseInterface(iface); conn.close(); return false }
        val s = Session(device.deviceName, conn, iface, input, output)
        open[device.deviceName] = s
        s.start()
        return true
    }

    private fun listen() {
        if (receiver != null) return
        val r = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                when (intent.action) {
                    permissionAction -> {
                        val device: UsbDevice? = intent.getParcelableExtra(UsbManager.EXTRA_DEVICE)
                        val granted = intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)
                        val id = device?.deviceName ?: return
                        val result = pending.remove(id) ?: return
                        result.success(granted && start(device))
                    }
                    UsbManager.ACTION_USB_DEVICE_ATTACHED, UsbManager.ACTION_USB_DEVICE_DETACHED -> {
                        val device: UsbDevice? = intent.getParcelableExtra(UsbManager.EXTRA_DEVICE)
                        if (intent.action == UsbManager.ACTION_USB_DEVICE_DETACHED && device != null) {
                            open.remove(device.deviceName)?.close()
                        }
                        changes?.success(null)
                    }
                }
            }
        }
        val filter = IntentFilter().apply {
            addAction(permissionAction)
            addAction(UsbManager.ACTION_USB_DEVICE_ATTACHED)
            addAction(UsbManager.ACTION_USB_DEVICE_DETACHED)
        }
        if (Build.VERSION.SDK_INT >= 33) {
            activity.registerReceiver(r, filter, Context.RECEIVER_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            activity.registerReceiver(r, filter)
        }
        receiver = r
    }

    fun stop() {
        for (s in open.values) s.close()
        open.clear()
        receiver?.let { activity.unregisterReceiver(it) }
        receiver = null
    }

    /** One open console: a thread on its interrupt endpoint. */
    private inner class Session(
        val id: String,
        val conn: UsbDeviceConnection,
        val iface: UsbInterface,
        val input: UsbEndpoint,
        val output: UsbEndpoint?,
    ) {
        @Volatile private var running = true
        private var thread: Thread? = null

        fun start() {
            thread = Thread({
                val buf = ByteArray(input.maxPacketSize.coerceAtLeast(64))
                while (running) {
                    val n = conn.bulkTransfer(input, buf, buf.size, 500)
                    if (n < 0) continue   // a timeout, or the device going: the detach says which
                    if (n == 0) continue
                    val copy = buf.copyOf(n)
                    main.post { packets?.success(mapOf("id" to id, "bytes" to copy)) }
                }
            }, "hid-$id").apply { isDaemon = true; start() }
        }

        /**
         * An output report. By the interrupt OUT endpoint where there is one; by a
         * SET_REPORT on the control endpoint otherwise, which is how the RMX takes its
         * lights: report id in the request, the data without it.
         */
        fun write(bytes: ByteArray) {
            if (bytes.isEmpty()) return
            val out = output
            if (out != null) {
                conn.bulkTransfer(out, bytes, bytes.size, 100)
                return
            }
            val reportId = bytes[0].toInt() and 0xFF
            val data = bytes.copyOfRange(1, bytes.size)
            conn.controlTransfer(
                0x21,                      // host to device, class, interface
                0x09,                      // SET_REPORT
                0x0200 or reportId,        // output report, id
                iface.id,
                data, data.size, 100,
            )
        }

        fun close() {
            running = false
            try { conn.releaseInterface(iface) } catch (_: Exception) {}
            try { conn.close() } catch (_: Exception) {}
        }
    }
}
