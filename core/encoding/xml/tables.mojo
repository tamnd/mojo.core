"""The three tables Go keeps in `encoding/xml`, and nothing else.

Generated from Go's own source by `tools/gen/xmltables.py`. Do not edit: change
the generator and run `pixi run gen`. `pixi run generated-check` fails on a
diff.

Two of these decide whether a run of characters is an XML name. They are
Appendix B of the 1998 specification, which lists the letters of the languages
that had been written down by then and has not been touched since, so a name
this refuses is a name Go refuses and a name the specification refuses. XML
1.0 fifth edition replaced the appendix with a much shorter rule that allows
far more, and neither Go nor this follows it, because a document that parses
here and not in Go would be worse than a document neither accepts.

The third is the HTML entity list. It is not used unless a caller asks for it
by assigning `html_entity()` to `Decoder.entity`, which is the second half of
the two line recipe for reading HTML that `Decoder.strict` documents.

A range is packed into one word as `lo | hi << 21 | stride << 42`, which is
what `core/unicode/data.mojo` does and is described there. XML's tables stop at
U+D7A3, so the twenty one bit fields are wider than anything in them.
"""


comptime _RANGES: Array[UInt64, 302] = [
    0x000004000740003A,
    0x000004000B400041,
    0x000004000BE0005F,
    0x000004000F400061,
    0x000004001AC000C0,
    0x000004001EC000D8,
    0x000004001FE000F8,
    0x0000040026200100,
    0x0000040027C00134,
    0x0000040029000141,
    0x000004002FC0014A,
    0x0000040038600180,
    0x000004003E0001CD,
    0x000004003EA001F4,
    0x0000040042E001FA,
    0x0000040055000250,
    0x00000400582002BB,
    0x0000040070C00386,
    0x0000040071400388,
    0x000004007180038C,
    0x000004007420038E,
    0x0000040079C003A3,
    0x000004007AC003D0,
    0x000008007C0003DA,
    0x000004007E6003E2,
    0x0000040081800401,
    0x0000040089E0040E,
    0x000004008B800451,
    0x000004009020045E,
    0x0000040098800490,
    0x00000400990004C7,
    0x00000400998004CB,
    0x000004009D6004D0,
    0x000004009EA004EE,
    0x000004009F2004F8,
    0x00000400AAC00531,
    0x00000400AB200559,
    0x00000400B0C00561,
    0x00000400BD4005D0,
    0x00000400BE4005F0,
    0x00000400C7400621,
    0x00000400C9400641,
    0x00000400D6E00671,
    0x00000400D7C006BA,
    0x00000400D9C006C0,
    0x00000400DA6006D0,
    0x00000400DAA006D5,
    0x00000400DCC006E5,
    0x0000040127200905,
    0x0000040127A0093D,
    0x000004012C200958,
    0x0000040131800985,
    0x000004013200098F,
    0x0000040135000993,
    0x00000401360009AA,
    0x00000401364009B2,
    0x00000401372009B6,
    0x000004013BA009DC,
    0x000004013C2009DF,
    0x000004013E2009F0,
    0x0000040141400A05,
    0x0000040142000A0F,
    0x0000040145000A13,
    0x0000040146000A2A,
    0x0000040146600A32,
    0x0000040146C00A35,
    0x0000040147200A38,
    0x000004014B800A59,
    0x000004014BC00A5E,
    0x000004014E800A72,
    0x0000040151600A85,
    0x0000040151A00A8D,
    0x0000040152200A8F,
    0x0000040155000A93,
    0x0000040156000AAA,
    0x0000040156600AB2,
    0x0000040157200AB5,
    0x00008C015C000ABD,
    0x0000040161800B05,
    0x0000040162000B0F,
    0x0000040165000B13,
    0x0000040166000B2A,
    0x0000040166600B32,
    0x0000040167200B36,
    0x0000040167A00B3D,
    0x000004016BA00B5C,
    0x000004016C200B5F,
    0x0000040171400B85,
    0x0000040172000B8E,
    0x0000040172A00B92,
    0x0000040173400B99,
    0x0000040173800B9C,
    0x0000040173E00B9E,
    0x0000040174800BA3,
    0x0000040175400BA8,
    0x0000040176A00BAE,
    0x0000040177200BB7,
    0x0000040181800C05,
    0x0000040182000C0E,
    0x0000040185000C12,
    0x0000040186600C2A,
    0x0000040187200C35,
    0x000004018C200C60,
    0x0000040191800C85,
    0x0000040192000C8E,
    0x0000040195000C92,
    0x0000040196600CAA,
    0x0000040197200CB5,
    0x000004019BC00CDE,
    0x000004019C200CE0,
    0x00000401A1800D05,
    0x00000401A2000D0E,
    0x00000401A5000D12,
    0x00000401A7200D2A,
    0x00000401AC200D60,
    0x00000401C5C00E01,
    0x00000401C6000E30,
    0x00000401C6600E32,
    0x00000401C8A00E40,
    0x00000401D0400E81,
    0x00000401D0800E84,
    0x00000401D1000E87,
    0x00000C01D1A00E8A,
    0x00000401D2E00E94,
    0x00000401D3E00E99,
    0x00000401D4600EA1,
    0x00000801D4E00EA5,
    0x00000401D5600EAA,
    0x00000401D5C00EAD,
    0x00000401D6000EB0,
    0x00000401D6600EB2,
    0x00000401D7A00EBD,
    0x00000401D8800EC0,
    0x00000401E8E00F40,
    0x00000401ED200F49,
    0x0000040218A010A0,
    0x000004021EC010D0,
    0x0000040220001100,
    0x0000040220601102,
    0x0000040220E01105,
    0x0000040221201109,
    0x000004022180110B,
    0x000004022240110E,
    0x000008022800113C,
    0x000008022A00114C,
    0x000004022AA01154,
    0x000004022B201159,
    0x000004022C20115F,
    0x000008022D201163,
    0x000004022DC0116D,
    0x000004022E601172,
    0x0000A40233C01175,
    0x00000C02356011A8,
    0x0000040235E011AE,
    0x00000402370011B7,
    0x00000402374011BA,
    0x00000402384011BC,
    0x000014023E0011EB,
    0x000004023F2011F9,
    0x00000403D3601E00,
    0x00000403DF201EA0,
    0x00000403E2A01F00,
    0x00000403E3A01F18,
    0x00000403E8A01F20,
    0x00000403E9A01F48,
    0x00000403EAE01F50,
    0x00000803EB601F59,
    0x00000403EBA01F5D,
    0x00000403EFA01F5F,
    0x00000403F6801F80,
    0x00000403F7801FB6,
    0x00000403F7C01FBE,
    0x00000403F8801FC2,
    0x00000403F9801FC6,
    0x00000403FA601FD0,
    0x00000403FB601FD6,
    0x00000403FD801FE0,
    0x00000403FE801FF2,
    0x00000403FF801FF6,
    0x0000040424C02126,
    0x000004042560212A,
    0x0000040425C0212E,
    0x0000040430402180,
    0x0000040600E03007,
    0x0000040605203021,
    0x0000040612803041,
    0x000004061F4030A1,
    0x0000040625803105,
    0x00000413F4A04E00,
    0x0000041AF460AC00,
    0x0000040005C0002D,
    0x0000040007200030,
    0x0000040016E000B7,
    0x000004005A2002D0,
    0x0000040068A00300,
    0x000004006C200360,
    0x0000040070E00387,
    0x0000040090C00483,
    0x00000400B4200591,
    0x00000400B72005A3,
    0x00000400B7A005BB,
    0x00000400B7E005BF,
    0x00000400B84005C1,
    0x0001F000C80005C4,
    0x00000400CA40064B,
    0x00000400CD200660,
    0x00000400CE000670,
    0x00000400DB8006D6,
    0x00000400DBE006DD,
    0x00000400DC8006E0,
    0x00000400DD0006E7,
    0x00000400DDA006EA,
    0x00000400DF2006F0,
    0x0000040120600901,
    0x000004012780093C,
    0x000004012980093E,
    0x0000040129A0094D,
    0x000004012A800951,
    0x000004012C600962,
    0x000004012DE00966,
    0x0000040130600981,
    0x00000401378009BC,
    0x0000040137E009BE,
    0x00000401388009C0,
    0x00000401390009C7,
    0x0000040139A009CB,
    0x000004013AE009D7,
    0x000004013C6009E2,
    0x000004013DE009E6,
    0x0000E80147800A02,
    0x0000040147E00A3E,
    0x0000040148400A40,
    0x0000040149000A47,
    0x0000040149A00A4B,
    0x000004014DE00A66,
    0x000004014E200A70,
    0x0000040150600A81,
    0x0000040157800ABC,
    0x0000040158A00ABE,
    0x0000040159200AC7,
    0x0000040159A00ACB,
    0x000004015DE00AE6,
    0x0000040160600B01,
    0x0000040167800B3C,
    0x0000040168600B3E,
    0x0000040169000B47,
    0x0000040169A00B4B,
    0x000004016AE00B56,
    0x000004016DE00B66,
    0x0000040170600B82,
    0x0000040178400BBE,
    0x0000040179000BC6,
    0x0000040179A00BCA,
    0x000004017AE00BD7,
    0x000004017DE00BE7,
    0x0000040180600C01,
    0x0000040188800C3E,
    0x0000040189000C46,
    0x0000040189A00C4A,
    0x000004018AC00C55,
    0x000004018DE00C66,
    0x0000040190600C82,
    0x0000040198800CBE,
    0x0000040199000CC6,
    0x0000040199A00CCA,
    0x000004019AC00CD5,
    0x000004019DE00CE6,
    0x00000401A0600D02,
    0x00000401A8600D3E,
    0x00000401A9000D46,
    0x00000401A9A00D4A,
    0x00000401AAE00D57,
    0x00000401ADE00D66,
    0x00000401C6200E31,
    0x00000401C7400E34,
    0x00000401C8C00E46,
    0x00000401C9C00E47,
    0x00000401CB200E50,
    0x00000401D6200EB1,
    0x00000401D7200EB4,
    0x00000401D7800EBB,
    0x00000401D8C00EC6,
    0x00000401D9A00EC8,
    0x00000401DB200ED0,
    0x00000401E3200F18,
    0x00000401E5200F20,
    0x00000801E7200F35,
    0x00000401E7E00F3E,
    0x00000401F0800F71,
    0x00000401F1600F86,
    0x00000401F2A00F90,
    0x00000401F2E00F97,
    0x00000401F5A00F99,
    0x00000401F6E00FB1,
    0x00000401F7200FB9,
    0x000004041B8020D0,
    0x003C900600A020E1,
    0x0000040605E0302A,
    0x0000040606A03031,
    0x0000040613403099,
    0x0000040613C0309D,
    0x000004061FC030FC,
]
"""Every range in the two tables, `first` first and `second` after it."""

