#
#
#           The Nim Compiler
#        (c) Copyright 2015 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

# This is the JavaScript code generator.

discard """
The JS code generator contains only 2 tricks:

Trick 1
-------
Some locations (for example 'var int') require "fat pointers" (``etyBaseIndex``)
which are pairs (array, index). The derefence operation is then 'array[index]'.
Check ``mapType`` for the details.

Trick 2
-------
It is preferable to generate '||' and '&&' if possible since that is more
idiomatic and hence should be friendlier for the JS JIT implementation. However
code like ``foo and (let bar = baz())`` cannot be translated this way. Instead
the expressions need to be transformed into statements. ``isSimpleExpr``
implements the required case distinction.
"""


import
  ast, strutils, trees, magicsys, options,
  nversion, msgs, idents, types, tables,
  ropes, math, passes, ccgutils, wordrecg, renderer,
  intsets, cgmeth, lowerings, sighashes, modulegraphs, lineinfos, rodutils,
  transf


from modulegraphs import ModuleGraph, PPassContext

type
  TJSGen = object of PPassContext
    module: PSym
    graph: ModuleGraph
    config: ConfigRef
    sigConflicts: CountTable[SigHash]

  BModule = ref TJSGen
  TJSTypeKind = enum       # necessary JS "types"
    etyNone,                  # no type
    etyNull,                  # null type
    etyProc,                  # proc type
    etyBool,                  # bool type
    etySeq,                   # Nim seq or string type
    etyInt,                   # JavaScript's int
    etyFloat,                 # JavaScript's float
    etyString,                # JavaScript's string
    etyObject,                # JavaScript's reference to an object
    etyBaseIndex              # base + index needed
  TResKind = enum
    resNone,                  # not set
    resExpr,                  # is some complex expression
    resVal,                   # is a temporary/value/l-value
    resCallee                 # expression is callee
  TCompRes = object
    kind: TResKind
    typ: TJSTypeKind
    res: Rope               # result part; index if this is an
                             # (address, index)-tuple
    address: Rope           # address of an (address, index)-tuple
    tmpLoc: Rope            # tmp var which stores the (address, index)
                            # pair to prevent multiple evals.
                            # the tmp is initialized upon evaling the
                            # address.
                            # might be nil.
                            # (see `maybeMakeTemp`)

  TBlock = object
    id: int                  # the ID of the label; positive means that it
                             # has been used (i.e. the label should be emitted)
    isLoop: bool             # whether it's a 'block' or 'while'

  PGlobals = ref object of RootObj
    typeInfo, constants, code: Rope
    forwarded: seq[PSym]
    generatedSyms: IntSet
    typeInfoGenerated: IntSet
    unique: int    # for temp identifier generation

  PProc = ref TProc
  TProc = object
    procDef: PNode
    prc: PSym
    globals, locals, body: Rope
    options: TOptions
    module: BModule
    g: PGlobals
    generatedParamCopies: IntSet
    beforeRetNeeded: bool
    unique: int    # for temp identifier generation
    blocks: seq[TBlock]
    extraIndent: int
    up: PProc     # up the call chain; required for closure support
    declaredGlobals: IntSet

template config*(p: PProc): ConfigRef = p.module.config

proc indentLine(p: PProc, r: Rope): Rope =
  result = r
  var p = p
  while true:
    for i in 0 ..< p.blocks.len + p.extraIndent:
      prepend(result, "\t".rope)
    if p.up == nil or p.up.prc != p.prc.owner:
      break
    p = p.up

template line(p: PProc, added: string) =
  add(p.body, indentLine(p, rope(added)))

template line(p: PProc, added: Rope) =
  add(p.body, indentLine(p, added))

template lineF(p: PProc, frmt: FormatStr, args: varargs[Rope]) =
  add(p.body, indentLine(p, ropes.`%`(frmt, args)))

template nested(p, body) =
  inc p.extraIndent
  body
  dec p.extraIndent

proc newGlobals(): PGlobals =
  new(result)
  result.forwarded = @[]
  result.generatedSyms = initIntSet()
  result.typeInfoGenerated = initIntSet()

proc initCompRes(r: var TCompRes) =
  r.address = nil
  r.res = nil
  r.tmpLoc = nil
  r.typ = etyNone
  r.kind = resNone

proc rdLoc(a: TCompRes): Rope {.inline.} =
  if a.typ != etyBaseIndex:
    result = a.res
  else:
    result = "$1[$2]" % [a.address, a.res]

proc newProc(globals: PGlobals, module: BModule, procDef: PNode,
             options: TOptions): PProc =
  result = PProc(
    blocks: @[],
    options: options,
    module: module,
    procDef: procDef,
    g: globals,
    extraIndent: int(procDef != nil))
  if procDef != nil: result.prc = procDef.sons[namePos].sym

proc declareGlobal(p: PProc; id: int; r: Rope) =
  if p.prc != nil and not p.declaredGlobals.containsOrIncl(id):
    p.locals.addf("global $1;$n", [r])

const
  MappedToObject = {tyObject, tyArray, tyTuple, tyOpenArray,
    tySet, tyVarargs}

proc mapType(typ: PType): TJSTypeKind =
  let t = skipTypes(typ, abstractInst)
  case t.kind
  of tyVar, tyRef, tyPtr, tyLent:
    if skipTypes(t.lastSon, abstractInst).kind in MappedToObject:
      result = etyObject
    else:
      result = etyBaseIndex
  of tyPointer:
    # treat a tyPointer like a typed pointer to an array of bytes
    result = etyBaseIndex
  of tyRange, tyDistinct, tyOrdinal, tyProxy:
    result = mapType(t.sons[0])
  of tyInt..tyInt64, tyUInt..tyUInt64, tyEnum, tyChar: result = etyInt
  of tyBool: result = etyBool
  of tyFloat..tyFloat128: result = etyFloat
  of tySet: result = etyObject # map a set to a table
  of tyString, tySequence, tyOpt: result = etySeq
  of tyObject, tyArray, tyTuple, tyOpenArray, tyVarargs, tyUncheckedArray:
    result = etyObject
  of tyNil: result = etyNull
  of tyGenericParam, tyGenericBody, tyGenericInvocation,
     tyNone, tyFromExpr, tyForward, tyEmpty,
     tyUntyped, tyTyped, tyTypeDesc, tyBuiltInTypeClass, tyCompositeTypeClass,
     tyAnd, tyOr, tyNot, tyAnything, tyVoid:
    result = etyNone
  of tyGenericInst, tyInferred, tyAlias, tyUserTypeClass, tyUserTypeClassInst,
     tySink, tyOwned:
    result = mapType(typ.lastSon)
  of tyStatic:
    if t.n != nil: result = mapType(lastSon t)
    else: result = etyNone
  of tyProc: result = etyProc
  of tyCString: result = etyString

proc mapType(p: PProc; typ: PType): TJSTypeKind =
  result = mapType(typ)

proc mangleName(m: BModule, s: PSym): Rope =
  proc validJsName(name: string): bool =
    result = true
    const reservedWords = ["abstract", "await", "boolean", "break", "byte",
      "case", "catch", "char", "class", "const", "continue", "debugger",
      "default", "delete", "do", "double", "else", "enum", "export", "extends",
      "false", "final", "finally", "float", "for", "function", "goto", "if",
      "implements", "import", "in", "instanceof", "int", "interface", "let",
      "long", "native", "new", "null", "package", "private", "protected",
      "public", "return", "short", "static", "super", "switch", "synchronized",
      "this", "throw", "throws", "transient", "true", "try", "typeof", "var",
      "void", "volatile", "while", "with", "yield"]
    case name
    of reservedWords:
      return false
    else:
      discard
    if name[0] in {'0'..'9'}: return false
    for chr in name:
      if chr notin {'A'..'Z','a'..'z','_','$','0'..'9'}:
        return false
  result = s.loc.r
  if result == nil:
    if s.kind == skField and s.name.s.validJsName:
      result = rope(s.name.s)
    elif s.kind == skTemp:
      result = rope(mangle(s.name.s))
    else:
      var x = newStringOfCap(s.name.s.len)
      var i = 0
      while i < s.name.s.len:
        let c = s.name.s[i]
        case c
        of 'A'..'Z':
          if i > 0 and s.name.s[i-1] in {'a'..'z'}:
            x.add '_'
          x.add(chr(c.ord - 'A'.ord + 'a'.ord))
        of 'a'..'z', '_', '0'..'9':
          x.add c
        else:
          x.add("HEX" & toHex(ord(c), 2))
        inc i
      result = rope(x)
    # From ES5 on reserved words can be used as object field names
    if s.kind != skField:
      if m.config.hcrOn:
        # When hot reloading is enabled, we must ensure that the names
        # of functions and types will be preserved across rebuilds:
        add(result, idOrSig(s, m.module.name.s, m.sigConflicts))
      else:
        add(result, "_")
        add(result, rope(s.id))
    s.loc.r = result

proc escapeJSString(s: string): string =
  result = newStringOfCap(s.len + s.len shr 2)
  result.add("\"")
  for c in items(s):
    case c
    of '\l': result.add("\\n")
    of '\r': result.add("\\r")
    of '\t': result.add("\\t")
    of '\b': result.add("\\b")
    of '\a': result.add("\\a")
    of '\e': result.add("\\e")
    of '\v': result.add("\\v")
    of '\\': result.add("\\\\")
    of '\"': result.add("\\\"")
    else: add(result, c)
  result.add("\"")

proc makeJSString(s: string, escapeNonAscii = true): Rope =
  if escapeNonAscii:
    result = strutils.escape(s).rope
  else:
    result = escapeJSString(s).rope

include jstypes

proc gen(p: PProc, n: PNode, r: var TCompRes)
proc genStmt(p: PProc, n: PNode)
proc genProc(oldProc: PProc, prc: PSym): Rope
proc genConstant(p: PProc, c: PSym)

proc useMagic(p: PProc, name: string) =
  if name.len == 0: return
  var s = magicsys.getCompilerProc(p.module.graph, name)
  if s != nil:
    internalAssert p.config, s.kind in {skProc, skFunc, skMethod, skConverter}
    if not p.g.generatedSyms.containsOrIncl(s.id):
      let code = genProc(p, s)
      add(p.g.constants, code)
  else:
    if p.prc != nil:
      globalError(p.config, p.prc.info, "system module needs: " & name)
    else:
      rawMessage(p.config, errGenerated, "system module needs: " & name)

proc isSimpleExpr(p: PProc; n: PNode): bool =
  # calls all the way down --> can stay expression based
  if n.kind in nkCallKinds+{nkBracketExpr, nkDotExpr, nkPar, nkTupleConstr} or
      (n.kind in {nkObjConstr, nkBracket, nkCurly}):
    for c in n:
      if not p.isSimpleExpr(c): return false
    result = true
  elif n.isAtom:
    result = true

proc getTemp(p: PProc, defineInLocals: bool = true): Rope =
  inc(p.unique)
  result = "Tmp$1" % [rope(p.unique)]
  if defineInLocals:
    add(p.locals, p.indentLine("var $1;$n" % [result]))

proc genAnd(p: PProc, a, b: PNode, r: var TCompRes) =
  assert r.kind == resNone
  var x, y: TCompRes
  if p.isSimpleExpr(a) and p.isSimpleExpr(b):
    gen(p, a, x)
    gen(p, b, y)
    r.kind = resExpr
    r.res = "($1 && $2)" % [x.rdLoc, y.rdLoc]
  else:
    r.res = p.getTemp
    r.kind = resVal
    # while a and b:
    # -->
    # while true:
    #   aa
    #   if not a: tmp = false
    #   else:
    #     bb
    #     tmp = b
    # tmp
    gen(p, a, x)
    lineF(p, "if (!$1) $2 = false; else {", [x.rdLoc, r.rdLoc])
    p.nested:
      gen(p, b, y)
      lineF(p, "$2 = $1;", [y.rdLoc, r.rdLoc])
    line(p, "}")

proc genOr(p: PProc, a, b: PNode, r: var TCompRes) =
  assert r.kind == resNone
  var x, y: TCompRes
  if p.isSimpleExpr(a) and p.isSimpleExpr(b):
    gen(p, a, x)
    gen(p, b, y)
    r.kind = resExpr
    r.res = "($1 || $2)" % [x.rdLoc, y.rdLoc]
  else:
    r.res = p.getTemp
    r.kind = resVal
    gen(p, a, x)
    lineF(p, "if ($1) $2 = true; else {", [x.rdLoc, r.rdLoc])
    p.nested:
      gen(p, b, y)
      lineF(p, "$2 = $1;", [y.rdLoc, r.rdLoc])
    line(p, "}")

type
  TMagicFrmt = array[0..1, string]
  TMagicOps = array[mAddI..mStrToStr, TMagicFrmt]

