import Foundation

/// Демо-режим: правдоподобные данные без роутера (как DemoSource в Android-версии).
enum DemoSource {
    static func jitter(_ base: Double, _ amp: Double) -> Double {
        base + Double.random(in: -amp...amp)
    }

    static func modem() -> ModemSnapshot {
        var m = ModemSnapshot()
        m.operatorName = "MTS RUS"
        m.operatorCode = "25001"
        m.registration = "registered"
        m.rat = "LTE+NR NSA"
        m.modelName = "Quectel EM160R-GL"
        m.fwVersion = "EM160RGLAPR01A08M4G"
        m.sim.imsi = "25007********7"
        m.sim.iccid = "8970199***********3"
        m.sim.imei = "8664250*********1"

        m.lteRsrp = jitter(-92, 5)
        m.lteRsrq = jitter(-11, 2)
        m.lteSinr = jitter(18, 5)
        m.lteRssi = jitter(-68, 4)
        m.nrRsrp = jitter(-101, 6)
        m.nrRsrq = jitter(-14, 2)
        m.nrSinr = jitter(12, 6)

        m.cellId = 218_453_121
        m.earfcn = 1_300
        m.pci = 271
        m.band = "B7 + n78"
        m.supportedBands = ["B1", "B3", "B7", "B8", "B20", "B28", "B38", "B40", "B41", "n78", "n79"]
        m.activeBands = ["B7", "n78"]

        m.tempModem = jitter(46, 2)
        m.tempPa = jitter(53, 3)
        m.tempSource = "tsens"
        m.tempStatus = "ok"

        m.qualityPercent = min(100, max(0, (m.bestRsrp! + 120) / 80 * 100))
        var hist: [Double] = []
        var v = m.bestRsrp! - 6
        for _ in 0..<48 {
            v += Double.random(in: -2...2)
            v = min(-70, max(-115, v))
            hist.append(v)
        }
        m.signalHistory = hist
        m.neighbors = [
            NeighborCell(rat: "LTE", earfcn: 1300, pci: 272, rsrp: -97, rsrq: -13, band: "B7"),
            NeighborCell(rat: "LTE", earfcn: 6300, pci: 88, rsrp: -104, rsrq: -15, band: "B3"),
            NeighborCell(rat: "NR", earfcn: 633984, pci: 15, rsrp: -108, rsrq: -17, band: "n78"),
            NeighborCell(rat: "LTE", earfcn: 9210, pci: 141, rsrp: -111, rsrq: -18, band: "B20"),
        ]
        m.ussdStatus = "idle"
        return m
    }

    static func sys() -> SysOverview {
        var o = SysOverview()
        o.hostname = "medve-router"
        o.model = "MedveRouter v2 (ipq6010)"
        o.firmware = "OpenWrt 24.10.2 r28622"
        o.kernel = "6.6.73"
        o.uptime = 396_512
        o.load1 = jitter(0.42, 0.25)
        o.load5 = jitter(0.5, 0.2)
        o.load15 = jitter(0.55, 0.15)
        o.memTotalKb = 512_000
        o.memFreeKb = 268_000
        o.cpuTemp = jitter(51, 3)
        o.cores = (0..<4).map { CpuCore(id: $0, freqMhz: [1200, 1200, 1200, 1200][$0], load: jitter(22, 18)) }
        return o
    }

    static func ifaces() -> [Iface] {
        [
            Iface(name: "lan", proto: "static", device: "br-lan", up: true, uptime: 3600,
                  ips: ["192.168.2.1/24"], gateway: "", dns: ["127.0.0.1"], rxBytes: 987_654_321, txBytes: 123_456_789, metric: nil),
            Iface(name: "wwan", proto: "qmi", device: "wwan0", up: true, uptime: 86400,
                  ips: ["10.117.84.22/30"], gateway: "10.117.84.21", dns: ["10.117.0.10"], rxBytes: 87_654_321_098, txBytes: 9_876_543_210, metric: 10),
            Iface(name: "wg0", proto: "wireguard", device: "wg0", up: true, uptime: 7200,
                  ips: ["10.8.0.1/24"], gateway: "", dns: [], rxBytes: 1_234_567, txBytes: 2_345_678, metric: 20),
            Iface(name: "wan6", proto: "dhcpv6", device: "wwan0", up: false, uptime: nil,
                  ips: [], gateway: "", dns: [], rxBytes: 0, txBytes: 0, metric: nil),
        ]
    }