comptime _SECOND_AT = 190
"""Where `second` starts, which is also how long `first` is."""

comptime _SECOND_LEN = 112
"""How many ranges `second` has."""


def _in(r: Int32, at: Int, count: Int) -> Bool:
    """Whether `r` is in `count` ranges starting at `at`.

    Binary search, the same shape as `core.unicode.letter`'s, because the rows
    are sorted and there are a hundred and ninety of them in the first table. A
    stride of one is the common case and is answered without the division.
    """
    var lo = 0
    var hi = count
    while lo < hi:
        var mid = lo + (hi - lo) // 2
        var word = materialize[_RANGES]()[at + mid]
        var start = UInt32(word & 0x1FFFFF)
        var end = UInt32((word >> 21) & 0x1FFFFF)
        if UInt32(r) < start:
            hi = mid
            continue
        if UInt32(r) > end:
            lo = mid + 1
            continue
        var stride = UInt32((word >> 42) & 0x3FFFFF)
        if stride == 1:
            return True
        return (UInt32(r) - start) % stride == 0
    return False


def is_name_first(r: Int32) -> Bool:
    """Whether `r` may start an XML name. Go's `unicode.Is(first, r)`.

    That is a letter, an underscore or a colon, where letter means what
    Appendix B says it means.
    """
    return _in(r, 0, _SECOND_AT)