const # magic checked op; magic unchecked op;
  jsMagics: TMagicOps = [
    ["addInt", ""], # AddI
    ["subInt", ""], # SubI
    ["mulInt", ""], # MulI
    ["divInt", ""], # DivI
    ["modInt", ""], # ModI
    ["addInt", ""], # Succ
    ["subInt", ""], # Pred
    ["", ""], # AddF64
    ["", ""], # SubF64
    ["", ""], # MulF64
    ["", ""], # DivF64
    ["", ""], # ShrI
    ["", ""], # ShlI
    ["", ""], # AshrI
    ["", ""], # BitandI
    ["", ""], # BitorI
    ["", ""], # BitxorI
    ["nimMin", "nimMin"], # MinI
    ["nimMax", "nimMax"], # MaxI
    ["nimMin", "nimMin"], # MinF64
    ["nimMax", "nimMax"], # MaxF64
    ["", ""], # addU
    ["", ""], # subU
    ["", ""], # mulU
    ["", ""], # divU
    ["", ""], # modU
    ["", ""], # EqI
    ["", ""], # LeI
    ["", ""], # LtI
    ["", ""], # EqF64
    ["", ""], # LeF64
    ["", ""], # LtF64
    ["", ""], # leU
    ["", ""], # ltU
    ["", ""], # leU64
    ["", ""], # ltU64
    ["", ""], # EqEnum
    ["", ""], # LeEnum
    ["", ""], # LtEnum
    ["", ""], # EqCh
    ["", ""], # LeCh
    ["", ""], # LtCh
    ["", ""], # EqB
    ["", ""], # LeB
    ["", ""], # LtB
    ["", ""], # EqRef
    ["", ""], # EqUntracedRef
    ["", ""], # LePtr
    ["", ""], # LtPtr
    ["", ""], # Xor
    ["", ""], # EqCString
    ["", ""], # EqProc
    ["negInt", ""], # UnaryMinusI
    ["negInt64", ""], # UnaryMinusI64
    ["absInt", ""], # AbsI
    ["", ""], # Not
    ["", ""], # UnaryPlusI
    ["", ""], # BitnotI
    ["", ""], # UnaryPlusF64
    ["", ""], # UnaryMinusF64
    ["", ""], # AbsF64
    ["", ""],     # ToFloat
    ["", ""],     # ToBiggestFloat
    ["", ""], # ToInt
    ["", ""], # ToBiggestInt
    ["nimCharToStr", "nimCharToStr"],
    ["nimBoolToStr", "nimBoolToStr"],
    ["cstrToNimstr", "cstrToNimstr"],
    ["cstrToNimstr", "cstrToNimstr"],
    ["cstrToNimstr", "cstrToNimstr"],
    ["cstrToNimstr", "cstrToNimstr"],
    ["", ""]]

proc needsTemp(p: PProc; n: PNode): bool =
  # check if n contains a call to determine
  # if a temp should be made to prevent multiple evals
  if n.kind in nkCallKinds + {nkTupleConstr, nkObjConstr, nkBracket, nkCurly}:
    return true
  for c in n:
    if needsTemp(p, c):
      return true

proc maybeMakeTemp(p: PProc, n: PNode; x: TCompRes): tuple[a, tmp: Rope] =
  var
    a = x.rdLoc
    b = a
  if needsTemp(p, n):
    # if we have tmp just use it
    if x.tmpLoc != nil and (mapType(n.typ) == etyBaseIndex or n.kind in {nkHiddenDeref, nkDerefExpr}):
      b = "$1[0][$1[1]]" % [x.tmpLoc]
      (a: a, tmp: b)
    else:
      let tmp = p.getTemp
      b = tmp
      a = "($1 = $2, $1)" % [tmp, a]
      (a: a, tmp: b)
  else:
    (a: a, tmp: b)

template binaryExpr(p: PProc, n: PNode, r: var TCompRes, magic, frmt: string) =
  # $1 and $2 in the `frmt` string bind to lhs and rhs of the expr,
  # if $3 or $4 are present they will be substituted with temps for
  # lhs and rhs respectively
  var x, y: TCompRes
  useMagic(p, magic)
  gen(p, n.sons[1], x)
  gen(p, n.sons[2], y)

  var
    a, tmp = x.rdLoc
    b, tmp2 = y.rdLoc
  when "$3" in frmt: (a, tmp) = maybeMakeTemp(p, n[1], x)
  when "$4" in frmt: (b, tmp2) = maybeMakeTemp(p, n[2], y)

  r.res = frmt % [a, b, tmp, tmp2]
  r.kind = resExpr

proc unsignedTrimmerJS(size: BiggestInt): Rope =
  case size
  of 1: rope"& 0xff"
  of 2: rope"& 0xffff"
  of 4: rope">>> 0"
  else: rope""


template unsignedTrimmer(size: BiggestInt): Rope =
  size.unsignedTrimmerJS

proc binaryUintExpr(p: PProc, n: PNode, r: var TCompRes, op: string,
                    reassign = false) =
  var x, y: TCompRes
  gen(p, n.sons[1], x)
  gen(p, n.sons[2], y)
  let trimmer = unsignedTrimmer(n[1].typ.skipTypes(abstractRange).size)
  if reassign:
    let (a, tmp) = maybeMakeTemp(p, n[1], x)
    r.res = "$1 = (($5 $2 $3) $4)" % [a, rope op, y.rdLoc, trimmer, tmp]
  else:
    r.res = "(($1 $2 $3) $4)" % [x.rdLoc, rope op, y.rdLoc, trimmer]
  r.kind = resExpr

template ternaryExpr(p: PProc, n: PNode, r: var TCompRes, magic, frmt: string) =
  var x, y, z: TCompRes
  useMagic(p, magic)
  gen(p, n.sons[1], x)
  gen(p, n.sons[2], y)
  gen(p, n.sons[3], z)
  r.res = frmt % [x.rdLoc, y.rdLoc, z.rdLoc]
  r.kind = resExpr

template unaryExpr(p: PProc, n: PNode, r: var TCompRes, magic, frmt: string) =
  # $1 binds to n[1], if $2 is present it will be substituted to a tmp of $1
  useMagic(p, magic)
  gen(p, n.sons[1], r)
  var a, tmp = r.rdLoc
  if "$2" in frmt: (a, tmp) = maybeMakeTemp(p, n[1], r)
  r.res = frmt % [a, tmp]
  r.kind = resExpr

proc arithAux(p: PProc, n: PNode, r: var TCompRes, op: TMagic) =
  var
    x, y: TCompRes
    xLoc,yLoc: Rope
  let i = ord(optOverflowCheck notin p.options)
  useMagic(p, jsMagics[op][i])
  if sonsLen(n) > 2:
    gen(p, n.sons[1], x)
    gen(p, n.sons[2], y)
    xLoc = x.rdLoc
    yLoc = y.rdLoc
  else:
    gen(p, n.sons[1], r)
    xLoc = r.rdLoc

  template applyFormat(frmtA, frmtB: string) =
    if i == 0:
      r.res = frmtA % [xLoc, yLoc]
    else:
      r.res = frmtB % [xLoc, yLoc]

  case op:
  of mAddI: applyFormat("addInt($1, $2)", "($1 + $2)")
  of mSubI: applyFormat("subInt($1, $2)", "($1 - $2)")
  of mMulI: applyFormat("mulInt($1, $2)", "($1 * $2)")
  of mDivI: applyFormat("divInt($1, $2)", "Math.trunc($1 / $2)")
  of mModI: applyFormat("modInt($1, $2)", "Math.trunc($1 % $2)")
  of mSucc: applyFormat("addInt($1, $2)", "($1 + $2)")
  of mPred: applyFormat("subInt($1, $2)", "($1 - $2)")
  of mAddF64: applyFormat("($1 + $2)", "($1 + $2)")
  of mSubF64: applyFormat("($1 - $2)", "($1 - $2)")
  of mMulF64: applyFormat("($1 * $2)", "($1 * $2)")
  of mDivF64: applyFormat("($1 / $2)", "($1 / $2)")
  of mShrI: applyFormat("", "")
  of mShlI: applyFormat("($1 << $2)", "($1 << $2)")
  of mAshrI: applyFormat("($1 >> $2)", "($1 >> $2)")
  of mBitandI: applyFormat("($1 & $2)", "($1 & $2)")
  of mBitorI: applyFormat("($1 | $2)", "($1 | $2)")
  of mBitxorI: applyFormat("($1 ^ $2)", "($1 ^ $2)")
  of mMinI: applyFormat("nimMin($1, $2)", "nimMin($1, $2)")
  of mMaxI: applyFormat("nimMax($1, $2)", "nimMax($1, $2)")
  of mMinF64: applyFormat("nimMin($1, $2)", "nimMin($1, $2)")
  of mMaxF64: applyFormat("nimMax($1, $2)", "nimMax($1, $2)")
  of mAddU: applyFormat("", "")
  of mSubU: applyFormat("", "")
  of mMulU: applyFormat("", "")
  of mDivU: applyFormat("", "")
  of mModU: applyFormat("($1 % $2)", "($1 % $2)")
  of mEqI: applyFormat("($1 == $2)", "($1 == $2)")
  of mLeI: applyFormat("($1 <= $2)", "($1 <= $2)")
  of mLtI: applyFormat("($1 < $2)", "($1 < $2)")
  of mEqF64: applyFormat("($1 == $2)", "($1 == $2)")
  of mLeF64: applyFormat("($1 <= $2)", "($1 <= $2)")
  of mLtF64: applyFormat("($1 < $2)", "($1 < $2)")
  of mLeU: applyFormat("($1 <= $2)", "($1 <= $2)")
  of mLtU: applyFormat("($1 < $2)", "($1 < $2)")
  of mLeU64: applyFormat("($1 <= $2)", "($1 <= $2)")
  of mLtU64: applyFormat("($1 < $2)", "($1 < $2)")
  of mEqEnum: applyFormat("($1 == $2)", "($1 == $2)")
  of mLeEnum: applyFormat("($1 <= $2)", "($1 <= $2)")
  of mLtEnum: applyFormat("($1 < $2)", "($1 < $2)")
  of mEqCh: applyFormat("($1 == $2)", "($1 == $2)")
  of mLeCh: applyFormat("($1 <= $2)", "($1 <= $2)")
  of mLtCh: applyFormat("($1 < $2)", "($1 < $2)")
  of mEqB: applyFormat("($1 == $2)", "($1 == $2)")
  of mLeB: applyFormat("($1 <= $2)", "($1 <= $2)")
  of mLtB: applyFormat("($1 < $2)", "($1 < $2)")
  of mEqRef: applyFormat("($1 == $2)", "($1 == $2)")
  of mEqUntracedRef: applyFormat("($1 == $2)", "($1 == $2)")
  of mLePtr: applyFormat("($1 <= $2)", "($1 <= $2)")
  of mLtPtr: applyFormat("($1 < $2)", "($1 < $2)")
  of mXor: applyFormat("($1 != $2)", "($1 != $2)")
  of mEqCString: applyFormat("($1 == $2)", "($1 == $2)")
  of mEqProc: applyFormat("($1 == $2)", "($1 == $2)")
  of mUnaryMinusI: applyFormat("negInt($1)", "-($1)")
  of mUnaryMinusI64: applyFormat("negInt64($1)", "-($1)")
  of mAbsI: applyFormat("absInt($1)", "Math.abs($1)")
  of mNot: applyFormat("!($1)", "!($1)")
  of mUnaryPlusI: applyFormat("+($1)", "+($1)")
  of mBitnotI: applyFormat("~($1)", "~($1)")
  of mUnaryPlusF64: applyFormat("+($1)", "+($1)")
  of mUnaryMinusF64: applyFormat("-($1)", "-($1)")
  of mAbsF64: applyFormat("Math.abs($1)", "Math.abs($1)")
  of mToFloat: applyFormat("$1", "$1")
  of mToBiggestFloat: applyFormat("$1", "$1")
  of mToInt: applyFormat("Math.trunc($1)", "Math.trunc($1)")
  of mToBiggestInt: applyFormat("Math.trunc($1)", "Math.trunc($1)")
  of mCharToStr: applyFormat("nimCharToStr($1)", "nimCharToStr($1)")
  of mBoolToStr: applyFormat("nimBoolToStr($1)", "nimBoolToStr($1)")
  of mIntToStr: applyFormat("cstrToNimstr(($1)+\"\")", "cstrToNimstr(($1)+\"\")")
  of mInt64ToStr: applyFormat("cstrToNimstr(($1)+\"\")", "cstrToNimstr(($1)+\"\")")
  of mFloatToStr: applyFormat("cstrToNimstr(($1)+\"\")", "cstrToNimstr(($1)+\"\")")
  of mCStrToStr: applyFormat("cstrToNimstr($1)", "cstrToNimstr($1)")
  of mStrToStr, mUnown: applyFormat("$1", "$1")
  else:
    assert false, $op

proc arith(p: PProc, n: PNode, r: var TCompRes, op: TMagic) =
  case op
  of mAddU: binaryUintExpr(p, n, r, "+")
  of mSubU: binaryUintExpr(p, n, r, "-")
  of mMulU: binaryUintExpr(p, n, r, "*")
  of mDivU: binaryUintExpr(p, n, r, "/")
  of mDivI:
    arithAux(p, n, r, op)
  of mModI:
    arithAux(p, n, r, op)
  of mShrI:
    var x, y: TCompRes
    gen(p, n.sons[1], x)
    gen(p, n.sons[2], y)
    let trimmer = unsignedTrimmer(n[1].typ.skipTypes(abstractRange).size)
    r.res = "(($1 $2) >>> $3)" % [x.rdLoc, trimmer, y.rdLoc]
  of mCharToStr, mBoolToStr, mIntToStr, mInt64ToStr, mFloatToStr,
      mCStrToStr, mStrToStr, mEnumToStr:
    arithAux(p, n, r, op)
  of mEqRef, mEqUntracedRef:
    if mapType(n[1].typ) != etyBaseIndex:
      arithAux(p, n, r, op)
    else:
      var x, y: TCompRes
      gen(p, n[1], x)
      gen(p, n[2], y)
      r.res = "($# == $# && $# == $#)" % [x.address, y.address, x.res, y.res]
  else:
    arithAux(p, n, r, op)
  r.kind = resExpr

proc hasFrameInfo(p: PProc): bool =
  ({optLineTrace, optStackTrace} * p.options == {optLineTrace, optStackTrace}) and
      ((p.prc == nil) or not (sfPure in p.prc.flags))

proc genLineDir(p: PProc, n: PNode) =
  let line = toLinenumber(n.info)
  if optLineDir in p.options:
    lineF(p, "// line $2 \"$1\"$n",
         [rope(toFilename(p.config, n.info)), rope(line)])
  if {optStackTrace, optEndb} * p.options == {optStackTrace, optEndb} and
      ((p.prc == nil) or sfPure notin p.prc.flags):
    useMagic(p, "endb")
    lineF(p, "endb($1);$n", [rope(line)])
  elif hasFrameInfo(p):
    lineF(p, "F.line = $1;$n", [rope(line)])