    static func clients() -> [WifiClient] {
        [
            WifiClient(mac: "A4:83:E7:AA:12:34", ifname: "wlan0", signal: -52, noise: -95, rxRate: 866.7, txRate: 866.7, connectedFor: 4211, hostname: "franh-phone"),
            WifiClient(mac: "5C:AA:FD:BB:56:78", ifname: "wlan0", signal: -67, noise: -96, rxRate: 433.3, txRate: 400, connectedFor: 812, hostname: "tv-samsung"),
            WifiClient(mac: "DC:A6:32:CC:9A:BC", ifname: "wlan1", signal: -74, noise: -97, rxRate: 144.4, txRate: 130, connectedFor: 9233, hostname: "raspi-cam"),
        ]
    }

    static func scan() -> [ScanResult] {
        [
            ScanResult(ssid: "HomeNet_5G", bssid: "10:13:31:AA:00:01", channel: 36, band: "5", signal: -48, width: "80 MHz", encryption: "WPA2-PSK"),
            ScanResult(ssid: "Rostelecom-AP", bssid: "10:13:31:AA:00:02", channel: 6, band: "2.4", signal: -59, width: "20 MHz", encryption: "WPA2-PSK"),
            ScanResult(ssid: "MGTS_2345", bssid: "F4:CA:E7:BB:00:03", channel: 11, band: "2.4", signal: -72, width: "20 MHz", encryption: "WPA2-PSK"),
            ScanResult(ssid: "Beeline_Free", bssid: "F4:CA:E7:BB:00:04", channel: 1, band: "2.4", signal: -81, width: "20 MHz", encryption: "OPEN"),
            ScanResult(ssid: "(скрытая)", bssid: "98:DA:C4:CC:00:05", channel: 100, band: "5", signal: -84, width: "80 MHz", encryption: "WPA3-SAE"),
        ]
    }

    static func vpn() -> [VpnInstance] {
        let p1 = VpnPeer(name: "phone", publicKey: "pQ8fK2nR…wY0=", endpoint: "5.101.84.12:51820",
                         allowedIps: "10.8.0.2/32", latestHandshake: Date().addingTimeInterval(-42),
                         rx: 1_452_312, tx: 2_881_004, keepalive: 25)
        let p2 = VpnPeer(name: "office", publicKey: "Xk71mNpQ…zR8=", endpoint: "88.201.10.44:51820",
                         allowedIps: "10.8.0.3/32", latestHandshake: Date().addingTimeInterval(-3700),
                         rx: 88_412, tx: 121_900, keepalive: 0)
        return [
            VpnInstance(name: "wg0", kind: "wg", up: true, address: "10.8.0.1/24", listenPort: 51_820, publicKey: "AA…zz=", peers: [p1, p2]),
            VpnInstance(name: "awg0", kind: "awg", up: false, address: "10.9.0.1/24", listenPort: 33_001, publicKey: "BB…yy=", peers: []),
        ]
    }

    static func routes() -> [Route] {
        [
            Route(iface: "wwan0", target: "default", gateway: "10.117.84.21", source: "10.117.84.22", metric: 10, proto: "static"),
            Route(iface: "wg0", target: "10.8.0.0/24", gateway: "wg0", source: "10.8.0.1", metric: nil, proto: "static"),
            Route(iface: "br-lan", target: "192.168.2.0/24", gateway: "br-lan", source: "192.168.2.1", metric: nil, proto: "kernel"),
        ]
    }

    static func packages() -> [Package] {
        [
            Package(name: "medvemodem", version: "1.9-r2"),
            Package(name: "kmod-usb-serial-qualcomm", version: "6.6.73-r1"),
            Package(name: "etherwake", version: "1.09-4"),
            Package(name: "amneziawg-tools", version: "1.0.20240206"),
            Package(name: "luci", version: "24.346.74218"),
            Package(name: "curl", version: "8.9.1-r1"),
            Package(name: "qmi-utils", version: "1.35.2"),
        ]
    }

    static func services() -> [ServiceStatus] {
        [
            ServiceStatus(name: "cron", enabled: true, running: true),
            ServiceStatus(name: "dnsmasq", enabled: true, running: true),
            ServiceStatus(name: "firewall", enabled: true, running: true),
            ServiceStatus(name: "medvemodem", enabled: true, running: true),
            ServiceStatus(name: "network", enabled: true, running: true),
            ServiceStatus(name: "rpcd", enabled: true, running: true),
            ServiceStatus(name: "wireguard", enabled: true, running: false),
        ]
    }

