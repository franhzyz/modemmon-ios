import Foundation

/// Установка ACL (rpcd) и бэкенда терминала mmterm на роутер —
/// ровно как это делает Android-версия (assets → base64 → файл на роутере).
enum Install {
    static let aclJSON = """
    {
        "modemmon": {
            "description": "ModemMon: файлы, команды, сеть, iwinfo, wireguard",
            "read": {
                "file": {
                    "/proc/*": [ "read" ],
                    "/etc/config/*": [ "read" ],
                    "/etc/crontabs/*": [ "read" ],
                    "/etc/openwrt_release": [ "read" ],
                    "/tmp/*": [ "list", "read" ]
                },
                "ubus": {
                    "file": [ "read", "stat", "lstat" ],
                    "iwinfo": [ "devices", "info", "scan", "assoclist" ],
                    "luci.wireguard": [ "*" ],
                    "luci.amneziawg": [ "*" ]
                }
            },
            "write": {
                "file": {
                    "/bin/*": [ "exec" ],
                    "/sbin/*": [ "exec" ],
                    "/usr/bin/*": [ "exec" ],
                    "/usr/sbin/*": [ "exec" ],
                    "/etc/init.d/*": [ "exec" ],
                    "/etc/crontabs/*": [ "write" ],
                    "/etc/config/*": [ "write" ],
                    "/tmp/*": [ "write" ]
                },
                "ubus": {
                    "file": [ "exec", "write" ],
                    "network": [ "reload", "restart" ],
                    "network.interface.*": [ "up", "down", "renew" ]
                }
            }
        }
    }
    """

    static let mmtermScript = #"""
    #!/bin/sh
    # mmterm v1 — бэкенд фронтендного терминала ModemMon.
    # Ставится приложением само (assets → /usr/bin/mmterm + chmod).
    # Сессия в /tmp/.mmterm: out (вывод), pid, off (смещение поллинга),
    # cwd (настоящая текущая папка), code (код выхода; файл есть = команда завершена).
    D=/tmp/.mmterm

    init() {
    	mkdir -p "$D"
    	[ -f "$D/cwd" ] || echo "/" > "$D/cwd"
    }

    stop_quiet() {
    	PID=$(cat "$D/pid" 2>/dev/null)
    	[ -n "$PID" ] || return 0
    	for d in /proc/[0-9]*; do
    		pp=$(awk '{print $4}' "$d/stat" 2>/dev/null)
    		[ "$pp" = "$PID" ] && kill "${d#/proc/}" 2>/dev/null
    	done
    	kill "$PID" 2>/dev/null
    	rm -f "$D/pid"
    }

    start() {
    	init
    	stop_quiet
    	echo "$1" | base64 -d > "$D/cmd.sh" 2>/dev/null || { echo "start failed: base64"; return 1; }
    	CWD=$(cat "$D/cwd" 2>/dev/null)
    	[ -n "$CWD" ] || CWD="/"
    	{
    		printf 'cd "%s" 2>/dev/null || cd /\n' "$CWD"
    		cat "$D/cmd.sh"
    		printf '\n__mm_code=$?\n'
    		printf 'pwd > "%s/cwd.new" 2>/dev/null\n' "$D"
    		printf 'echo "$__mm_code" > "%s/code"\n' "$D"
    	} > "$D/job.sh"
    	rm -f "$D/out" "$D/code" "$D/off" "$D/cwd.new"
    	echo 0 > "$D/off"
    	: > "$D/out"
    	/bin/sh "$D/job.sh" > "$D/out" 2>&1 &
    	echo $! > "$D/pid"
    	echo "started $(cat "$D/pid")"
    }

    poll() {
    	init
    	[ -f "$D/cwd.new" ] && mv "$D/cwd.new" "$D/cwd"
    	if [ -f "$D/out" ]; then
    		OFF=$(cat "$D/off" 2>/dev/null)
    		[ -n "$OFF" ] || OFF=0
    		SIZE=$(wc -c < "$D/out")
    		if [ "$SIZE" -gt "$OFF" ]; then
    			tail -c +$((OFF + 1)) "$D/out"
    			echo "$SIZE" > "$D/off"
    		fi
    	fi
    	CWD=$(cat "$D/cwd" 2>/dev/null)
    	[ -n "$CWD" ] || CWD="/"
    	if [ -f "$D/code" ]; then
    		echo ""
    		echo "__MMTERM done $(cat "$D/code") cwd=$CWD"
    		return 0
    	fi
    	PID=$(cat "$D/pid" 2>/dev/null)
    	if [ -n "$PID" ] && [ -d "/proc/$PID" ]; then
    		echo ""
    		echo "__MMTERM running cwd=$CWD"
    	else
    		echo "137" > "$D/code"
    		echo ""
    		echo "__MMTERM done 137 cwd=$CWD"
    	fi
    }

    stop() {
    	init
    	stop_quiet
    	rm -f "$D/out" "$D/off" "$D/code" "$D/job.sh" "$D/cmd.sh" "$D/cwd.new"
    	echo "stopped"
    }

    case "$1" in
    	start) start "$2" ;;
    	poll) poll ;;
    	stop) stop ;;
    	check) init; echo "ok v1" ;;
    	*) echo "usage: mmterm start <b64>|poll|stop|check"; exit 1 ;;
    esac
    """#

    /// Ставит/обновляет ACL rpcd и перезапускает rpcd.
    static func installAcl(_ ubus: UbusClient) async throws {
        let b64 = Data(aclJSON.utf8).base64EncodedString()
        let r = try await ubus.fileExec(
            "echo \(b64) | base64 -d > /usr/share/rpcd/acl.d/modemmon.json && /etc/init.d/rpcd restart 2>/dev/null; sleep 1; echo done"
        )
        guard r.stdout.contains("done") else {
            throw MmError.backend("ACL не установился: \(r.stderr.isEmpty ? r.stdout : r.stderr)")
        }
    }

    /// Ставит /usr/bin/mmterm и проверяет его.
    static func installMmterm(_ ubus: UbusClient) async throws {
        let b64 = Data(mmtermScript.utf8).base64EncodedString()
        _ = try await ubus.fileExec(
            "echo \(b64) | base64 -d > /usr/bin/mmterm && chmod 755 /usr/bin/mmterm && echo installed"
        )
        let chk = try await ubus.fileExec("/usr/bin/mmterm check")
        guard chk.stdout.contains("ok") else {
            throw MmError.backend("mmterm не отвечает: \(chk.stdout.isEmpty ? chk.stderr : chk.stdout)")
        }
    }

    static func aclInstalled(_ ubus: UbusClient) async -> Bool {
        guard let r = try? await ubus.fileExec("test -f /usr/share/rpcd/acl.d/modemmon.json && echo yes || echo no") else { return false }
        return r.stdout.contains("yes")
    }

    static func mmtermInstalled(_ ubus: UbusClient) async -> Bool {
        guard let r = try? await ubus.fileExec("/usr/bin/mmterm check 2>/dev/null") else { return false }
        return r.stdout.contains("ok")
    }
}