proc genWhileStmt(p: PProc, n: PNode) =
  var
    cond: TCompRes
  internalAssert p.config, isEmptyType(n.typ)
  genLineDir(p, n)
  inc(p.unique)
  var length = len(p.blocks)
  setLen(p.blocks, length + 1)
  p.blocks[length].id = -p.unique
  p.blocks[length].isLoop = true
  let labl = p.unique.rope
  lineF(p, "L$1: while (true) {$n", [labl])
  p.nested: gen(p, n.sons[0], cond)
  lineF(p, "if (!$1) break L$2;$n",
       [cond.res, labl])
  p.nested: genStmt(p, n.sons[1])
  lineF(p, "}$n", [labl])
  setLen(p.blocks, length)

proc moveInto(p: PProc, src: var TCompRes, dest: TCompRes) =
  if src.kind != resNone:
    if dest.kind != resNone:
      lineF(p, "$1 = $2;$n", [dest.rdLoc, src.rdLoc])
    else:
      lineF(p, "$1;$n", [src.rdLoc])
    src.kind = resNone
    src.res = nil

proc genTry(p: PProc, n: PNode, r: var TCompRes) =
  # code to generate:
  #
  #  ++excHandler;
  #  var tmpFramePtr = framePtr;
  #  try {
  #    stmts;
  #    --excHandler;
  #  } catch (EXC) {
  #    var prevJSError = lastJSError; lastJSError = EXC;
  #    framePtr = tmpFramePtr;
  #    --excHandler;
  #    if (e.typ && e.typ == NTI433 || e.typ == NTI2321) {
  #      stmts;
  #    } else if (e.typ && e.typ == NTI32342) {
  #      stmts;
  #    } else {
  #      stmts;
  #    }
  #    lastJSError = prevJSError;
  #  } finally {
  #    framePtr = tmpFramePtr;
  #    stmts;
  #  }
  genLineDir(p, n)
  if not isEmptyType(n.typ):
    r.kind = resVal
    r.res = getTemp(p)
  inc(p.unique)
  var i = 1
  var length = sonsLen(n)
  var catchBranchesExist = length > 1 and n.sons[i].kind == nkExceptBranch
  if catchBranchesExist:
    add(p.body, "++excHandler;\L")
  var tmpFramePtr = rope"F"
  if optStackTrace notin p.options:
    tmpFramePtr = p.getTemp(true)
    line(p, tmpFramePtr & " = framePtr;\L")
  lineF(p, "try {$n", [])
  var a: TCompRes
  gen(p, n.sons[0], a)
  moveInto(p, a, r)
  var generalCatchBranchExists = false
  if catchBranchesExist:
    addf(p.body, "--excHandler;$n} catch (EXC) {$n var prevJSError = lastJSError;$n" &
        " lastJSError = EXC;$n --excHandler;$n", [])
    line(p, "framePtr = $1;$n" % [tmpFramePtr])
  while i < length and n.sons[i].kind == nkExceptBranch:
    let blen = sonsLen(n.sons[i])
    if blen == 1:
      # general except section:
      generalCatchBranchExists = true
      if i > 1: lineF(p, "else {$n", [])
      gen(p, n.sons[i].sons[0], a)
      moveInto(p, a, r)
      if i > 1: lineF(p, "}$n", [])
    else:
      var orExpr: Rope = nil
      var excAlias: PNode = nil

      useMagic(p, "isObj")
      for j in 0 .. blen - 2:
        var throwObj: PNode
        let it = n.sons[i].sons[j]

        if it.isInfixAs():
          throwObj = it[1]
          excAlias = it[2]
          # If this is a ``except exc as sym`` branch there must be no following
          # nodes
          doAssert orExpr == nil
        elif it.kind == nkType:
          throwObj = it
        else:
          internalError(p.config, n.info, "genTryStmt")

        if orExpr != nil: add(orExpr, "||")
        # Generate the correct type checking code depending on whether this is a
        # NIM-native or a JS-native exception
        # if isJsObject(throwObj.typ):
        if isImportedException(throwObj.typ, p.config):
          addf(orExpr, "lastJSError instanceof $1",
            [throwObj.typ.sym.loc.r])
        else:
          addf(orExpr, "isObj(lastJSError.m_type, $1)",
               [genTypeInfo(p, throwObj.typ)])

      if i > 1: line(p, "else ")
      lineF(p, "if (lastJSError && ($1)) {$n", [orExpr])
      # If some branch requires a local alias introduce it here. This is needed
      # since JS cannot do ``catch x as y``.
      if excAlias != nil:
        excAlias.sym.loc.r = mangleName(p.module, excAlias.sym)
        lineF(p, "var $1 = lastJSError;$n", excAlias.sym.loc.r)
      gen(p, n.sons[i].sons[blen - 1], a)
      moveInto(p, a, r)
      lineF(p, "}$n", [])
    inc(i)
  if catchBranchesExist:
    if not generalCatchBranchExists:
      useMagic(p, "reraiseException")
      line(p, "else {\L")
      line(p, "\treraiseException();\L")
      line(p, "}\L")
    lineF(p, "lastJSError = prevJSError;$n")
  line(p, "} finally {\L")
  line(p, "framePtr = $1;$n" % [tmpFramePtr])
  if i < length and n.sons[i].kind == nkFinally:
    genStmt(p, n.sons[i].sons[0])
  line(p, "}\L")

proc genRaiseStmt(p: PProc, n: PNode) =
  if n.sons[0].kind != nkEmpty:
    var a: TCompRes
    gen(p, n.sons[0], a)
    let typ = skipTypes(n.sons[0].typ, abstractPtrs)
    genLineDir(p, n)
    useMagic(p, "raiseException")
    lineF(p, "raiseException($1, $2);$n",
             [a.rdLoc, makeJSString(typ.sym.name.s)])
  else:
    genLineDir(p, n)
    useMagic(p, "reraiseException")
    line(p, "reraiseException();\L")

proc genCaseJS(p: PProc, n: PNode, r: var TCompRes) =
  var
    cond, stmt: TCompRes
  genLineDir(p, n)
  gen(p, n.sons[0], cond)
  let stringSwitch = skipTypes(n.sons[0].typ, abstractVar).kind == tyString
  if stringSwitch:
    useMagic(p, "toJSStr")
    lineF(p, "switch (toJSStr($1)) {$n", [cond.rdLoc])
  else:
    lineF(p, "switch ($1) {$n", [cond.rdLoc])
  if not isEmptyType(n.typ):
    r.kind = resVal
    r.res = getTemp(p)
  for i in 1 ..< sonsLen(n):
    let it = n.sons[i]
    case it.kind
    of nkOfBranch:
      for j in 0 .. sonsLen(it) - 2:
        let e = it.sons[j]
        if e.kind == nkRange:
          var v = copyNode(e.sons[0])
          while v.intVal <= e.sons[1].intVal:
            gen(p, v, cond)
            lineF(p, "case $1:$n", [cond.rdLoc])
            inc(v.intVal)
        else:
          if stringSwitch:
            case e.kind
            of nkStrLit..nkTripleStrLit: lineF(p, "case $1:$n",
                [makeJSString(e.strVal, false)])
            else: internalError(p.config, e.info, "jsgen.genCaseStmt: 2")
          else:
            gen(p, e, cond)
            lineF(p, "case $1:$n", [cond.rdLoc])
      p.nested:
        gen(p, lastSon(it), stmt)
        moveInto(p, stmt, r)
        lineF(p, "break;$n", [])
    of nkElse:
      lineF(p, "default: $n", [])
      p.nested:
        gen(p, it.sons[0], stmt)
        moveInto(p, stmt, r)
        lineF(p, "break;$n", [])
    else: internalError(p.config, it.info, "jsgen.genCaseStmt")
  lineF(p, "}$n", [])

proc genBlock(p: PProc, n: PNode, r: var TCompRes) =
  inc(p.unique)
  let idx = len(p.blocks)
  if n.sons[0].kind != nkEmpty:
    # named block?
    if (n.sons[0].kind != nkSym): internalError(p.config, n.info, "genBlock")
    var sym = n.sons[0].sym
    sym.loc.k = locOther
    sym.position = idx+1
  let labl = p.unique
  lineF(p, "L$1: do {$n", [labl.rope])
  setLen(p.blocks, idx + 1)
  p.blocks[idx].id = - p.unique # negative because it isn't used yet
  gen(p, n.sons[1], r)
  setLen(p.blocks, idx)
  lineF(p, "} while(false);$n", [labl.rope])

proc genBreakStmt(p: PProc, n: PNode) =
  var idx: int
  genLineDir(p, n)
  if n.sons[0].kind != nkEmpty:
    # named break?
    assert(n.sons[0].kind == nkSym)
    let sym = n.sons[0].sym
    assert(sym.loc.k == locOther)
    idx = sym.position-1
  else:
    # an unnamed 'break' can only break a loop after 'transf' pass:
    idx = len(p.blocks) - 1
    while idx >= 0 and not p.blocks[idx].isLoop: dec idx
    if idx < 0 or not p.blocks[idx].isLoop:
      internalError(p.config, n.info, "no loop to break")
  p.blocks[idx].id = abs(p.blocks[idx].id) # label is used
  lineF(p, "break L$1;$n", [rope(p.blocks[idx].id)])

proc genAsmOrEmitStmt(p: PProc, n: PNode) =
  genLineDir(p, n)
  p.body.add p.indentLine(nil)
  for i in 0 ..< sonsLen(n):
    let it = n[i]
    case it.kind
    of nkStrLit..nkTripleStrLit:
      p.body.add(it.strVal)
    of nkSym:
      let v = it.sym
      # for backwards compatibility we don't deref syms here :-(
      if false:
        discard
      else:
        var r: TCompRes
        gen(p, it, r)

        if it.typ.kind == tyPointer:
          # A fat pointer is disguised as an array
          r.res = r.address
          r.address = nil
          r.typ = etyNone
        elif r.typ == etyBaseIndex:
          # Deference first
          r.res = "$1[$2]" % [r.address, r.res]
          r.address = nil
          r.typ = etyNone

        p.body.add(r.rdLoc)
    else:
      var r: TCompRes
      gen(p, it, r)
      p.body.add(r.rdLoc)
  p.body.add "\L"

proc genIf(p: PProc, n: PNode, r: var TCompRes) =
  var cond, stmt: TCompRes
  var toClose = 0
  if not isEmptyType(n.typ):
    r.kind = resVal
    r.res = getTemp(p)
  for i in 0 ..< sonsLen(n):
    let it = n.sons[i]
    if sonsLen(it) != 1:
      if i > 0:
        lineF(p, "else {$n", [])
        inc(toClose)
      p.nested: gen(p, it.sons[0], cond)
      lineF(p, "if ($1) {$n", [cond.rdLoc])
      gen(p, it.sons[1], stmt)
    else:
      # else part:
      lineF(p, "else {$n", [])
      p.nested: gen(p, it.sons[0], stmt)
    moveInto(p, stmt, r)
    lineF(p, "}$n", [])
  line(p, repeat('}', toClose) & "\L")

proc generateHeader(p: PProc, typ: PType): Rope =
  result = nil
  for i in 1 ..< sonsLen(typ.n):
    assert(typ.n.sons[i].kind == nkSym)
    var param = typ.n.sons[i].sym
    if isCompileTimeOnly(param.typ): continue
    if result != nil: add(result, ", ")
    var name = mangleName(p.module, param)
    add(result, name)
    if mapType(param.typ) == etyBaseIndex:
      add(result, ", ")
      add(result, name)
      add(result, "_Idx")

proc countJsParams(typ: PType): int =
  for i in 1 ..< sonsLen(typ.n):
    assert(typ.n.sons[i].kind == nkSym)
    var param = typ.n.sons[i].sym
    if isCompileTimeOnly(param.typ): continue
    if mapType(param.typ) == etyBaseIndex:
      inc result, 2
    else:
      inc result

const
  nodeKindsNeedNoCopy = {nkCharLit..nkInt64Lit, nkStrLit..nkTripleStrLit,
    nkFloatLit..nkFloat64Lit, nkCurly, nkPar, nkStringToCString,
    nkObjConstr, nkTupleConstr, nkBracket,
    nkCStringToString, nkCall, nkPrefix, nkPostfix, nkInfix,
    nkCommand, nkHiddenCallConv, nkCallStrLit}

proc needsNoCopy(p: PProc; y: PNode): bool =
  return y.kind in nodeKindsNeedNoCopy or
        ((mapType(y.typ) != etyBaseIndex or (y.kind == nkSym and y.sym.kind == skParam)) and
          (skipTypes(y.typ, abstractInst).kind in
            {tyRef, tyPtr, tyLent, tyVar, tyCString, tyProc, tyOwned} + IntegralTypes))