    static func processes() -> [ProcInfo] {
        [
            ProcInfo(id: 1, user: "root", command: "/sbin/procd"),
            ProcInfo(id: 812, user: "root", command: "/usr/sbin/rpcd -i /sbin/rpcd"),
            ProcInfo(id: 1101, user: "root", command: "/usr/sbin/dnsmasq -C /var/etc/dnsmasq.conf.cfg01411c"),
            ProcInfo(id: 1444, user: "root", command: "/usr/bin/medvemodem -c /etc/config/medvemodem"),
            ProcInfo(id: 1900, user: "nobody", command: "/usr/sbin/uhttpd -f -h /www"),
        ]
    }

    static func log() -> String {
        """
        Fri Nov  7 21:12:04 2026 daemon.info medvemodem[1444]: signal update: rsrp=-91 rsrq=-11 sinr=19
        Fri Nov  7 21:12:11 2026 daemon.notice netifd: wwan (1234): 204 ok, latency 41ms
        Fri Nov  7 21:12:30 2026 authpriv.info dropbear[2201]: Password auth succeeded for 'root' from 192.168.2.50:51444
        Fri Nov  7 21:13:02 2026 daemon.info dnsmasq-dhcp[1101]: DHCPACK(br-lan) 192.168.2.50 a4:83:e7:aa:12:34 franh-phone
        Fri Nov  7 21:13:44 2026 kern.info kernel: [396512.44] qmi_wwan 1-1:1.4 wwan0: rx 1.2GB tx 0.3GB
        """
    }

    static func crontab() -> String {
        "# generated by ModemMon\n0 * * * * /usr/bin/modem-telemetry push\n*/5 * * * * /usr/bin/wol-guard check\n"
    }

    static func uciNetwork() -> UciConfig {
        var cfg = UciConfig(name: "network")
        cfg.sections = [
            UciSection(name: "lan", type: "interface", anon: false, options: [
                UciOption(name: "device", value: "br-lan"),
                UciOption(name: "proto", value: "static"),
                UciOption(name: "ipaddr", value: "192.168.2.1"),
                UciOption(name: "netmask", value: "255.255.255.0"),
            ]),
            UciSection(name: "wwan", type: "interface", anon: false, options: [
                UciOption(name: "proto", value: "qmi"),
                UciOption(name: "device", value: "/dev/cdc-wdm0"),
                UciOption(name: "apn", value: "internet.mts.ru"),
                UciOption(name: "metric", value: "10"),
            ]),
            UciSection(name: "@wireguard[0]", type: "wireguard_wg0", anon: true, options: [
                UciOption(name: "public_key", value: "pQ8fK2nR…"),
                UciOption(name: "allowed_ips", value: "10.8.0.2/32"),
            ]),
        ]
        return cfg
    }

    static func backups() -> [BackupFile] {
        [
            BackupFile(path: "/tmp/modemmon-backup-1762540800.tar.gz", size: 148_233, mtime: Date().addingTimeInterval(-86400)),
            BackupFile(path: "/tmp/modemmon-backup-1762627200.tar.gz", size: 151_002, mtime: Date()),
        ]
    }

    static func leds() -> [LedInfo] {
        [
            LedInfo(name: "green:status", brightness: 255, maxBrightness: 255, trigger: "default-on"),
            LedInfo(name: "green:net", brightness: 0, maxBrightness: 255, trigger: "netdev"),
            LedInfo(name: "red:failover", brightness: 0, maxBrightness: 255, trigger: "none"),
        ]
    }

    static func smsList() -> [Sms] {
        [
            Sms(id: "3", number: "MTS", text: "Ваш баланс: 312,45 руб. Пополните счёт до 20.11.", ts: Date().addingTimeInterval(-3600), isNew: true),
            Sms(id: "2", number: "+79161234567", text: "Привет! Роутер то перезагружал?", ts: Date().addingTimeInterval(-86_400), isNew: false),
            Sms(id: "1", number: "MTS", text: "Пакет трафика израсходован на 80%.", ts: Date().addingTimeInterval(-172_800), isNew: false),
        ]
    }
}
