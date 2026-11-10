import Foundation

let output = """
  -------------------------------
  Hardware | supported: gsm-umts, lte
           |   current: lte
  -------------------------------
  Modes    | supported: allowed: 2g, 3g, 4g
           |   current: allowed: 4g
  -------------------------------
  Bands    | supported: 'eutran-1, eutran-3,
           |            eutran-7, ngran-78, eutran-3'
           |   current: 'eutran-3, ngran-78'
  -------------------------------
  IP       | supported: ipv4, ipv6
"""
let parsed = BandsCodec.parse(output)
assert(parsed.supported == ["eutran-1", "eutran-3", "eutran-7", "ngran-78"])
assert(parsed.current == ["eutran-3", "ngran-78"])
let any = BandsCodec.parse("  Bands | supported: eutran-1, eutran-3\n        | current: any\n  SIM | path: /somewhere")
assert(any.supported == ["eutran-1", "eutran-3"] && any.current == ["any"])
let absent = BandsCodec.parse("Hardware | supported: lte\n         | current: lte")
assert(absent.supported.isEmpty && absent.current.isEmpty)
let unknown = BandsCodec.parse("Bands | supported: unknown\n      | current: --")
assert(unknown.supported.isEmpty && unknown.current.isEmpty)
assert(BandsCodec.mmName("B3") == "eutran-3")
assert(BandsCodec.mmName("n78") == "ngran-78")
assert(BandsCodec.mmName("W1") == "utran-1")
assert(BandsCodec.mmName("eutran-7") == "eutran-7")
assert(!BandsCodec.isSafeName("eutran-3;reboot"))
print("BandsCodec: all tests passed")