proc genAsgnAux(p: PProc, x, y: PNode, noCopyNeeded: bool) =
  var a, b: TCompRes
  var xtyp = mapType(p, x.typ)

  gen(p, x, a)
  genLineDir(p, y)
  gen(p, y, b)

  # we don't care if it's an etyBaseIndex (global) of a string, it's
  # still a string that needs to be copied properly:
  if x.typ.skipTypes(abstractInst).kind in {tySequence, tyOpt, tyString}:
    xtyp = etySeq
  case xtyp
  of etySeq:
    if (needsNoCopy(p, y) and needsNoCopy(p, x)) or noCopyNeeded:
      lineF(p, "$1 = $2;$n", [a.rdLoc, b.rdLoc])
    else:
      useMagic(p, "nimCopy")
      lineF(p, "$1 = nimCopy(null, $2, $3);$n",
               [a.rdLoc, b.res, genTypeInfo(p, y.typ)])
  of etyObject:
    if x.typ.kind == tyVar or (needsNoCopy(p, y) and needsNoCopy(p, x)) or noCopyNeeded:
      lineF(p, "$1 = $2;$n", [a.rdLoc, b.rdLoc])
    else:
      useMagic(p, "nimCopy")
      lineF(p, "nimCopy($1, $2, $3);$n",
               [a.res, b.res, genTypeInfo(p, y.typ)])
  of etyBaseIndex:
    if a.typ != etyBaseIndex or b.typ != etyBaseIndex:
      if y.kind == nkCall:
        let tmp = p.getTemp(false)
        lineF(p, "var $1 = $4; $2 = $1[0]; $3 = $1[1];$n", [tmp, a.address, a.res, b.rdLoc])
      elif b.typ == etyBaseIndex:
        lineF(p, "$# = [$#, $#];$n", [a.res, b.address, b.res])
      else:
        internalError(p.config, x.info, "genAsgn")
    else:
      lineF(p, "$1 = $2; $3 = $4;$n", [a.address, b.address, a.res, b.res])
  else:
    lineF(p, "$1 = $2;$n", [a.rdLoc, b.rdLoc])

proc genAsgn(p: PProc, n: PNode) =
  genAsgnAux(p, n.sons[0], n.sons[1], noCopyNeeded=false)

proc genFastAsgn(p: PProc, n: PNode) =
  # 'shallowCopy' always produced 'noCopyNeeded = true' here but this is wrong
  # for code like
  #  while j >= pos:
  #    dest[i].shallowCopy(dest[j])
  # See bug #5933. So we try to be more compatible with the C backend semantics
  # here for 'shallowCopy'. This is an educated guess and might require further
  # changes later:
  let noCopy = n[0].typ.skipTypes(abstractInst).kind in {tySequence, tyOpt, tyString}
  genAsgnAux(p, n.sons[0], n.sons[1], noCopyNeeded=noCopy)

proc genSwap(p: PProc, n: PNode) =
  var a, b: TCompRes
  gen(p, n.sons[1], a)
  gen(p, n.sons[2], b)
  var tmp = p.getTemp(false)
  if mapType(p, skipTypes(n.sons[1].typ, abstractVar)) == etyBaseIndex:
    let tmp2 = p.getTemp(false)
    if a.typ != etyBaseIndex or b.typ != etyBaseIndex:
      internalError(p.config, n.info, "genSwap")
    lineF(p, "var $1 = $2; $2 = $3; $3 = $1;$n",
             [tmp, a.address, b.address])
    tmp = tmp2
  lineF(p, "var $1 = $2; $2 = $3; $3 = $1;",
           [tmp, a.res, b.res])

proc getFieldPosition(p: PProc; f: PNode): int =
  case f.kind
  of nkIntLit..nkUInt64Lit: result = int(f.intVal)
  of nkSym: result = f.sym.position
  else: internalError(p.config, f.info, "genFieldPosition")

proc genFieldAddr(p: PProc, n: PNode, r: var TCompRes) =
  var a: TCompRes
  r.typ = etyBaseIndex
  let b = if n.kind == nkHiddenAddr: n.sons[0] else: n
  gen(p, b.sons[0], a)
  if skipTypes(b.sons[0].typ, abstractVarRange).kind == tyTuple:
    r.res = makeJSString("Field" & $getFieldPosition(p, b.sons[1]))
  else:
    if b.sons[1].kind != nkSym: internalError(p.config, b.sons[1].info, "genFieldAddr")
    var f = b.sons[1].sym
    if f.loc.r == nil: f.loc.r = mangleName(p.module, f)
    r.res = makeJSString($f.loc.r)
  internalAssert p.config, a.typ != etyBaseIndex
  r.address = a.res
  r.kind = resExpr

proc genFieldAccess(p: PProc, n: PNode, r: var TCompRes) =
  gen(p, n.sons[0], r)
  r.typ = mapType(n.typ)
  let otyp = skipTypes(n.sons[0].typ, abstractVarRange)

  template mkTemp(i: int) =
    if r.typ == etyBaseIndex:
      if needsTemp(p, n[i]):
        let tmp = p.getTemp
        r.address = "($1 = $2, $1)[0]" % [tmp, r.res]
        r.res = "$1[1]" % [tmp]
        r.tmpLoc = tmp
      else:
        r.address = "$1[0]" % [r.res]
        r.res = "$1[1]" % [r.res]
  if otyp.kind == tyTuple:
    r.res = ("$1.Field$2") %
        [r.res, getFieldPosition(p, n.sons[1]).rope]
    mkTemp(0)
  else:
    if n.sons[1].kind != nkSym: internalError(p.config, n.sons[1].info, "genFieldAccess")
    var f = n.sons[1].sym
    if f.loc.r == nil: f.loc.r = mangleName(p.module, f)
    r.res = "$1.$2" % [r.res, f.loc.r]
    mkTemp(1)
  r.kind = resExpr

proc genAddr(p: PProc, n: PNode, r: var TCompRes)

proc genCheckedFieldOp(p: PProc, n: PNode, addrTyp: PType, r: var TCompRes) =
  internalAssert p.config, n.kind == nkCheckedFieldExpr
  # nkDotExpr to access the requested field
  let accessExpr = n[0]
  # nkCall to check if the discriminant is valid
  var checkExpr = n[1]

  let negCheck = checkExpr[0].sym.magic == mNot
  if negCheck:
    checkExpr = checkExpr[^1]

  # Field symbol
  var field = accessExpr[1].sym
  internalAssert p.config, field.kind == skField
  if field.loc.r == nil: field.loc.r = mangleName(p.module, field)
  # Discriminant symbol
  let disc = checkExpr[2].sym
  internalAssert p.config, disc.kind == skField
  if disc.loc.r == nil: disc.loc.r = mangleName(p.module, disc)

  var setx: TCompRes
  gen(p, checkExpr[1], setx)

  var obj: TCompRes
  gen(p, accessExpr[0], obj)
  # Avoid evaluating the LHS twice (one to read the discriminant and one to read
  # the field)
  let tmp = p.getTemp()
  lineF(p, "var $1 = $2;$n", tmp, obj.res)

  useMagic(p, "raiseFieldError")
  useMagic(p, "makeNimstrLit")
  lineF(p, "if ($1[$2.$3]$4undefined) { raiseFieldError(makeNimstrLit($5)); }$n",
    setx.res, tmp, disc.loc.r, if negCheck: ~"!==" else: ~"===",
    makeJSString(field.name.s))

  if addrTyp != nil and mapType(p, addrTyp) == etyBaseIndex:
    r.typ = etyBaseIndex
    r.res = makeJSString($field.loc.r)
    r.address = tmp
  else:
    r.typ = etyNone
    r.res = "$1.$2" % [tmp, field.loc.r]
  r.kind = resExpr

proc genArrayAddr(p: PProc, n: PNode, r: var TCompRes) =
  var
    a, b: TCompRes
    first: Int128
  r.typ = etyBaseIndex
  let m = if n.kind == nkHiddenAddr: n.sons[0] else: n
  gen(p, m.sons[0], a)
  gen(p, m.sons[1], b)
  #internalAssert p.config, a.typ != etyBaseIndex and b.typ != etyBaseIndex
  let (x, tmp) = maybeMakeTemp(p, m[0], a)
  r.address = x
  var typ = skipTypes(m.sons[0].typ, abstractPtrs)
  if typ.kind == tyArray:
    first = firstOrd(p.config, typ.sons[0])
  if optBoundsCheck in p.options:
    useMagic(p, "chckIndx")
    r.res = "chckIndx($1, $2, $3.length+$2-1)-$2" % [b.res, rope(first), tmp]
  elif first != 0:
    r.res = "($1)-$2" % [b.res, rope(first)]
  else:
    r.res = b.res
  r.kind = resExpr

proc genArrayAccess(p: PProc, n: PNode, r: var TCompRes) =
  var ty = skipTypes(n.sons[0].typ, abstractVarRange)
  if ty.kind in {tyRef, tyPtr, tyLent, tyOwned}: ty = skipTypes(ty.lastSon, abstractVarRange)
  case ty.kind
  of tyArray, tyOpenArray, tySequence, tyString, tyCString, tyVarargs:
    genArrayAddr(p, n, r)
  of tyTuple:
    genFieldAddr(p, n, r)
  else: internalError(p.config, n.info, "expr(nkBracketExpr, " & $ty.kind & ')')
  r.typ = mapType(n.typ)
  if r.res == nil: internalError(p.config, n.info, "genArrayAccess")
  if ty.kind == tyCString:
    r.res = "$1.charCodeAt($2)" % [r.address, r.res]
  elif r.typ == etyBaseIndex:
    if needsTemp(p, n[0]):
      let tmp = p.getTemp
      r.address = "($1 = $2, $1)[0]" % [tmp, r.rdLoc]
      r.res = "$1[1]" % [tmp]
      r.tmpLoc = tmp
    else:
      let x = r.rdLoc
      r.address = "$1[0]" % [x]
      r.res = "$1[1]" % [x]
  else:
    r.res = "$1[$2]" % [r.address, r.res]
  r.kind = resExpr

template isIndirect(x: PSym): bool =
  let v = x
  ({sfAddrTaken, sfGlobal} * v.flags != {} and
    #(mapType(v.typ) != etyObject) and
    {sfImportc, sfExportc} * v.flags == {} and
    v.kind notin {skProc, skFunc, skConverter, skMethod, skIterator,
                  skConst, skTemp, skLet})

proc genAddr(p: PProc, n: PNode, r: var TCompRes) =
  case n.sons[0].kind
  of nkSym:
    let s = n.sons[0].sym
    if s.loc.r == nil: internalError(p.config, n.info, "genAddr: 3")
    case s.kind
    of skVar, skLet, skResult:
      r.kind = resExpr
      let jsType = mapType(p, n.typ)
      if jsType == etyObject:
        # make addr() a no-op:
        r.typ = etyNone
        if isIndirect(s):
          r.res = s.loc.r & "[0]"
        else:
          r.res = s.loc.r
        r.address = nil
      elif {sfGlobal, sfAddrTaken} * s.flags != {} or jsType == etyBaseIndex:
        # for ease of code generation, we do not distinguish between
        # sfAddrTaken and sfGlobal.
        r.typ = etyBaseIndex
        r.address = s.loc.r
        r.res = rope("0")
      else:
        # 'var openArray' for instance produces an 'addr' but this is harmless:
        gen(p, n.sons[0], r)
        #internalError(p.config, n.info, "genAddr: 4 " & renderTree(n))
    else: internalError(p.config, n.info, "genAddr: 2")
  of nkCheckedFieldExpr:
    genCheckedFieldOp(p, n[0], n.typ, r)
  of nkDotExpr:
    if mapType(p, n.typ) == etyBaseIndex:
      genFieldAddr(p, n.sons[0], r)
    else:
      genFieldAccess(p, n.sons[0], r)
  of nkBracketExpr:
    var ty = skipTypes(n.sons[0].typ, abstractVarRange)
    if ty.kind in MappedToObject:
      gen(p, n.sons[0], r)
    else:
      let kindOfIndexedExpr = skipTypes(n.sons[0].sons[0].typ, abstractVarRange).kind
      case kindOfIndexedExpr
      of tyArray, tyOpenArray, tySequence, tyString, tyCString, tyVarargs:
        genArrayAddr(p, n.sons[0], r)
      of tyTuple:
        genFieldAddr(p, n.sons[0], r)
      else: internalError(p.config, n.sons[0].info, "expr(nkBracketExpr, " & $kindOfIndexedExpr & ')')
  of nkObjDownConv:
    gen(p, n.sons[0], r)
  of nkHiddenDeref:
    gen(p, n.sons[0].sons[0], r)
  else: internalError(p.config, n.sons[0].info, "genAddr: " & $n.sons[0].kind)

proc attachProc(p: PProc; content: Rope; s: PSym) =
  add(p.g.code, content)

proc attachProc(p: PProc; s: PSym) =
  let newp = genProc(p, s)
  attachProc(p, newp, s)

proc genProcForSymIfNeeded(p: PProc, s: PSym) =
  if not p.g.generatedSyms.containsOrIncl(s.id):
    let newp = genProc(p, s)
    var owner = p
    while owner != nil and owner.prc != s.owner:
      owner = owner.up
    if owner != nil: add(owner.locals, newp)
    else: attachProc(p, newp, s)

proc genCopyForParamIfNeeded(p: PProc, n: PNode) =
  let s = n.sym
  if p.prc == s.owner or needsNoCopy(p, n):
    return
  var owner = p.up
  while true:
    if owner == nil:
      internalError(p.config, n.info, "couldn't find the owner proc of the closed over param: " & s.name.s)
    if owner.prc == s.owner:
      if not owner.generatedParamCopies.containsOrIncl(s.id):
        let copy = "$1 = nimCopy(null, $1, $2);$n" % [s.loc.r, genTypeInfo(p, s.typ)]
        add(owner.locals, owner.indentLine(copy))
      return
    owner = owner.up