def is_name_rune(r: Int32) -> Bool:
    """Whether `r` may appear after the first character of an XML name.

    Go asks `unicode.Is(first, c) || unicode.Is(second, c)` and this asks the
    same two questions in the same order. `second` is the digits, the combining
    marks and the extenders, which may not start a name.
    """
    return is_name_first(r) or _in(r, _SECOND_AT, _SECOND_LEN)


def html_auto_close() -> List[String]:
    """The HTML elements that close themselves. Go's `HTMLAutoClose`.

    Go's is a package level slice a caller could sort or append to by accident
    and every other caller would then be reading a different list. This is a
    function returning a fresh one, which is what `core.encoding.base64` does
    with Go's four `Encoding` variables and for the same reason.
    """
    var out = List[String]()
    out.append("basefont")
    out.append("br")
    out.append("area")
    out.append("link")
    out.append("img")
    out.append("param")
    out.append("hr")
    out.append("input")
    out.append("col")
    out.append("frame")
    out.append("isindex")
    out.append("base")
    out.append("meta")
    return out^


def html_entity() -> Dict[String, String]:
    """The HTML entity names and what they stand for. Go's `HTMLEntity`.

    Two hundred and fifty two names, each one a single code point, which is
    what the HTML 4 entity page has and is why nothing here can expand to
    anything that could be expanded again. A caller assigns this to
    `Decoder.entity` and unsets `Decoder.strict`, and those two lines are the
    whole of reading HTML with this package.

    Built fresh on every call, for the reason `html_auto_close` gives.
    """
    var out = Dict[String, String]()
    out["nbsp"] = chr(0x00A0)
    out["iexcl"] = chr(0x00A1)
    out["cent"] = chr(0x00A2)
    out["pound"] = chr(0x00A3)
    out["curren"] = chr(0x00A4)
    out["yen"] = chr(0x00A5)
    out["brvbar"] = chr(0x00A6)
    out["sect"] = chr(0x00A7)
    out["uml"] = chr(0x00A8)
    out["copy"] = chr(0x00A9)
    out["ordf"] = chr(0x00AA)
    out["laquo"] = chr(0x00AB)
    out["not"] = chr(0x00AC)
    out["shy"] = chr(0x00AD)
    out["reg"] = chr(0x00AE)
    out["macr"] = chr(0x00AF)
    out["deg"] = chr(0x00B0)
    out["plusmn"] = chr(0x00B1)
    out["sup2"] = chr(0x00B2)
    out["sup3"] = chr(0x00B3)
    out["acute"] = chr(0x00B4)
    out["micro"] = chr(0x00B5)
    out["para"] = chr(0x00B6)
    out["middot"] = chr(0x00B7)
    out["cedil"] = chr(0x00B8)
    out["sup1"] = chr(0x00B9)
    out["ordm"] = chr(0x00BA)
    out["raquo"] = chr(0x00BB)
    out["frac14"] = chr(0x00BC)
    out["frac12"] = chr(0x00BD)
    out["frac34"] = chr(0x00BE)
    out["iquest"] = chr(0x00BF)
    out["Agrave"] = chr(0x00C0)
    out["Aacute"] = chr(0x00C1)
    out["Acirc"] = chr(0x00C2)
    out["Atilde"] = chr(0x00C3)
    out["Auml"] = chr(0x00C4)
    out["Aring"] = chr(0x00C5)
    out["AElig"] = chr(0x00C6)
    out["Ccedil"] = chr(0x00C7)
    out["Egrave"] = chr(0x00C8)
    out["Eacute"] = chr(0x00C9)
    out["Ecirc"] = chr(0x00CA)
    out["Euml"] = chr(0x00CB)
    out["Igrave"] = chr(0x00CC)
    out["Iacute"] = chr(0x00CD)
    out["Icirc"] = chr(0x00CE)
    out["Iuml"] = chr(0x00CF)
    out["ETH"] = chr(0x00D0)
    out["Ntilde"] = chr(0x00D1)
    out["Ograve"] = chr(0x00D2)
    out["Oacute"] = chr(0x00D3)
    out["Ocirc"] = chr(0x00D4)
    out["Otilde"] = chr(0x00D5)
    out["Ouml"] = chr(0x00D6)
    out["times"] = chr(0x00D7)
    out["Oslash"] = chr(0x00D8)
    out["Ugrave"] = chr(0x00D9)
    out["Uacute"] = chr(0x00DA)
    out["Ucirc"] = chr(0x00DB)
    out["Uuml"] = chr(0x00DC)
    out["Yacute"] = chr(0x00DD)
    out["THORN"] = chr(0x00DE)
    out["szlig"] = chr(0x00DF)
    out["agrave"] = chr(0x00E0)
    out["aacute"] = chr(0x00E1)
    out["acirc"] = chr(0x00E2)
    out["atilde"] = chr(0x00E3)
    out["auml"] = chr(0x00E4)
    out["aring"] = chr(0x00E5)
    out["aelig"] = chr(0x00E6)
    out["ccedil"] = chr(0x00E7)
    out["egrave"] = chr(0x00E8)
    out["eacute"] = chr(0x00E9)
    out["ecirc"] = chr(0x00EA)
    out["euml"] = chr(0x00EB)
    out["igrave"] = chr(0x00EC)
    out["iacute"] = chr(0x00ED)
    out["icirc"] = chr(0x00EE)
    out["iuml"] = chr(0x00EF)
    out["eth"] = chr(0x00F0)
    out["ntilde"] = chr(0x00F1)
    out["ograve"] = chr(0x00F2)
    out["oacute"] = chr(0x00F3)
    out["ocirc"] = chr(0x00F4)
    out["otilde"] = chr(0x00F5)
    out["ouml"] = chr(0x00F6)
    out["divide"] = chr(0x00F7)
    out["oslash"] = chr(0x00F8)
    out["ugrave"] = chr(0x00F9)
    out["uacute"] = chr(0x00FA)
    out["ucirc"] = chr(0x00FB)
    out["uuml"] = chr(0x00FC)
    out["yacute"] = chr(0x00FD)
    out["thorn"] = chr(0x00FE)
    out["yuml"] = chr(0x00FF)
    out["fnof"] = chr(0x0192)
    out["Alpha"] = chr(0x0391)
    out["Beta"] = chr(0x0392)
    out["Gamma"] = chr(0x0393)
    out["Delta"] = chr(0x0394)
    out["Epsilon"] = chr(0x0395)
    out["Zeta"] = chr(0x0396)
    out["Eta"] = chr(0x0397)
    out["Theta"] = chr(0x0398)
    out["Iota"] = chr(0x0399)
    out["Kappa"] = chr(0x039A)
    out["Lambda"] = chr(0x039B)
    out["Mu"] = chr(0x039C)
    out["Nu"] = chr(0x039D)
    out["Xi"] = chr(0x039E)
    out["Omicron"] = chr(0x039F)
    out["Pi"] = chr(0x03A0)
    out["Rho"] = chr(0x03A1)
    out["Sigma"] = chr(0x03A3)
    out["Tau"] = chr(0x03A4)
    out["Upsilon"] = chr(0x03A5)
    out["Phi"] = chr(0x03A6)
    out["Chi"] = chr(0x03A7)
    out["Psi"] = chr(0x03A8)
    out["Omega"] = chr(0x03A9)
    out["alpha"] = chr(0x03B1)
    out["beta"] = chr(0x03B2)
    out["gamma"] = chr(0x03B3)
    out["delta"] = chr(0x03B4)
    out["epsilon"] = chr(0x03B5)
    out["zeta"] = chr(0x03B6)
    out["eta"] = chr(0x03B7)
    out["theta"] = chr(0x03B8)
    out["iota"] = chr(0x03B9)
    out["kappa"] = chr(0x03BA)
    out["lambda"] = chr(0x03BB)
    out["mu"] = chr(0x03BC)
    out["nu"] = chr(0x03BD)
    out["xi"] = chr(0x03BE)
    out["omicron"] = chr(0x03BF)
    out["pi"] = chr(0x03C0)
    out["rho"] = chr(0x03C1)
    out["sigmaf"] = chr(0x03C2)
    out["sigma"] = chr(0x03C3)
    out["tau"] = chr(0x03C4)
    out["upsilon"] = chr(0x03C5)
    out["phi"] = chr(0x03C6)
    out["chi"] = chr(0x03C7)
    out["psi"] = chr(0x03C8)
    out["omega"] = chr(0x03C9)
    out["thetasym"] = chr(0x03D1)
    out["upsih"] = chr(0x03D2)
    out["piv"] = chr(0x03D6)
    out["bull"] = chr(0x2022)
    out["hellip"] = chr(0x2026)
    out["prime"] = chr(0x2032)
    out["Prime"] = chr(0x2033)
    out["oline"] = chr(0x203E)
    out["frasl"] = chr(0x2044)
    out["weierp"] = chr(0x2118)
    out["image"] = chr(0x2111)
    out["real"] = chr(0x211C)
    out["trade"] = chr(0x2122)
    out["alefsym"] = chr(0x2135)
    out["larr"] = chr(0x2190)
    out["uarr"] = chr(0x2191)
    out["rarr"] = chr(0x2192)
    out["darr"] = chr(0x2193)
    out["harr"] = chr(0x2194)
    out["crarr"] = chr(0x21B5)
    out["lArr"] = chr(0x21D0)
    out["uArr"] = chr(0x21D1)
    out["rArr"] = chr(0x21D2)
    out["dArr"] = chr(0x21D3)
    out["hArr"] = chr(0x21D4)
    out["forall"] = chr(0x2200)
    out["part"] = chr(0x2202)
    out["exist"] = chr(0x2203)
    out["empty"] = chr(0x2205)
    out["nabla"] = chr(0x2207)
    out["isin"] = chr(0x2208)
    out["notin"] = chr(0x2209)
    out["ni"] = chr(0x220B)
    out["prod"] = chr(0x220F)
    out["sum"] = chr(0x2211)
    out["minus"] = chr(0x2212)
    out["lowast"] = chr(0x2217)
    out["radic"] = chr(0x221A)
    out["prop"] = chr(0x221D)
    out["infin"] = chr(0x221E)
    out["ang"] = chr(0x2220)
    out["and"] = chr(0x2227)
    out["or"] = chr(0x2228)
    out["cap"] = chr(0x2229)
    out["cup"] = chr(0x222A)
    out["int"] = chr(0x222B)
    out["there4"] = chr(0x2234)
    out["sim"] = chr(0x223C)
    out["cong"] = chr(0x2245)
    out["asymp"] = chr(0x2248)
    out["ne"] = chr(0x2260)
    out["equiv"] = chr(0x2261)
    out["le"] = chr(0x2264)
    out["ge"] = chr(0x2265)
    out["sub"] = chr(0x2282)
    out["sup"] = chr(0x2283)
    out["nsub"] = chr(0x2284)
    out["sube"] = chr(0x2286)
    out["supe"] = chr(0x2287)
    out["oplus"] = chr(0x2295)
    out["otimes"] = chr(0x2297)
    out["perp"] = chr(0x22A5)
    out["sdot"] = chr(0x22C5)
    out["lceil"] = chr(0x2308)
    out["rceil"] = chr(0x2309)
    out["lfloor"] = chr(0x230A)
    out["rfloor"] = chr(0x230B)
    out["lang"] = chr(0x2329)
    out["rang"] = chr(0x232A)
    out["loz"] = chr(0x25CA)
    out["spades"] = chr(0x2660)
    out["clubs"] = chr(0x2663)
    out["hearts"] = chr(0x2665)
    out["diams"] = chr(0x2666)
    out["quot"] = chr(0x0022)
    out["amp"] = chr(0x0026)
    out["lt"] = chr(0x003C)
    out["gt"] = chr(0x003E)
    out["OElig"] = chr(0x0152)
    out["oelig"] = chr(0x0153)
    out["Scaron"] = chr(0x0160)
    out["scaron"] = chr(0x0161)
    out["Yuml"] = chr(0x0178)
    out["circ"] = chr(0x02C6)
    out["tilde"] = chr(0x02DC)
    out["ensp"] = chr(0x2002)
    out["emsp"] = chr(0x2003)
    out["thinsp"] = chr(0x2009)
    out["zwnj"] = chr(0x200C)
    out["zwj"] = chr(0x200D)
    out["lrm"] = chr(0x200E)
    out["rlm"] = chr(0x200F)
    out["ndash"] = chr(0x2013)
    out["mdash"] = chr(0x2014)
    out["lsquo"] = chr(0x2018)
    out["rsquo"] = chr(0x2019)
    out["sbquo"] = chr(0x201A)
    out["ldquo"] = chr(0x201C)
    out["rdquo"] = chr(0x201D)
    out["bdquo"] = chr(0x201E)
    out["dagger"] = chr(0x2020)
    out["Dagger"] = chr(0x2021)
    out["permil"] = chr(0x2030)
    out["lsaquo"] = chr(0x2039)
    out["rsaquo"] = chr(0x203A)
    out["euro"] = chr(0x20AC)
    return out^