proc genSym(p: PProc, n: PNode, r: var TCompRes) =
  var s = n.sym
  case s.kind
  of skVar, skLet, skParam, skTemp, skResult, skForVar:
    if s.loc.r == nil:
      internalError(p.config, n.info, "symbol has no generated name: " & s.name.s)
    if s.kind == skParam:
      genCopyForParamIfNeeded(p, n)
    let k = mapType(p, s.typ)
    if k == etyBaseIndex:
      r.typ = etyBaseIndex
      if {sfAddrTaken, sfGlobal} * s.flags != {}:
        if isIndirect(s):
          r.address = "$1[0][0]" % [s.loc.r]
          r.res = "$1[0][1]" % [s.loc.r]
        else:
          r.address = "$1[0]" % [s.loc.r]
          r.res = "$1[1]" % [s.loc.r]
      else:
        r.address = s.loc.r
        r.res = s.loc.r & "_Idx"
    elif isIndirect(s):
      r.res = "$1[0]" % [s.loc.r]
    else:
      r.res = s.loc.r
  of skConst:
    genConstant(p, s)
    if s.loc.r == nil:
      internalError(p.config, n.info, "symbol has no generated name: " & s.name.s)
    r.res = s.loc.r
  of skProc, skFunc, skConverter, skMethod:
    if sfCompileTime in s.flags:
      localError(p.config, n.info, "request to generate code for .compileTime proc: " &
          s.name.s)
    discard mangleName(p.module, s)
    r.res = s.loc.r
    if lfNoDecl in s.loc.flags or s.magic != mNone or
       {sfImportc, sfInfixCall} * s.flags != {}:
      discard
    elif s.kind == skMethod and s.getBody.kind == nkEmpty:
      # we cannot produce code for the dispatcher yet:
      discard
    elif sfForward in s.flags:
      p.g.forwarded.add(s)
    else:
      genProcForSymIfNeeded(p, s)
  else:
    if s.loc.r == nil:
      internalError(p.config, n.info, "symbol has no generated name: " & s.name.s)
    r.res = s.loc.r
  r.kind = resVal

proc genDeref(p: PProc, n: PNode, r: var TCompRes) =
  let it = n.sons[0]
  let t = mapType(p, it.typ)
  if t == etyObject:
    gen(p, it, r)
  else:
    var a: TCompRes
    gen(p, it, a)
    r.kind = a.kind
    r.typ = mapType(p, n.typ)
    if r.typ == etyBaseIndex:
      let tmp = p.getTemp
      r.address = "($1 = $2, $1)[0]" % [tmp, a.rdLoc]
      r.res = "$1[1]" % [tmp]
      r.tmpLoc = tmp
    elif a.typ == etyBaseIndex:
      if a.tmpLoc != nil:
        r.tmpLoc = a.tmpLoc
      r.res = a.rdLoc
    else:
      internalError(p.config, n.info, "genDeref")

proc genArgNoParam(p: PProc, n: PNode, r: var TCompRes) =
  var a: TCompRes
  gen(p, n, a)
  if a.typ == etyBaseIndex:
    add(r.res, a.address)
    add(r.res, ", ")
    add(r.res, a.res)
  else:
    add(r.res, a.res)

proc genArg(p: PProc, n: PNode, param: PSym, r: var TCompRes; emitted: ptr int = nil) =
  var a: TCompRes
  gen(p, n, a)
  if skipTypes(param.typ, abstractVar).kind in {tyOpenArray, tyVarargs} and
      a.typ == etyBaseIndex:
    add(r.res, "$1[$2]" % [a.address, a.res])
  elif a.typ == etyBaseIndex:
    add(r.res, a.address)
    add(r.res, ", ")
    add(r.res, a.res)
    if emitted != nil: inc emitted[]
  elif n.typ.kind in {tyVar, tyPtr, tyRef, tyLent, tyOwned} and
      n.kind in nkCallKinds and mapType(param.typ) == etyBaseIndex:
    # this fixes bug #5608:
    let tmp = getTemp(p)
    add(r.res, "($1 = $2, $1[0]), $1[1]" % [tmp, a.rdLoc])
    if emitted != nil: inc emitted[]
  else:
    add(r.res, a.res)

proc genArgs(p: PProc, n: PNode, r: var TCompRes; start=1) =
  add(r.res, "(")
  var hasArgs = false

  var typ = skipTypes(n.sons[0].typ, abstractInst)
  assert(typ.kind == tyProc)
  assert(sonsLen(typ) == sonsLen(typ.n))
  var emitted = start-1

  for i in start ..< sonsLen(n):
    let it = n.sons[i]
    var paramType: PNode = nil
    if i < sonsLen(typ):
      assert(typ.n.sons[i].kind == nkSym)
      paramType = typ.n.sons[i]
      if paramType.typ.isCompileTimeOnly: continue

    if hasArgs: add(r.res, ", ")
    if paramType.isNil:
      genArgNoParam(p, it, r)
    else:
      genArg(p, it, paramType.sym, r, addr emitted)
    inc emitted
    hasArgs = true
  add(r.res, ")")
  when false:
    # XXX look into this:
    let jsp = countJsParams(typ)
    if emitted != jsp and tfVarargs notin typ.flags:
      localError(p.config, n.info, "wrong number of parameters emitted; expected: " & $jsp &
        " but got: " & $emitted)
  r.kind = resExpr

proc genOtherArg(p: PProc; n: PNode; i: int; typ: PType;
                 generated: var int; r: var TCompRes) =
  if i >= n.len:
    globalError(p.config, n.info, "wrong importcpp pattern; expected parameter at position " & $i &
        " but got only: " & $(n.len-1))
  let it = n[i]
  var paramType: PNode = nil
  if i < sonsLen(typ):
    assert(typ.n.sons[i].kind == nkSym)
    paramType = typ.n.sons[i]
    if paramType.typ.isCompileTimeOnly: return
  if paramType.isNil:
    genArgNoParam(p, it, r)
  else:
    genArg(p, it, paramType.sym, r)
  inc generated

proc genPatternCall(p: PProc; n: PNode; pat: string; typ: PType;
                    r: var TCompRes) =
  var i = 0
  var j = 1
  r.kind = resExpr
  while i < pat.len:
    case pat[i]
    of '@':
      var generated = 0
      for k in j ..< n.len:
        if generated > 0: add(r.res, ", ")
        genOtherArg(p, n, k, typ, generated, r)
      inc i
    of '#':
      var generated = 0
      genOtherArg(p, n, j, typ, generated, r)
      inc j
      inc i
    of '\31':
      # unit separator
      add(r.res, "#")
      inc i
    of '\29':
      # group separator
      add(r.res, "@")
      inc i
    else:
      let start = i
      while i < pat.len:
        if pat[i] notin {'@', '#', '\31', '\29'}: inc(i)
        else: break
      if i - 1 >= start:
        add(r.res, substr(pat, start, i - 1))

proc genInfixCall(p: PProc, n: PNode, r: var TCompRes) =
  # don't call '$' here for efficiency:
  let f = n[0].sym
  if f.loc.r == nil: f.loc.r = mangleName(p.module, f)
  if sfInfixCall in f.flags:
    let pat = n.sons[0].sym.loc.r.data
    internalAssert p.config, pat.len > 0
    if pat.contains({'#', '(', '@'}):
      var typ = skipTypes(n.sons[0].typ, abstractInst)
      assert(typ.kind == tyProc)
      genPatternCall(p, n, pat, typ, r)
      return
  if n.len != 1:
    gen(p, n.sons[1], r)
    if r.typ == etyBaseIndex:
      if r.address == nil:
        globalError(p.config, n.info, "cannot invoke with infix syntax")
      r.res = "$1[$2]" % [r.address, r.res]
      r.address = nil
      r.typ = etyNone
    add(r.res, ".")
  var op: TCompRes
  gen(p, n.sons[0], op)
  add(r.res, op.res)
  genArgs(p, n, r, 2)

proc genCall(p: PProc, n: PNode, r: var TCompRes) =
  gen(p, n.sons[0], r)
  genArgs(p, n, r)
  if n.typ != nil:
    let t = mapType(n.typ)
    if t == etyBaseIndex:
      let tmp = p.getTemp
      r.address = "($1 = $2, $1)[0]" % [tmp, r.rdLoc]
      r.res = "$1[1]" % [tmp]
      r.tmpLoc = tmp
      r.typ = t

proc genEcho(p: PProc, n: PNode, r: var TCompRes) =
  let n = n[1].skipConv
  internalAssert p.config, n.kind == nkBracket
  useMagic(p, "toJSStr") # Used in rawEcho
  useMagic(p, "rawEcho")
  add(r.res, "rawEcho(")
  for i in 0 ..< sonsLen(n):
    let it = n.sons[i]
    if it.typ.isCompileTimeOnly: continue
    if i > 0: add(r.res, ", ")
    genArgNoParam(p, it, r)
  add(r.res, ")")
  r.kind = resExpr

proc putToSeq(s: string, indirect: bool): Rope =
  result = rope(s)
  if indirect: result = "[$1]" % [result]

proc createVar(p: PProc, typ: PType, indirect: bool): Rope
proc createRecordVarAux(p: PProc, rec: PNode, excludedFieldIDs: IntSet, output: var Rope) =
  case rec.kind
  of nkRecList:
    for i in 0 ..< sonsLen(rec):
      createRecordVarAux(p, rec.sons[i], excludedFieldIDs, output)
  of nkRecCase:
    createRecordVarAux(p, rec.sons[0], excludedFieldIDs, output)
    for i in 1 ..< sonsLen(rec):
      createRecordVarAux(p, lastSon(rec.sons[i]), excludedFieldIDs, output)
  of nkSym:
    # Do not produce code for void types
    if isEmptyType(rec.sym.typ): return
    if rec.sym.id notin excludedFieldIDs:
      if output.len > 0: output.add(", ")
      output.addf("$#: ", [mangleName(p.module, rec.sym)])
      output.add(createVar(p, rec.sym.typ, false))
  else: internalError(p.config, rec.info, "createRecordVarAux")

proc createObjInitList(p: PProc, typ: PType, excludedFieldIDs: IntSet, output: var Rope) =
  var t = typ
  if objHasTypeField(t):
    if output.len > 0: output.add(", ")
    addf(output, "m_type: $1", [genTypeInfo(p, t)])
  while t != nil:
    t = t.skipTypes(skipPtrs)
    createRecordVarAux(p, t.n, excludedFieldIDs, output)
    t = t.sons[0]

proc arrayTypeForElemType(typ: PType): string =
  # XXX This should also support tyEnum and tyBool
  case typ.kind
  of tyInt, tyInt32: "Int32Array"
  of tyInt16: "Int16Array"
  of tyInt8: "Int8Array"
  of tyUInt, tyUInt32: "Uint32Array"
  of tyUInt16: "Uint16Array"
  of tyUInt8: "Uint8Array"
  of tyFloat32: "Float32Array"
  of tyFloat64, tyFloat: "Float64Array"
  else: ""

proc createVar(p: PProc, typ: PType, indirect: bool): Rope =
  var t = skipTypes(typ, abstractInst)
  case t.kind
  of tyInt..tyInt64, tyUInt..tyUInt64, tyEnum, tyChar:
    result = putToSeq("0", indirect)
  of tyFloat..tyFloat128:
    result = putToSeq("0.0", indirect)
  of tyRange, tyGenericInst, tyAlias, tySink, tyOwned:
    result = createVar(p, lastSon(typ), indirect)
  of tySet:
    result = putToSeq("{}", indirect)
  of tyBool:
    result = putToSeq("false", indirect)
  of tyArray:
    let length = toInt(lengthOrd(p.config, t))
    let e = elemType(t)
    let jsTyp = arrayTypeForElemType(e)
    if jsTyp.len > 0:
      result = "new $1($2)" % [rope(jsTyp), rope(length)]
    elif length > 32:
      useMagic(p, "arrayConstr")
      # XXX: arrayConstr depends on nimCopy. This line shouldn't be necessary.
      useMagic(p, "nimCopy")
      result = "arrayConstr($1, $2, $3)" % [rope(length),
          createVar(p, e, false), genTypeInfo(p, e)]
    else:
      result = rope("[")
      var i = 0
      while i < length:
        if i > 0: add(result, ", ")
        add(result, createVar(p, e, false))
        inc(i)
      add(result, "]")
    if indirect: result = "[$1]" % [result]
  of tyTuple:
    result = rope("{")
    for i in 0..<t.sonsLen:
      if i > 0: add(result, ", ")
      addf(result, "Field$1: $2", [i.rope,
            createVar(p, t.sons[i], false)])
    add(result, "}")
    if indirect: result = "[$1]" % [result]
  of tyObject:
    var initList: Rope
    createObjInitList(p, t, initIntSet(), initList)
    result = ("{$1}") % [initList]
    if indirect: result = "[$1]" % [result]
  of tyVar, tyPtr, tyLent, tyRef, tyPointer:
    if mapType(p, t) == etyBaseIndex:
      result = putToSeq("[null, 0]", indirect)
    else:
      result = putToSeq("null", indirect)
  of tySequence, tyOpt, tyString, tyCString, tyProc:
    result = putToSeq("null", indirect)
  of tyStatic:
    if t.n != nil:
      result = createVar(p, lastSon t, indirect)
    else:
      internalError(p.config, "createVar: " & $t.kind)
      result = nil
  else:
    internalError(p.config, "createVar: " & $t.kind)
    result = nil

template returnType: untyped = ~""

proc genVarInit(p: PProc, v: PSym, n: PNode) =
  var
    a: TCompRes
    s: Rope
    varCode: string
    varName = mangleName(p.module, v)
    useReloadingGuard = sfGlobal in v.flags and p.config.hcrOn

  if v.constraint.isNil:
    if useReloadingGuard:
      lineF(p, "var $1;$n", varName)
      lineF(p, "if ($1 === undefined) {$n", varName)
      varCode = $varName
      inc p.extraIndent
    else:
      varCode = "var $2"
  else:
    # Is this really a thought through feature?  this basically unused
    # feature makes it impossible for almost all format strings in
    # this function to be checked at compile time.
    varCode = v.constraint.strVal

  if n.kind == nkEmpty:
    if not isIndirect(v) and
      v.typ.kind in {tyVar, tyPtr, tyLent, tyRef, tyOwned} and mapType(p, v.typ) == etyBaseIndex:
      lineF(p, "var $1 = null;$n", [varName])
      lineF(p, "var $1_Idx = 0;$n", [varName])
    else:
      line(p, runtimeFormat(varCode & " = $3;$n", [returnType, varName, createVar(p, v.typ, isIndirect(v))]))
  else:
    gen(p, n, a)
    case mapType(p, v.typ)
    of etyObject, etySeq:
      if needsNoCopy(p, n):
        s = a.res
      else:
        useMagic(p, "nimCopy")
        s = "nimCopy(null, $1, $2)" % [a.res, genTypeInfo(p, n.typ)]
    of etyBaseIndex:
      let targetBaseIndex = {sfAddrTaken, sfGlobal} * v.flags == {}
      if a.typ == etyBaseIndex:
        if targetBaseIndex:
          line(p, runtimeFormat(varCode & " = $3, $2_Idx = $4;$n",
                   [returnType, v.loc.r, a.address, a.res]))
        else:
          if isIndirect(v):
            line(p, runtimeFormat(varCode & " = [[$3, $4]];$n",
                     [returnType, v.loc.r, a.address, a.res]))
          else:
            line(p, runtimeFormat(varCode & " = [$3, $4];$n",
                     [returnType, v.loc.r, a.address, a.res]))
      else:
        if targetBaseIndex:
          let tmp = p.getTemp
          lineF(p, "var $1 = $2, $3 = $1[0], $3_Idx = $1[1];$n",
                   [tmp, a.res, v.loc.r])
        else:
          line(p, runtimeFormat(varCode & " = $3;$n", [returnType, v.loc.r, a.res]))
      return
    else:
      s = a.res
    if isIndirect(v):
      line(p, runtimeFormat(varCode & " = [$3];$n", [returnType, v.loc.r, s]))
    else:
      line(p, runtimeFormat(varCode & " = $3;$n", [returnType, v.loc.r, s]))

  if useReloadingGuard:
    dec p.extraIndent
    lineF(p, "}$n")

proc genVarStmt(p: PProc, n: PNode) =
  for i in 0 ..< sonsLen(n):
    var a = n.sons[i]
    if a.kind != nkCommentStmt:
      if a.kind == nkVarTuple:
        let unpacked = lowerTupleUnpacking(p.module.graph, a, p.prc)
        genStmt(p, unpacked)
      else:
        assert(a.kind == nkIdentDefs)
        assert(a.sons[0].kind == nkSym)
        var v = a.sons[0].sym
        if lfNoDecl notin v.loc.flags and sfImportc notin v.flags:
          genLineDir(p, a)
          genVarInit(p, v, a.sons[2])

proc genConstant(p: PProc, c: PSym) =
  if lfNoDecl notin c.loc.flags and not p.g.generatedSyms.containsOrIncl(c.id):
    let oldBody = p.body
    p.body = nil
    #genLineDir(p, c.ast)
    genVarInit(p, c, c.ast)
    add(p.g.constants, p.body)
    p.body = oldBody

proc genNew(p: PProc, n: PNode) =
  var a: TCompRes
  gen(p, n.sons[1], a)
  var t = skipTypes(n.sons[1].typ, abstractVar).sons[0]
  if mapType(t) == etyObject:
    lineF(p, "$1 = $2;$n", [a.rdLoc, createVar(p, t, false)])
  elif a.typ == etyBaseIndex:
    lineF(p, "$1 = [$3]; $2 = 0;$n", [a.address, a.res, createVar(p, t, false)])
  else:
    lineF(p, "$1 = [[$2], 0];$n", [a.rdLoc, createVar(p, t, false)])

proc genNewSeq(p: PProc, n: PNode) =
  var x, y: TCompRes
  gen(p, n.sons[1], x)
  gen(p, n.sons[2], y)
  let t = skipTypes(n.sons[1].typ, abstractVar).sons[0]
  lineF(p, "$1 = new Array($2); for (var i=0;i<$2;++i) {$1[i]=$3;}", [
    x.rdLoc, y.rdLoc, createVar(p, t, false)])

proc genOrd(p: PProc, n: PNode, r: var TCompRes) =
  case skipTypes(n.sons[1].typ, abstractVar).kind
  of tyEnum, tyInt..tyUInt64, tyChar: gen(p, n.sons[1], r)
  of tyBool: unaryExpr(p, n, r, "", "($1 ? 1:0)")
  else: internalError(p.config, n.info, "genOrd")

proc genConStrStr(p: PProc, n: PNode, r: var TCompRes) =
  var a: TCompRes

  gen(p, n.sons[1], a)
  r.kind = resExpr
  if skipTypes(n.sons[1].typ, abstractVarRange).kind == tyChar:
    r.res.add("[$1].concat(" % [a.res])
  else:
    r.res.add("($1 || []).concat(" % [a.res])

  for i in 2 .. sonsLen(n) - 2:
    gen(p, n.sons[i], a)
    if skipTypes(n.sons[i].typ, abstractVarRange).kind == tyChar:
      r.res.add("[$1]," % [a.res])
    else:
      r.res.add("$1 || []," % [a.res])

  gen(p, n.sons[sonsLen(n) - 1], a)
  if skipTypes(n.sons[sonsLen(n) - 1].typ, abstractVarRange).kind == tyChar:
    r.res.add("[$1])" % [a.res])
  else:
    r.res.add("$1 || [])" % [a.res])

proc genToArray(p: PProc; n: PNode; r: var TCompRes) =
  # we map mArray to PHP's array constructor, a mild hack:
  var a, b: TCompRes
  r.kind = resExpr
  r.res = rope("array(")
  let x = skipConv(n[1])
  if x.kind == nkBracket:
    for i in 0 ..< x.len:
      let it = x[i]
      if it.kind in {nkPar, nkTupleConstr} and it.len == 2:
        if i > 0: r.res.add(", ")
        gen(p, it[0], a)
        gen(p, it[1], b)
        r.res.add("$# => $#" % [a.rdLoc, b.rdLoc])
      else:
        localError(p.config, it.info, "'toArray' needs tuple constructors")
  else:
    localError(p.config, x.info, "'toArray' needs an array literal")
  r.res.add(")")

proc genReprAux(p: PProc, n: PNode, r: var TCompRes, magic: string, typ: Rope = nil) =
  useMagic(p, magic)
  add(r.res, magic & "(")
  var a: TCompRes

  gen(p, n.sons[1], a)
  if magic == "reprAny":
    # the pointer argument in reprAny is expandend to
    # (pointedto, pointer), so we need to fill it
    if a.address.isNil:
      add(r.res, a.res)
      add(r.res, ", null")
    else:
      add(r.res, "$1, $2" % [a.address, a.res])
  else:
    add(r.res, a.res)

  if not typ.isNil:
    add(r.res, ", ")
    add(r.res, typ)
  add(r.res, ")")

proc genRepr(p: PProc, n: PNode, r: var TCompRes) =
  let t = skipTypes(n.sons[1].typ, abstractVarRange)
  case t.kind:
  of tyInt..tyInt64, tyUInt..tyUInt64:
    genReprAux(p, n, r, "reprInt")
  of tyChar:
    genReprAux(p, n, r, "reprChar")
  of tyBool:
    genReprAux(p, n, r, "reprBool")
  of tyFloat..tyFloat128:
    genReprAux(p, n, r, "reprFloat")
  of tyString:
    genReprAux(p, n, r, "reprStr")
  of tyEnum, tyOrdinal:
    genReprAux(p, n, r, "reprEnum", genTypeInfo(p, t))
  of tySet:
    genReprAux(p, n, r, "reprSet", genTypeInfo(p, t))
  of tyEmpty, tyVoid:
    localError(p.config, n.info, "'repr' doesn't support 'void' type")
  of tyPointer:
    genReprAux(p, n, r, "reprPointer")
  of tyOpenArray, tyVarargs:
    genReprAux(p, n, r, "reprJSONStringify")
  else:
    genReprAux(p, n, r, "reprAny", genTypeInfo(p, t))

proc genOf(p: PProc, n: PNode, r: var TCompRes) =
  var x: TCompRes
  let t = skipTypes(n.sons[2].typ,
                    abstractVarRange+{tyRef, tyPtr, tyLent, tyTypeDesc, tyOwned})
  gen(p, n.sons[1], x)
  if tfFinal in t.flags:
    r.res = "($1.m_type == $2)" % [x.res, genTypeInfo(p, t)]
  else:
    useMagic(p, "isObj")
    r.res = "isObj($1.m_type, $2)" % [x.res, genTypeInfo(p, t)]
  r.kind = resExpr

proc genDefault(p: PProc, n: PNode; r: var TCompRes) =
  r.res = createVar(p, n.typ, indirect = false)
  r.kind = resExpr

proc genReset(p: PProc, n: PNode) =
  var x: TCompRes
  useMagic(p, "genericReset")
  gen(p, n.sons[1], x)
  if x.typ == etyBaseIndex:
    lineF(p, "$1 = null, $2 = 0;$n", [x.address, x.res])
  else:
    let (a, tmp) = maybeMakeTemp(p, n[1], x)
    lineF(p, "$1 = genericReset($3, $2);$n", [a,
                  genTypeInfo(p, n.sons[1].typ), tmp])

proc genMagic(p: PProc, n: PNode, r: var TCompRes) =
  var
    a: TCompRes
    line, filen: Rope
  var op = n.sons[0].sym.magic
  case op
  of mOr: genOr(p, n.sons[1], n.sons[2], r)
  of mAnd: genAnd(p, n.sons[1], n.sons[2], r)
  of mAddI..mStrToStr: arith(p, n, r, op)
  of mRepr: genRepr(p, n, r)
  of mSwap: genSwap(p, n)
  of mUnaryLt:
    # XXX: range checking?
    if not (optOverflowCheck in p.options): unaryExpr(p, n, r, "", "$1 - 1")
    else: unaryExpr(p, n, r, "subInt", "subInt($1, 1)")
  of mAppendStrCh:
    binaryExpr(p, n, r, "addChar",
        "if ($1 != null) { addChar($3, $2); } else { $3 = [$2]; }")
  of mAppendStrStr:
    var lhs, rhs: TCompRes
    gen(p, n[1], lhs)
    gen(p, n[2], rhs)

    let rhsIsLit = n[2].kind in nkStrKinds
    let (a, tmp) = maybeMakeTemp(p, n[1], lhs)
    if skipTypes(n.sons[1].typ, abstractVarRange).kind == tyCString:
      r.res = "if ($1 != null) { $4 += $2; } else { $4 = $2$3; }" % [
        a, rhs.rdLoc, if rhsIsLit: nil else: ~".slice()", tmp]
    else:
      r.res = "if ($1 != null) { $4 = ($4).concat($2); } else { $4 = $2$3; }" % [
          lhs.rdLoc, rhs.rdLoc, if rhsIsLit: nil else: ~".slice()", tmp]
    r.kind = resExpr
  of mAppendSeqElem:
    var x, y: TCompRes
    gen(p, n.sons[1], x)
    gen(p, n.sons[2], y)
    let (a, tmp) = maybeMakeTemp(p, n[1], x)
    if mapType(n[2].typ) == etyBaseIndex:
      let c = "[$1, $2]" % [y.address, y.res]
      r.res = "if ($1 != null) { $3.push($2); } else { $3 = [$2]; }" % [a, c, tmp]
    elif needsNoCopy(p, n[2]):
      r.res = "if ($1 != null) { $3.push($2); } else { $3 = [$2]; }" % [a, y.rdLoc, tmp]
    else:
      useMagic(p, "nimCopy")
      let c = getTemp(p, defineInLocals=false)
      lineF(p, "var $1 = nimCopy(null, $2, $3);$n",
            [c, y.rdLoc, genTypeInfo(p, n[2].typ)])
      r.res = "if ($1 != null) { $3.push($2); } else { $3 = [$2]; }" % [a, c, tmp]
    r.kind = resExpr
  of mConStrStr:
    genConStrStr(p, n, r)
  of mEqStr:
    binaryExpr(p, n, r, "eqStrings", "eqStrings($1, $2)")
  of mLeStr:
    binaryExpr(p, n, r, "cmpStrings", "(cmpStrings($1, $2) <= 0)")
  of mLtStr:
    binaryExpr(p, n, r, "cmpStrings", "(cmpStrings($1, $2) < 0)")
  of mIsNil:
    # we want to accept undefined, so we ==
    if mapType(n[1].typ) != etyBaseIndex:
      unaryExpr(p, n, r, "", "($1 == null)")
    else:
      var x: TCompRes
      gen(p, n[1], x)
      r.res = "($# == null && $# === 0)" % [x.address, x.res]
  of mEnumToStr: genRepr(p, n, r)
  of mNew, mNewFinalize: genNew(p, n)
  of mChr: gen(p, n.sons[1], r)
  of mArrToSeq:
    if needsNoCopy(p, n.sons[1]):
      gen(p, n.sons[1], r)
    else:
      var x: TCompRes
      gen(p, n.sons[1], x)
      useMagic(p, "nimCopy")
      r.res = "nimCopy(null, $1, $2)" % [x.rdLoc, genTypeInfo(p, n.typ)]
  of mDestroy: discard "ignore calls to the default destructor"
  of mOrd: genOrd(p, n, r)
  of mLengthStr, mLengthSeq, mLengthOpenArray, mLengthArray:
    unaryExpr(p, n, r, "", "($1 != null ? $2.length : 0)")
  of mXLenStr, mXLenSeq:
    unaryExpr(p, n, r, "", "$1.length")
  of mHigh:
    unaryExpr(p, n, r, "", "($1 != null ? ($2.length-1) : -1)")
  of mInc:
    if n[1].typ.skipTypes(abstractRange).kind in {tyUInt..tyUInt64}:
      binaryUintExpr(p, n, r, "+", true)
    else:
      if optOverflowCheck notin p.options: binaryExpr(p, n, r, "", "$1 += $2")
      else: binaryExpr(p, n, r, "addInt", "$1 = addInt($3, $2)")
  of ast.mDec:
    if n[1].typ.skipTypes(abstractRange).kind in {tyUInt..tyUInt64}:
      binaryUintExpr(p, n, r, "-", true)
    else:
      if optOverflowCheck notin p.options: binaryExpr(p, n, r, "", "$1 -= $2")
      else: binaryExpr(p, n, r, "subInt", "$1 = subInt($3, $2)")
  of mSetLengthStr:
    binaryExpr(p, n, r, "mnewString", "($1 == null ? $3 = mnewString($2) : $3.length = $2)")
  of mSetLengthSeq:
    var x, y: TCompRes
    gen(p, n.sons[1], x)
    gen(p, n.sons[2], y)
    let t = skipTypes(n.sons[1].typ, abstractVar).sons[0]
    let (a, tmp) = maybeMakeTemp(p, n[1], x)
    let (b, tmp2) = maybeMakeTemp(p, n[2], y)
    r.res = """if ($1 === null) $4 = [];
               if ($4.length < $2) { for (var i=$4.length;i<$5;++i) $4.push($3); }
               else { $4.length = $5; }""" % [a, b, createVar(p, t, false), tmp, tmp2]
    r.kind = resExpr
  of mCard: unaryExpr(p, n, r, "SetCard", "SetCard($1)")
  of mLtSet: binaryExpr(p, n, r, "SetLt", "SetLt($1, $2)")
  of mLeSet: binaryExpr(p, n, r, "SetLe", "SetLe($1, $2)")
  of mEqSet: binaryExpr(p, n, r, "SetEq", "SetEq($1, $2)")
  of mMulSet: binaryExpr(p, n, r, "SetMul", "SetMul($1, $2)")
  of mPlusSet: binaryExpr(p, n, r, "SetPlus", "SetPlus($1, $2)")
  of mMinusSet: binaryExpr(p, n, r, "SetMinus", "SetMinus($1, $2)")
  of mIncl: binaryExpr(p, n, r, "", "$1[$2] = true")
  of mExcl: binaryExpr(p, n, r, "", "delete $1[$2]")
  of mInSet:
    binaryExpr(p, n, r, "", "($1[$2] != undefined)")
  of mNewSeq: genNewSeq(p, n)
  of mNewSeqOfCap: unaryExpr(p, n, r, "", "[]")
  of mOf: genOf(p, n, r)
  of mDefault: genDefault(p, n, r)
  of mReset: genReset(p, n)
  of mEcho: genEcho(p, n, r)
  of mNLen..mNError, mSlurp, mStaticExec:
    localError(p.config, n.info, errXMustBeCompileTime % n.sons[0].sym.name.s)
  of mCopyStr:
    binaryExpr(p, n, r, "", "($1.slice($2))")
  of mNewString: unaryExpr(p, n, r, "mnewString", "mnewString($1)")
  of mNewStringOfCap:
    unaryExpr(p, n, r, "mnewString", "mnewString(0)")
  of mDotDot:
    genProcForSymIfNeeded(p, n.sons[0].sym)
    genCall(p, n, r)
  of mParseBiggestFloat:
    useMagic(p, "nimParseBiggestFloat")
    genCall(p, n, r)
  of mSlice:
    # arr.slice([begin[, end]]): 'end' is exclusive
    var x, y, z: TCompRes
    gen(p, n.sons[1], x)
    gen(p, n.sons[2], y)
    gen(p, n.sons[3], z)
    r.res = "($1.slice($2, $3+1))" % [x.rdLoc, y.rdLoc, z.rdLoc]
    r.kind = resExpr
  else:
    genCall(p, n, r)
    #else internalError(p.config, e.info, 'genMagic: ' + magicToStr[op]);

proc genSetConstr(p: PProc, n: PNode, r: var TCompRes) =
  var
    a, b: TCompRes
  useMagic(p, "setConstr")
  r.res = rope("setConstr(")
  r.kind = resExpr
  for i in 0 ..< sonsLen(n):
    if i > 0: add(r.res, ", ")
    var it = n.sons[i]
    if it.kind == nkRange:
      gen(p, it.sons[0], a)
      gen(p, it.sons[1], b)
      addf(r.res, "[$1, $2]", [a.res, b.res])
    else:
      gen(p, it, a)
      add(r.res, a.res)
  add(r.res, ")")
  # emit better code for constant sets:
  if isDeepConstExpr(n):
    inc(p.g.unique)
    let tmp = rope("ConstSet") & rope(p.g.unique)
    addf(p.g.constants, "var $1 = $2;$n", [tmp, r.res])
    r.res = tmp

proc genArrayConstr(p: PProc, n: PNode, r: var TCompRes) =
  var a: TCompRes
  r.res = rope("[")
  r.kind = resExpr
  for i in 0 ..< sonsLen(n):
    if i > 0: add(r.res, ", ")
    gen(p, n.sons[i], a)
    if a.typ == etyBaseIndex:
      addf(r.res, "[$1, $2]", [a.address, a.res])
    else:
      if not needsNoCopy(p, n[i]):
        let typ = n[i].typ.skipTypes(abstractInst)
        useMagic(p, "nimCopy")
        a.res = "nimCopy(null, $1, $2)" % [a.rdLoc, genTypeInfo(p, typ)]
      add(r.res, a.res)
  add(r.res, "]")

proc genTupleConstr(p: PProc, n: PNode, r: var TCompRes) =
  var a: TCompRes
  r.res = rope("{")
  r.kind = resExpr
  for i in 0 ..< sonsLen(n):
    if i > 0: add(r.res, ", ")
    var it = n.sons[i]
    if it.kind == nkExprColonExpr: it = it.sons[1]
    gen(p, it, a)
    let typ = it.typ.skipTypes(abstractInst)
    if a.typ == etyBaseIndex:
      addf(r.res, "Field$#: [$#, $#]", [i.rope, a.address, a.res])
    else:
      if not needsNoCopy(p, it):
        useMagic(p, "nimCopy")
        a.res = "nimCopy(null, $1, $2)" % [a.rdLoc, genTypeInfo(p, typ)]
      addf(r.res, "Field$#: $#", [i.rope, a.res])
  r.res.add("}")

proc genObjConstr(p: PProc, n: PNode, r: var TCompRes) =
  var a: TCompRes
  r.kind = resExpr
  var initList : Rope
  var fieldIDs = initIntSet()
  for i in 1 ..< sonsLen(n):
    if i > 1: add(initList, ", ")
    var it = n.sons[i]
    internalAssert p.config, it.kind == nkExprColonExpr
    let val = it.sons[1]
    gen(p, val, a)
    var f = it.sons[0].sym
    if f.loc.r == nil: f.loc.r = mangleName(p.module, f)
    fieldIDs.incl(f.id)

    let typ = val.typ.skipTypes(abstractInst)
    if a.typ == etyBaseIndex:
      addf(initList, "$#: [$#, $#]", [f.loc.r, a.address, a.res])
    else:
      if not needsNoCopy(p, val):
        useMagic(p, "nimCopy")
        a.res = "nimCopy(null, $1, $2)" % [a.rdLoc, genTypeInfo(p, typ)]
      addf(initList, "$#: $#", [f.loc.r, a.res])
  let t = skipTypes(n.typ, abstractInst + skipPtrs)
  createObjInitList(p, t, fieldIDs, initList)
  r.res = ("{$1}") % [initList]

proc genConv(p: PProc, n: PNode, r: var TCompRes) =
  var dest = skipTypes(n.typ, abstractVarRange)
  var src = skipTypes(n.sons[1].typ, abstractVarRange)
  gen(p, n.sons[1], r)
  if dest.kind == src.kind:
    # no-op conversion
    return
  case dest.kind:
  of tyBool:
    r.res = "(!!($1))" % [r.res]
    r.kind = resExpr
  of tyInt:
    r.res = "(($1)|0)" % [r.res]
  else:
    # TODO: What types must we handle here?
    discard

proc upConv(p: PProc, n: PNode, r: var TCompRes) =
  gen(p, n.sons[0], r)        # XXX

proc genRangeChck(p: PProc, n: PNode, r: var TCompRes, magic: string) =
  var a, b: TCompRes
  gen(p, n.sons[0], r)
  if optRangeCheck in p.options:
    gen(p, n.sons[1], a)
    gen(p, n.sons[2], b)
    useMagic(p, "chckRange")
    r.res = "chckRange($1, $2, $3)" % [r.res, a.res, b.res]
    r.kind = resExpr

proc convStrToCStr(p: PProc, n: PNode, r: var TCompRes) =
  # we do an optimization here as this is likely to slow down
  # much of the code otherwise:
  if n.sons[0].kind == nkCStringToString:
    gen(p, n.sons[0].sons[0], r)
  else:
    gen(p, n.sons[0], r)
    if r.res == nil: internalError(p.config, n.info, "convStrToCStr")
    useMagic(p, "toJSStr")
    r.res = "toJSStr($1)" % [r.res]
    r.kind = resExpr

proc convCStrToStr(p: PProc, n: PNode, r: var TCompRes) =
  # we do an optimization here as this is likely to slow down
  # much of the code otherwise:
  if n.sons[0].kind == nkStringToCString:
    gen(p, n.sons[0].sons[0], r)
  else:
    gen(p, n.sons[0], r)
    if r.res == nil: internalError(p.config, n.info, "convCStrToStr")
    useMagic(p, "cstrToNimstr")
    r.res = "cstrToNimstr($1)" % [r.res]
    r.kind = resExpr

proc genReturnStmt(p: PProc, n: PNode) =
  if p.procDef == nil: internalError(p.config, n.info, "genReturnStmt")
  p.beforeRetNeeded = true
  if n.sons[0].kind != nkEmpty:
    genStmt(p, n.sons[0])
  else:
    genLineDir(p, n)
  lineF(p, "break BeforeRet;$n", [])

proc frameCreate(p: PProc; procname, filename: Rope): Rope =
  const frameFmt =
    "var F={procname:$1,prev:framePtr,filename:$2,line:0};$n"

  result = p.indentLine(frameFmt % [procname, filename])
  result.add p.indentLine(ropes.`%`("framePtr = F;$n", []))

proc frameDestroy(p: PProc): Rope =
  result = p.indentLine rope(("framePtr = F.prev;") & "\L")

proc genProcBody(p: PProc, prc: PSym): Rope =
  if hasFrameInfo(p):
    result = frameCreate(p,
              makeJSString(prc.owner.name.s & '.' & prc.name.s),
              makeJSString(toFilename(p.config, prc.info)))
  else:
    result = nil
  if p.beforeRetNeeded:
    result.add p.indentLine(~"BeforeRet: do {$n")
    result.add p.body
    result.add p.indentLine(~"} while (false);$n")
  else:
    add(result, p.body)
  if prc.typ.callConv == ccSysCall:
    result = ("try {$n$1} catch (e) {$n" &
      " alert(\"Unhandled exception:\\n\" + e.message + \"\\n\"$n}") % [result]
  if hasFrameInfo(p):
    add(result, frameDestroy(p))

proc optionalLine(p: Rope): Rope =
  if p == nil:
    return nil
  else:
    return p & "\L"

proc genProc(oldProc: PProc, prc: PSym): Rope =
  var
    resultSym: PSym
    a: TCompRes
  #if gVerbosity >= 3:
  #  echo "BEGIN generating code for: " & prc.name.s
  var p = newProc(oldProc.g, oldProc.module, prc.ast, prc.options)
  p.up = oldProc
  var returnStmt: Rope = nil
  var resultAsgn: Rope = nil
  var name = mangleName(p.module, prc)
  let header = generateHeader(p, prc.typ)
  if prc.typ.sons[0] != nil and sfPure notin prc.flags:
    resultSym = prc.ast.sons[resultPos].sym
    let mname = mangleName(p.module, resultSym)
    if not isIndirect(resultSym) and
      resultSym.typ.kind in {tyVar, tyPtr, tyLent, tyRef, tyOwned} and
        mapType(p, resultSym.typ) == etyBaseIndex:
      resultAsgn = p.indentLine(("var $# = null;$n") % [mname])
      resultAsgn.add p.indentLine("var $#_Idx = 0;$n" % [mname])
    else:
      let resVar = createVar(p, resultSym.typ, isIndirect(resultSym))
      resultAsgn = p.indentLine(("var $# = $#;$n") % [mname, resVar])
    gen(p, prc.ast.sons[resultPos], a)
    if mapType(p, resultSym.typ) == etyBaseIndex:
      returnStmt = "return [$#, $#];$n" % [a.address, a.res]
    else:
      returnStmt = "return $#;$n" % [a.res]

  let transformedBody = transformBody(oldProc.module.graph, prc, cache = false)
  p.nested: genStmt(p, transformedBody)

  var def: Rope
  if not prc.constraint.isNil:
    def = runtimeFormat(prc.constraint.strVal & " {$n$#$#$#$#$#",
            [ returnType,
              name,
              header,
              optionalLine(p.globals),
              optionalLine(p.locals),
              optionalLine(resultAsgn),
              optionalLine(genProcBody(p, prc)),
              optionalLine(p.indentLine(returnStmt))])
  else:
    result = ~"\L"

    if p.config.hcrOn:
      # Here, we introduce thunks that create the equivalent of a jump table
      # for all global functions, because references to them may be stored
      # in JavaScript variables. The added indirection ensures that such
      # references will end up calling the reloaded code.
      var thunkName = name
      name = name & "IMLP"
      result.add("function $#() { return $#.apply(this, arguments); }$n" %
                 [thunkName, name])

    def = "function $#($#) {$n$#$#$#$#$#" %
            [ name,
              header,
              optionalLine(p.globals),
              optionalLine(p.locals),
              optionalLine(resultAsgn),
              optionalLine(genProcBody(p, prc)),
              optionalLine(p.indentLine(returnStmt))]

  dec p.extraIndent
  result.add p.indentLine(def)
  result.add p.indentLine(~"}$n")

  #if gVerbosity >= 3:
  #  echo "END   generated code for: " & prc.name.s

proc genStmt(p: PProc, n: PNode) =
  var r: TCompRes
  gen(p, n, r)
  if r.res != nil: lineF(p, "$#;$n", [r.res])

proc genPragma(p: PProc, n: PNode) =
  for it in n.sons:
    case whichPragma(it)
    of wEmit: genAsmOrEmitStmt(p, it.sons[1])
    else: discard

proc genCast(p: PProc, n: PNode, r: var TCompRes) =
  var dest = skipTypes(n.typ, abstractVarRange)
  var src = skipTypes(n.sons[1].typ, abstractVarRange)
  gen(p, n.sons[1], r)
  if dest.kind == src.kind:
    # no-op conversion
    return
  let toInt = (dest.kind in tyInt..tyInt32)
  let toUint = (dest.kind in tyUInt..tyUInt32)
  let fromInt = (src.kind in tyInt..tyInt32)
  let fromUint = (src.kind in tyUInt..tyUInt32)

  if toUint and (fromInt or fromUint):
    let trimmer = unsignedTrimmer(dest.size)
    r.res = "($1 $2)" % [r.res, trimmer]
  elif toInt:
    if fromInt:
      let trimmer = unsignedTrimmer(dest.size)
      r.res = "($1 $2)" % [r.res, trimmer]
    elif fromUint:
      if src.size == 4 and dest.size == 4:
        # XXX prevent multi evaluations
        r.res = "($1|0)" % [r.res]
      else:
        let trimmer = unsignedTrimmer(dest.size)
        let minuend = case dest.size
          of 1: "0xfe"
          of 2: "0xfffe"
          of 4: "0xfffffffe"
          else: ""
        r.res = "($1 - ($2 $3))" % [rope minuend, r.res, trimmer]
  elif (src.kind == tyPtr and mapType(p, src) == etyObject) and dest.kind == tyPointer:
    r.address = r.res
    r.res = ~"null"
    r.typ = etyBaseIndex
  elif (dest.kind == tyPtr and mapType(p, dest) == etyObject) and src.kind == tyPointer:
    r.res = r.address
    r.typ = etyObject

proc gen(p: PProc, n: PNode, r: var TCompRes) =
  r.typ = etyNone
  if r.kind != resCallee: r.kind = resNone
  #r.address = nil
  r.res = nil
  case n.kind
  of nkSym:
    genSym(p, n, r)
  of nkCharLit..nkUInt64Lit:
    if n.typ.kind == tyBool:
      r.res = if n.intVal == 0: rope"false" else: rope"true"
    else:
      r.res = rope(n.intVal)
    r.kind = resExpr
  of nkNilLit:
    if isEmptyType(n.typ):
      discard
    elif mapType(p, n.typ) == etyBaseIndex:
      r.typ = etyBaseIndex
      r.address = rope"null"
      r.res = rope"0"
      r.kind = resExpr
    else:
      r.res = rope"null"
      r.kind = resExpr
  of nkStrLit..nkTripleStrLit:
    if skipTypes(n.typ, abstractVarRange).kind == tyString:
      if n.strVal.len != 0:
        useMagic(p, "makeNimstrLit")
        r.res = "makeNimstrLit($1)" % [makeJSString(n.strVal)]
      else:
        r.res = rope"[]"
    else:
      r.res = makeJSString(n.strVal, false)
    r.kind = resExpr
  of nkFloatLit..nkFloat64Lit:
    let f = n.floatVal
    case classify(f)
    of fcNan:
      r.res = rope"NaN"
    of fcNegZero:
      r.res = rope"-0.0"
    of fcZero:
      r.res = rope"0.0"
    of fcInf:
      r.res = rope"Infinity"
    of fcNegInf:
      r.res = rope"-Infinity"
    else: r.res = rope(f.toStrMaxPrecision)
    r.kind = resExpr
  of nkCallKinds:
    if isEmptyType(n.typ): genLineDir(p, n)
    if (n.sons[0].kind == nkSym) and (n.sons[0].sym.magic != mNone):
      genMagic(p, n, r)
    elif n.sons[0].kind == nkSym and sfInfixCall in n.sons[0].sym.flags and
        n.len >= 1:
      genInfixCall(p, n, r)
    else:
      genCall(p, n, r)
  of nkClosure: gen(p, n[0], r)
  of nkCurly: genSetConstr(p, n, r)
  of nkBracket: genArrayConstr(p, n, r)
  of nkPar, nkTupleConstr: genTupleConstr(p, n, r)
  of nkObjConstr: genObjConstr(p, n, r)
  of nkHiddenStdConv, nkHiddenSubConv, nkConv: genConv(p, n, r)
  of nkAddr, nkHiddenAddr:
    genAddr(p, n, r)
  of nkDerefExpr, nkHiddenDeref: genDeref(p, n, r)
  of nkBracketExpr: genArrayAccess(p, n, r)
  of nkDotExpr: genFieldAccess(p, n, r)
  of nkCheckedFieldExpr: genCheckedFieldOp(p, n, nil, r)
  of nkObjDownConv: gen(p, n.sons[0], r)
  of nkObjUpConv: upConv(p, n, r)
  of nkCast: genCast(p, n, r)
  of nkChckRangeF: genRangeChck(p, n, r, "chckRangeF")
  of nkChckRange64: genRangeChck(p, n, r, "chckRange64")
  of nkChckRange: genRangeChck(p, n, r, "chckRange")
  of nkStringToCString: convStrToCStr(p, n, r)
  of nkCStringToString: convCStrToStr(p, n, r)
  of nkEmpty: discard
  of nkLambdaKinds:
    let s = n.sons[namePos].sym
    discard mangleName(p.module, s)
    r.res = s.loc.r
    if lfNoDecl in s.loc.flags or s.magic != mNone: discard
    elif not p.g.generatedSyms.containsOrIncl(s.id):
      add(p.locals, genProc(p, s))
  of nkType: r.res = genTypeInfo(p, n.typ)
  of nkStmtList, nkStmtListExpr:
    # this shows the distinction is nice for backends and should be kept
    # in the frontend
    let isExpr = not isEmptyType(n.typ)
    for i in 0 ..< sonsLen(n) - isExpr.ord:
      genStmt(p, n.sons[i])
    if isExpr:
      gen(p, lastSon(n), r)
  of nkBlockStmt, nkBlockExpr: genBlock(p, n, r)
  of nkIfStmt, nkIfExpr: genIf(p, n, r)
  of nkWhen:
    # This is "when nimvm" node
    gen(p, n.sons[1].sons[0], r)
  of nkWhileStmt: genWhileStmt(p, n)
  of nkVarSection, nkLetSection: genVarStmt(p, n)
  of nkConstSection: discard
  of nkForStmt, nkParForStmt:
    internalError(p.config, n.info, "for statement not eliminated")
  of nkCaseStmt: genCaseJS(p, n, r)
  of nkReturnStmt: genReturnStmt(p, n)
  of nkBreakStmt: genBreakStmt(p, n)
  of nkAsgn: genAsgn(p, n)
  of nkFastAsgn: genFastAsgn(p, n)
  of nkDiscardStmt:
    if n.sons[0].kind != nkEmpty:
      genLineDir(p, n)
      gen(p, n.sons[0], r)
  of nkAsmStmt: genAsmOrEmitStmt(p, n)
  of nkTryStmt, nkHiddenTryStmt: genTry(p, n, r)
  of nkRaiseStmt: genRaiseStmt(p, n)
  of nkTypeSection, nkCommentStmt, nkIteratorDef, nkIncludeStmt,
     nkImportStmt, nkImportExceptStmt, nkExportStmt, nkExportExceptStmt,
     nkFromStmt, nkTemplateDef, nkMacroDef, nkStaticStmt: discard
  of nkPragma: genPragma(p, n)
  of nkProcDef, nkFuncDef, nkMethodDef, nkConverterDef:
    var s = n.sons[namePos].sym
    if {sfExportc, sfCompilerProc} * s.flags == {sfExportc}:
      genSym(p, n.sons[namePos], r)
      r.res = nil
  of nkGotoState, nkState:
    internalError(p.config, n.info, "first class iterators not implemented")
  of nkPragmaBlock: gen(p, n.lastSon, r)
  of nkComesFrom:
    discard "XXX to implement for better stack traces"
  else: internalError(p.config, n.info, "gen: unknown node type: " & $n.kind)

proc newModule(g: ModuleGraph; module: PSym): BModule =
  new(result)
  result.module = module
  result.sigConflicts = initCountTable[SigHash]()
  if g.backend == nil:
    g.backend = newGlobals()
  result.graph = g
  result.config = g.config

proc genHeader(): Rope =
  result = (
    "/* Generated by the Nim Compiler v$1 */$n" &
    "/*   (c) " & copyrightYear & " Andreas Rumpf */$n$n" &
    "var framePtr = null;$n" &
    "var excHandler = 0;$n" &
    "var lastJSError = null;$n" &
    "if (typeof Int8Array === 'undefined') Int8Array = Array;$n" &
    "if (typeof Int16Array === 'undefined') Int16Array = Array;$n" &
    "if (typeof Int32Array === 'undefined') Int32Array = Array;$n" &
    "if (typeof Uint8Array === 'undefined') Uint8Array = Array;$n" &
    "if (typeof Uint16Array === 'undefined') Uint16Array = Array;$n" &
    "if (typeof Uint32Array === 'undefined') Uint32Array = Array;$n" &
    "if (typeof Float32Array === 'undefined') Float32Array = Array;$n" &
    "if (typeof Float64Array === 'undefined') Float64Array = Array;$n") %
    [rope(VersionAsString)]

proc addHcrInitGuards(p: PProc, n: PNode,
                      moduleLoadedVar: Rope, inInitGuard: var bool) =
  if n.kind == nkStmtList:
    for child in n:
      addHcrInitGuards(p, child, moduleLoadedVar, inInitGuard)
  else:
    let stmtShouldExecute = n.kind in {
      nkProcDef, nkFuncDef, nkMethodDef,nkConverterDef,
      nkVarSection, nkLetSection} or nfExecuteOnReload in n.flags

    if inInitGuard:
      if stmtShouldExecute:
        dec p.extraIndent
        line(p, "}\L")
        inInitGuard = false
    else:
      if not stmtShouldExecute:
        lineF(p, "if ($1 == undefined) {$n", [moduleLoadedVar])
        inc p.extraIndent
        inInitGuard = true

    genStmt(p, n)

proc genModule(p: PProc, n: PNode) =
  if optStackTrace in p.options:
    add(p.body, frameCreate(p,
        makeJSString("module " & p.module.module.name.s),
        makeJSString(toFilename(p.config, p.module.module.info))))
  let transformedN = transformStmt(p.module.graph, p.module.module, n)
  if p.config.hcrOn and n.kind == nkStmtList:
    let moduleSym = p.module.module
    var moduleLoadedVar = rope(moduleSym.name.s) & "_loaded" &
                          idOrSig(moduleSym, moduleSym.name.s, p.module.sigConflicts)
    lineF(p, "var $1;$n", [moduleLoadedVar])
    var inGuardedBlock = false

    addHcrInitGuards(p, transformedN, moduleLoadedVar, inGuardedBlock)

    if inGuardedBlock:
      dec p.extraIndent
      line(p, "}\L")

    lineF(p, "$1 = true;$n", [moduleLoadedVar])
  else:
    genStmt(p, transformedN)

  if optStackTrace in p.options:
    add(p.body, frameDestroy(p))

proc myProcess(b: PPassContext, n: PNode): PNode =
  result = n
  let m = BModule(b)
  if passes.skipCodegen(m.config, n): return n
  if m.module == nil: internalError(m.config, n.info, "myProcess")
  let globals = PGlobals(m.graph.backend)
  var p = newProc(globals, m, nil, m.module.options)
  p.unique = globals.unique
  genModule(p, n)
  add(p.g.code, p.locals)
  add(p.g.code, p.body)

proc wholeCode(graph: ModuleGraph; m: BModule): Rope =
  let globals = PGlobals(graph.backend)
  for prc in globals.forwarded:
    if not globals.generatedSyms.containsOrIncl(prc.id):
      var p = newProc(globals, m, nil, m.module.options)
      attachProc(p, prc)

  var disp = generateMethodDispatchers(graph)
  for i in 0..sonsLen(disp)-1:
    let prc = disp.sons[i].sym
    if not globals.generatedSyms.containsOrIncl(prc.id):
      var p = newProc(globals, m, nil, m.module.options)
      attachProc(p, prc)

  result = globals.typeInfo & globals.constants & globals.code

proc getClassName(t: PType): Rope =
  var s = t.sym
  if s.isNil or sfAnon in s.flags:
    s = skipTypes(t, abstractPtrs).sym
  if s.isNil or sfAnon in s.flags:
    doAssert(false, "cannot retrieve class name")
  if s.loc.r != nil: result = s.loc.r
  else: result = rope(s.name.s)

proc myClose(graph: ModuleGraph; b: PPassContext, n: PNode): PNode =
  result = myProcess(b, n)
  var m = BModule(b)
  if sfMainModule in m.module.flags:
    for destructorCall in graph.globalDestructors:
      n.add destructorCall
  if passes.skipCodegen(m.config, n): return n
  if sfMainModule in m.module.flags:
    let code = wholeCode(graph, m)
    let outFile = m.config.prepareToWriteOutput()
    discard writeRopeIfNotEqual(genHeader() & code, outFile)

proc myOpen(graph: ModuleGraph; s: PSym): PPassContext =
  result = newModule(graph, s)

const JSgenPass* = makePass(myOpen, myProcess, myClose)
