#
#
#           The Nim Compiler
#        (c) Copyright 2013 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

## This module implements the signature matching for resolving
## the call to overloaded procs, generic procs and operators.

import
  intsets, ast, astalgo, semdata, types, msgs, renderer, lookups, semtypinst,
  magicsys, idents, lexer, options, parampatterns, strutils, trees,
  linter, lineinfos, lowerings, modulegraphs

when (defined(booting) or defined(nimsuggest)) and not defined(leanCompiler):
  import docgen

type
  MismatchKind* = enum
    kUnknown, kAlreadyGiven, kUnknownNamedParam, kTypeMismatch, kVarNeeded,
    kMissingParam, kExtraArg, kPositionalAlreadyGiven

  MismatchInfo* = object
    kind*: MismatchKind # reason for mismatch
    arg*: int           # position of provided arguments that mismatches
    formal*: PSym       # parameter that mismatches against provided argument
                        # its position can differ from `arg` because of varargs

  TCandidateState* = enum
    csEmpty, csMatch, csNoMatch

  CandidateError* = object
    sym*: PSym
    firstMismatch*: MismatchInfo
    diagnostics*: seq[string]
    enabled*: bool

  CandidateErrors* = seq[CandidateError]

  TCandidate* = object
    c*: PContext
    exactMatches*: int       # also misused to prefer iters over procs
    genericMatches: int      # also misused to prefer constraints
    subtypeMatches: int
    intConvMatches: int      # conversions to int are not as expensive
    convMatches: int
    state*: TCandidateState
    callee*: PType           # may not be nil!
    calleeSym*: PSym         # may be nil
    calleeScope*: int        # scope depth:
                             # is this a top-level symbol or a nested proc?
    call*: PNode             # modified call
    bindings*: TIdTable      # maps types to types
    magic*: TMagic           # magic of operation
    baseTypeMatch: bool      # needed for conversions from T to openarray[T]
                             # for example
    fauxMatch*: TTypeKind    # the match was successful only due to the use
                             # of error or wildcard (unknown) types.
                             # this is used to prevent instantiations.
    genericConverter*: bool  # true if a generic converter needs to
                             # be instantiated
    coerceDistincts*: bool   # this is an explicit coercion that can strip away
                             # a distrinct type
    typedescMatched*: bool
    isNoCall*: bool          # misused for generic type instantiations C[T]
    inferredTypes: seq[PType] # inferred types during the current signature
                              # matching. they will be reset if the matching
                              # is not successful. may replace the bindings
                              # table in the future.
    diagnostics*: seq[string] # \
                              # when diagnosticsEnabled, the matching process
                              # will collect extra diagnostics that will be
                              # displayed to the user.
                              # triggered when overload resolution fails
                              # or when the explain pragma is used. may be
                              # triggered with an idetools command in the
                              # future.
    inheritancePenalty: int   # to prefer closest father object type
    firstMismatch*: MismatchInfo # mismatch info for better error messages
    diagnosticsEnabled*: bool

  TTypeRelFlag* = enum
    trDontBind
    trNoCovariance

  TTypeRelFlags* = set[TTypeRelFlag]

  TTypeRelation* = enum      # order is important!
    isNone, isConvertible,
    isIntConv,
    isSubtype,
    isSubrange,              # subrange of the wanted type; no type conversion
                             # but apart from that counts as ``isSubtype``
    isBothMetaConvertible    # generic proc parameter was matched against
                             # generic type, e.g., map(mySeq, x=>x+1),
                             # maybe recoverable by rerun if the parameter is
                             # the proc's return value
    isInferred,              # generic proc was matched against a concrete type
    isInferredConvertible,   # same as above, but requiring proc CC conversion
    isGeneric,
    isFromIntLit,            # conversion *from* int literal; proven safe
    isEqual

const
  isNilConversion = isConvertible # maybe 'isIntConv' fits better?

proc markUsed*(c: PContext; info: TLineInfo, s: PSym; usageSym: var PSym)

template hasFauxMatch*(c: TCandidate): bool = c.fauxMatch != tyNone

proc initCandidateAux(ctx: PContext,
                      c: var TCandidate, callee: PType) {.inline.} =
  c.c = ctx
  c.exactMatches = 0
  c.subtypeMatches = 0
  c.convMatches = 0
  c.intConvMatches = 0
  c.genericMatches = 0
  c.state = csEmpty
  c.firstMismatch = MismatchInfo()
  c.callee = callee
  c.call = nil
  c.baseTypeMatch = false
  c.genericConverter = false
  c.inheritancePenalty = 0

proc initCandidate*(ctx: PContext, c: var TCandidate, callee: PType) =
  initCandidateAux(ctx, c, callee)
  c.calleeSym = nil
  initIdTable(c.bindings)

proc put(c: var TCandidate, key, val: PType) {.inline.} =
  when false:
    let old = PType(idTableGet(c.bindings, key))
    if old != nil:
      echo "Putting ", typeToString(key), " ", typeToString(val), " and old is ", typeToString(old)
      if typeToString(old) == "seq[string]":
        writeStackTrace()
    if c.c.module.name.s == "temp3":
      echo "binding ", key, " -> ", val
  idTablePut(c.bindings, key, val.skipIntLit)

proc initCandidate*(ctx: PContext, c: var TCandidate, callee: PSym,
                    binding: PNode, calleeScope = -1,
                    diagnosticsEnabled = false) =
  initCandidateAux(ctx, c, callee.typ)
  c.calleeSym = callee
  if callee.kind in skProcKinds and calleeScope == -1:
    if callee.originatingModule == ctx.module:
      c.calleeScope = 2
      var owner = callee
      while true:
        owner = owner.skipGenericOwner
        if owner.kind == skModule: break
        inc c.calleeScope
    else:
      c.calleeScope = 1
  else:
    c.calleeScope = calleeScope
  c.diagnostics = @[] # if diagnosticsEnabled: @[] else: nil
  c.diagnosticsEnabled = diagnosticsEnabled
  c.magic = c.calleeSym.magic
  initIdTable(c.bindings)
  if binding != nil and callee.kind in routineKinds:
    var typeParams = callee.ast[genericParamsPos]
    for i in 1..min(sonsLen(typeParams), sonsLen(binding)-1):
      var formalTypeParam = typeParams.sons[i-1].typ
      var bound = binding[i].typ
      if bound != nil:
        if formalTypeParam.kind == tyTypeDesc:
          if bound.kind != tyTypeDesc:
            bound = makeTypeDesc(ctx, bound)
        else:
          bound = bound.skipTypes({tyTypeDesc})
        put(c, formalTypeParam, bound)

proc newCandidate*(ctx: PContext, callee: PSym,
                   binding: PNode, calleeScope = -1): TCandidate =
  initCandidate(ctx, result, callee, binding, calleeScope)

proc newCandidate*(ctx: PContext, callee: PType): TCandidate =
  initCandidate(ctx, result, callee)

proc copyCandidate(a: var TCandidate, b: TCandidate) =
  a.c = b.c
  a.exactMatches = b.exactMatches
  a.subtypeMatches = b.subtypeMatches
  a.convMatches = b.convMatches
  a.intConvMatches = b.intConvMatches
  a.genericMatches = b.genericMatches
  a.state = b.state
  a.callee = b.callee
  a.calleeSym = b.calleeSym
  a.call = copyTree(b.call)
  a.baseTypeMatch = b.baseTypeMatch
  copyIdTable(a.bindings, b.bindings)

proc sumGeneric(t: PType): int =
  # count the "genericness" so that Foo[Foo[T]] has the value 3
  # and Foo[T] has the value 2 so that we know Foo[Foo[T]] is more
  # specific than Foo[T].
  var t = t
  var isvar = 1
  while true:
    case t.kind
    of tyGenericInst, tyArray, tyRef, tyPtr, tyDistinct, tyUncheckedArray,
        tyOpenArray, tyVarargs, tySet, tyRange, tySequence, tyGenericBody,
        tyLent, tyOwned:
      t = t.lastSon
      inc result
    of tyOr:
      var maxBranch = 0
      for branch in t.sons:
        let branchSum = sumGeneric(branch)
        if branchSum > maxBranch: maxBranch = branchSum
      inc result, maxBranch
      break
    of tyVar:
      t = t.sons[0]
      inc result
      inc isvar
    of tyTypeDesc:
      t = t.lastSon
      if t.kind == tyEmpty: break
      inc result
    of tyGenericInvocation, tyTuple, tyProc, tyAnd:
      result += ord(t.kind in {tyGenericInvocation, tyAnd})
      for i in 0 ..< t.len:
        if t.sons[i] != nil:
          result += sumGeneric(t.sons[i])
      break
    of tyStatic:
      return sumGeneric(t.sons[0]) + 1
    of tyGenericParam, tyUntyped, tyTyped: break
    of tyAlias, tySink: t = t.lastSon
    of tyBool, tyChar, tyEnum, tyObject, tyPointer,
        tyString, tyCString, tyInt..tyInt64, tyFloat..tyFloat128,
        tyUInt..tyUInt64, tyCompositeTypeClass:
      return isvar
    else:
      return 0

#var ggDebug: bool

proc complexDisambiguation(a, b: PType): int =
  # 'a' matches better if *every* argument matches better or equal than 'b'.
  var winner = 0
  for i in 1 ..< min(a.len, b.len):
    let x = a.sons[i].sumGeneric
    let y = b.sons[i].sumGeneric
    #if ggDebug:
    #echo "came herA ", typeToString(a.sons[i]), " ", x
    #echo "came herB ", typeToString(b.sons[i]), " ", y
    if x != y:
      if winner == 0:
        if x > y: winner = 1
        else: winner = -1
      elif x > y:
        if winner != 1:
          # contradiction
          return 0
      else:
        if winner != -1:
          return 0
  result = winner
  when false:
    var x, y: int
    for i in 1 ..< a.len: x += a.sons[i].sumGeneric
    for i in 1 ..< b.len: y += b.sons[i].sumGeneric
    result = x - y

proc writeMatches*(c: TCandidate) =
  echo "Candidate '", c.calleeSym.name.s, "' at ", c.c.config $ c.calleeSym.info
  echo "  exact matches: ", c.exactMatches
  echo "  generic matches: ", c.genericMatches
  echo "  subtype matches: ", c.subtypeMatches
  echo "  intconv matches: ", c.intConvMatches
  echo "  conv matches: ", c.convMatches
  echo "  inheritance: ", c.inheritancePenalty

proc cmpCandidates*(a, b: TCandidate): int =
  result = a.exactMatches - b.exactMatches
  if result != 0: return
  result = a.genericMatches - b.genericMatches
  if result != 0: return
  result = a.subtypeMatches - b.subtypeMatches
  if result != 0: return
  result = a.intConvMatches - b.intConvMatches
  if result != 0: return
  result = a.convMatches - b.convMatches
  if result != 0: return
  # the other way round because of other semantics:
  result = b.inheritancePenalty - a.inheritancePenalty
  if result != 0: return
  # prefer more specialized generic over more general generic:
  result = complexDisambiguation(a.callee, b.callee)
  # only as a last resort, consider scoping:
  if result != 0: return
  result = a.calleeScope - b.calleeScope

proc argTypeToString(arg: PNode; prefer: TPreferedDesc): string =
  if arg.kind in nkSymChoices:
    result = typeToString(arg[0].typ, prefer)
    for i in 1 ..< arg.len:
      result.add(" | ")
      result.add typeToString(arg[i].typ, prefer)
  elif arg.typ == nil:
    result = "void"
  else:
    result = arg.typ.typeToString(prefer)

proc describeArgs*(c: PContext, n: PNode, startIdx = 1;
                   prefer: TPreferedDesc = preferName): string =
  result = ""
  for i in startIdx ..< n.len:
    var arg = n.sons[i]
    if n.sons[i].kind == nkExprEqExpr:
      add(result, renderTree(n.sons[i].sons[0]))
      add(result, ": ")
      if arg.typ.isNil and arg.kind notin {nkStmtList, nkDo}:
        # XXX we really need to 'tryExpr' here!
        arg = c.semOperand(c, n.sons[i].sons[1])
        n.sons[i].typ = arg.typ
        n.sons[i].sons[1] = arg
    else:
      if arg.typ.isNil and arg.kind notin {nkStmtList, nkDo, nkElse,
                                           nkOfBranch, nkElifBranch,
                                           nkExceptBranch}:
        arg = c.semOperand(c, n.sons[i])
        n.sons[i] = arg
    if arg.typ != nil and arg.typ.kind == tyError: return
    add(result, argTypeToString(arg, prefer))
    if i != sonsLen(n) - 1: add(result, ", ")

proc typeRel*(c: var TCandidate, f, aOrig: PType,
              flags: TTypeRelFlags = {}): TTypeRelation

proc concreteType(c: TCandidate, t: PType; f: PType = nil): PType =
  case t.kind
  of tyTypeDesc:
    if c.isNoCall: result = t
    else: result = nil
  of tySequence, tySet:
    if t.sons[0].kind == tyEmpty: result = nil
    else: result = t
  of tyGenericParam, tyAnything:
    result = t
    while true:
      result = PType(idTableGet(c.bindings, t))
      if result == nil:
        break # it's ok, no match
        # example code that triggers it:
        # proc sort[T](cmp: proc(a, b: T): int = cmp)
      if result.kind != tyGenericParam: break
  of tyGenericInvocation:
    result = t
    doAssert(false, "cannot resolve type: " & typeToString(t))
  of tyOwned:
    # bug #11257: the comparison system.`==`[T: proc](x, y: T) works
    # better without the 'owned' type:
    if f != nil and f.len > 0 and f.sons[0].skipTypes({tyBuiltInTypeClass}).kind == tyProc:
      result = t.lastSon
    else:
      result = t
  else:
    result = t                # Note: empty is valid here

proc handleRange(f, a: PType, min, max: TTypeKind): TTypeRelation =
  if a.kind == f.kind:
    result = isEqual
  else:
    let ab = skipTypes(a, {tyRange})
    let k = ab.kind
    if k == f.kind: result = isSubrange
    elif k == tyInt and f.kind in {tyRange, tyInt8..tyInt64,
                                   tyUInt..tyUInt64} and
        isIntLit(ab) and getInt(ab.n) >= firstOrd(nil, f) and
                         getInt(ab.n) <= lastOrd(nil, f):
      # passing 'nil' to firstOrd/lastOrd here as type checking rules should
      # not depent on the target integer size configurations!
      # integer literal in the proper range; we want ``i16 + 4`` to stay an
      # ``int16`` operation so we declare the ``4`` pseudo-equal to int16
      result = isFromIntLit
    elif f.kind == tyInt and k in {tyInt8..tyInt32}:
      result = isIntConv
    elif f.kind == tyUInt and k in {tyUInt8..tyUInt32}:
      result = isIntConv
    elif k >= min and k <= max:
      result = isConvertible
    elif a.kind == tyRange and
      # Make sure the conversion happens between types w/ same signedness
      (f.kind in {tyInt..tyInt64} and a[0].kind in {tyInt..tyInt64} or
       f.kind in {tyUInt8..tyUInt32} and a[0].kind in {tyUInt8..tyInt32}) and
      a.n[0].intVal >= firstOrd(nil, f) and a.n[1].intVal <= lastOrd(nil, f):
      # passing 'nil' to firstOrd/lastOrd here as type checking rules should
      # not depent on the target integer size configurations!
      result = isConvertible
    else: result = isNone

proc isConvertibleToRange(f, a: PType): bool =
  # be less picky for tyRange, as that it is used for array indexing:
  if f.kind in {tyInt..tyInt64, tyUInt..tyUInt64} and
     a.kind in {tyInt..tyInt64, tyUInt..tyUInt64}:
    case f.kind
    of tyInt, tyInt64: result = true
    of tyInt8: result = a.kind in {tyInt8, tyInt}
    of tyInt16: result = a.kind in {tyInt8, tyInt16, tyInt}
    of tyInt32: result = a.kind in {tyInt8, tyInt16, tyInt32, tyInt}
    of tyUInt, tyUInt64: result = true
    of tyUInt8: result = a.kind in {tyUInt8, tyUInt}
    of tyUInt16: result = a.kind in {tyUInt8, tyUInt16, tyUInt}
    of tyUInt32: result = a.kind in {tyUInt8, tyUInt16, tyUInt32, tyUInt}
    else: result = false
  elif f.kind in {tyFloat..tyFloat128} and
       a.kind in {tyFloat..tyFloat128}:
    result = true

proc handleFloatRange(f, a: PType): TTypeRelation =
  if a.kind == f.kind:
    result = isEqual
  else:
    let ab = skipTypes(a, {tyRange})
    var k = ab.kind
    if k == f.kind: result = isSubrange
    elif isFloatLit(ab): result = isFromIntLit
    elif isIntLit(ab): result = isConvertible
    elif k >= tyFloat and k <= tyFloat128:
      # conversion to "float32" is not as good:
      if f.kind == tyFloat32: result = isConvertible
      else: result = isIntConv
    else: result = isNone

proc genericParamPut(c: var TCandidate; last, fGenericOrigin: PType) =
  if fGenericOrigin != nil and last.kind == tyGenericInst and
     last.len-1 == fGenericOrigin.len:
    for i in 1 ..< sonsLen(fGenericOrigin):
      let x = PType(idTableGet(c.bindings, fGenericOrigin.sons[i]))
      if x == nil:
        put(c, fGenericOrigin.sons[i], last.sons[i])

proc isObjectSubtype(c: var TCandidate; a, f, fGenericOrigin: PType): int =
  var t = a
  assert t.kind == tyObject
  var depth = 0
  var last = a
  while t != nil and not sameObjectTypes(f, t):
    assert t.kind == tyObject
    t = t.sons[0]
    if t == nil: break
    last = t
    t = skipTypes(t, skipPtrs)
    inc depth
  if t != nil:
    genericParamPut(c, last, fGenericOrigin)
    result = depth
  else:
    result = -1

type
  SkippedPtr = enum skippedNone, skippedRef, skippedPtr

proc skipToObject(t: PType; skipped: var SkippedPtr): PType =
  var r = t
  # we're allowed to skip one level of ptr/ref:
  var ptrs = 0
  while r != nil:
    case r.kind
    of tyGenericInvocation:
      r = r.sons[0]
    of tyRef:
      inc ptrs
      skipped = skippedRef
      r = r.lastSon
    of tyPtr:
      inc ptrs
      skipped = skippedPtr
      r = r.lastSon
    of tyGenericBody, tyGenericInst, tyAlias, tySink, tyOwned:
      r = r.lastSon
    else:
      break
  if r.kind == tyObject and ptrs <= 1: result = r

proc isGenericSubtype(c: var TCandidate; a, f: PType, d: var int, fGenericOrigin: PType): bool =
  assert f.kind in {tyGenericInst, tyGenericInvocation, tyGenericBody}
  var askip = skippedNone
  var fskip = skippedNone
  var t = a.skipToObject(askip)
  let r = f.skipToObject(fskip)
  if r == nil: return false
  var depth = 0
  var last = a
  # XXX sameObjectType can return false here. Need to investigate
  # why that is but sameObjectType does way too much work here anyway.
  while t != nil and r.sym != t.sym and askip == fskip:
    t = t.sons[0]
    if t == nil: break
    last = t
    t = t.skipToObject(askip)
    inc depth
  if t != nil and askip == fskip:
    genericParamPut(c, last, fGenericOrigin)
    d = depth
    result = true

proc minRel(a, b: TTypeRelation): TTypeRelation =
  if a <= b: result = a
  else: result = b

proc recordRel(c: var TCandidate, f, a: PType): TTypeRelation =
  result = isNone
  if sameType(f, a):
    result = isEqual
  elif sonsLen(a) == sonsLen(f):
    result = isEqual
    let firstField = if f.kind == tyTuple: 0
                     else: 1
    for i in firstField ..< sonsLen(f):
      var m = typeRel(c, f.sons[i], a.sons[i])
      if m < isSubtype: return isNone
      result = minRel(result, m)
    if f.n != nil and a.n != nil:
      for i in 0 ..< sonsLen(f.n):
        # check field names:
        if f.n.sons[i].kind != nkSym: return isNone
        elif a.n.sons[i].kind != nkSym: return isNone
        else:
          var x = f.n.sons[i].sym
          var y = a.n.sons[i].sym
          if f.kind == tyObject and typeRel(c, x.typ, y.typ) < isSubtype:
            return isNone
          if x.name.id != y.name.id: return isNone

proc allowsNil(f: PType): TTypeRelation {.inline.} =
  result = if tfNotNil notin f.flags: isSubtype else: isNone

proc allowsNilDeprecated(c: TCandidate, f: PType): TTypeRelation =
  if optNilSeqs in c.c.config.options:
    result = allowsNil(f)
  else:
    result = isNone

proc inconsistentVarTypes(f, a: PType): bool {.inline.} =
  result = f.kind != a.kind and (f.kind in {tyVar, tyLent} or a.kind in {tyVar, tyLent})

proc procParamTypeRel(c: var TCandidate, f, a: PType): TTypeRelation =
  ## For example we have:
  ## .. code-block:: nim
  ##   proc myMap[T,S](sIn: seq[T], f: proc(x: T): S): seq[S] = ...
  ##   proc innerProc[Q,W](q: Q): W = ...
  ## And we want to match: myMap(@[1,2,3], innerProc)
  ## This proc (procParamTypeRel) will do the following steps in
  ## three different calls:
  ## - matches f=T to a=Q. Since f is metatype, we resolve it
  ##    to int (which is already known at this point). So in this case
  ##    Q=int mapping will be saved to c.bindings.
  ## - matches f=S to a=W. Both of these metatypes are unknown, so we
  ##    return with isBothMetaConvertible to ask for rerun.
  ## - matches f=S to a=W. At this point the return type of innerProc
  ##    is known (we get it from c.bindings). We can use that value
  ##    to match with f, and save back to c.bindings.
  var
    f = f
    a = a

  if a.isMetaType:
    let aResolved = PType(idTableGet(c.bindings, a))
    if aResolved != nil:
      a = aResolved
  if a.isMetaType:
    if f.isMetaType:
      # We are matching a generic proc (as proc param)
      # to another generic type appearing in the proc
      # signature. There is a change that the target
      # type is already fully-determined, so we are
      # going to try resolve it
      if c.call != nil:
        f = generateTypeInstance(c.c, c.bindings, c.call.info, f)
      else:
        f = nil
      if f == nil or f.isMetaType:
        # no luck resolving the type, so the inference fails
        return isBothMetaConvertible
    # Note that this typeRel call will save a's resolved type into c.bindings
    let reverseRel = typeRel(c, a, f)
    if reverseRel >= isGeneric:
      result = isInferred
      #inc c.genericMatches
  else:
    # Note that this typeRel call will save f's resolved type into c.bindings
    # if f is metatype.
    result = typeRel(c, f, a)

  if result <= isSubtype or inconsistentVarTypes(f, a):
    result = isNone

  #if result == isEqual:
  #  inc c.exactMatches

proc procTypeRel(c: var TCandidate, f, a: PType): TTypeRelation =
  case a.kind
  of tyProc:
    if sonsLen(f) != sonsLen(a): return
    result = isEqual      # start with maximum; also correct for no
                          # params at all

    template checkParam(f, a) =
      result = minRel(result, procParamTypeRel(c, f, a))
      if result == isNone: return

    # Note: We have to do unification for the parameters before the
    # return type!
    for i in 1 ..< f.sonsLen:
      checkParam(f.sons[i], a.sons[i])

    if f.sons[0] != nil:
      if a.sons[0] != nil:
        checkParam(f.sons[0], a.sons[0])
      else:
        return isNone
    elif a.sons[0] != nil:
      return isNone

    if tfNoSideEffect in f.flags and tfNoSideEffect notin a.flags:
      return isNone
    elif tfThread in f.flags and a.flags * {tfThread, tfNoSideEffect} == {} and
        optThreadAnalysis in c.c.config.globalOptions:
      # noSideEffect implies ``tfThread``!
      return isNone
    elif f.flags * {tfIterator} != a.flags * {tfIterator}:
      return isNone
    elif f.callConv != a.callConv:
      # valid to pass a 'nimcall' thingie to 'closure':
      if f.callConv == ccClosure and a.callConv == ccDefault:
        result = if result == isInferred: isInferredConvertible
                 elif result == isBothMetaConvertible: isBothMetaConvertible
                 else: isConvertible
      else:
        return isNone
    when useEffectSystem:
      if compatibleEffects(f, a) != efCompat: return isNone

  of tyNil:
    result = f.allowsNil
  else: discard

proc typeRangeRel(f, a: PType): TTypeRelation {.noinline.} =
  template checkRange[T](a0, a1, f0, f1: T): TTypeRelation =
    if a0 == f0 and a1 == f1:
      isEqual
    elif a0 >= f0 and a1 <= f1:
      isConvertible
    elif a0 <= f1 and f0 <= a1:
      # X..Y and C..D overlap iff (X <= D and C <= Y)
      isConvertible
    else:
      isNone

  if f.isOrdinalType:
    checkRange(firstOrd(nil, a), lastOrd(nil, a), firstOrd(nil, f), lastOrd(nil, f))
  else:
    checkRange(firstFloat(a), lastFloat(a), firstFloat(f), lastFloat(f))


proc matchUserTypeClass*(m: var TCandidate; ff, a: PType): PType =
  var
    c = m.c
    typeClass = ff.skipTypes({tyUserTypeClassInst})
    body = typeClass.n[3]
    matchedConceptContext: TMatchedConcept
    prevMatchedConcept = c.matchedConcept
    prevCandidateType = typeClass[0][0]

  if prevMatchedConcept != nil:
    matchedConceptContext.prev = prevMatchedConcept
    matchedConceptContext.depth = prevMatchedConcept.depth + 1
    if prevMatchedConcept.depth > 4:
      localError(m.c.graph.config, body.info, $body & " too nested for type matching")
      return nil

  openScope(c)
  matchedConceptContext.candidateType = a
  typeClass[0].sons[0] = a
  c.matchedConcept = addr(matchedConceptContext)
  defer:
    c.matchedConcept = prevMatchedConcept
    typeClass[0].sons[0] = prevCandidateType
    closeScope(c)

  var typeParams: seq[(PSym, PType)]

  if ff.kind == tyUserTypeClassInst:
    for i in 1 ..< (ff.len - 1):
      var
        typeParamName = ff.base.sons[i-1].sym.name
        typ = ff.sons[i]
        param: PSym
        alreadyBound = PType(idTableGet(m.bindings, typ))

      if alreadyBound != nil: typ = alreadyBound

      template paramSym(kind): untyped =
        newSym(kind, typeParamName, typeClass.sym, typeClass.sym.info, {})

      block addTypeParam:
        for prev in typeParams:
          if prev[1].id == typ.id:
            param = paramSym prev[0].kind
            param.typ = prev[0].typ
            break addTypeParam

        case typ.kind
        of tyStatic:
          param = paramSym skConst
          param.typ = typ.exactReplica
          if typ.n == nil:
            param.typ.flags.incl tfInferrableStatic
          else:
            param.ast = typ.n
        of tyUnknown:
          param = paramSym skVar
          param.typ = typ.exactReplica
        else:
          param = paramSym skType
          param.typ = if typ.isMetaType:
                        c.newTypeWithSons(tyInferred, @[typ])
                      else:
                        makeTypeDesc(c, typ)

        typeParams.add((param, typ))

      addDecl(c, param)

  var
    oldWriteHook: type(m.c.config.writelnHook)
    diagnostics: seq[string]
    errorPrefix: string
    flags: TExprFlags = {}
    collectDiagnostics = m.diagnosticsEnabled or
                         sfExplain in typeClass.sym.flags

  if collectDiagnostics:
    oldWriteHook = m.c.config.writelnHook
    # XXX: we can't write to m.diagnostics directly, because
    # Nim doesn't support capturing var params in closures
    diagnostics = @[]
    flags = {efExplain}
    m.c.config.writelnHook = proc (s: string) =
      if errorPrefix.len == 0: errorPrefix = typeClass.sym.name.s & ":"
      let msg = s.replace("Error:", errorPrefix)
      if oldWriteHook != nil: oldWriteHook msg
      diagnostics.add msg

  var checkedBody = c.semTryExpr(c, body.copyTree, flags)

  if collectDiagnostics:
    m.c.config.writelnHook = oldWriteHook
    for msg in diagnostics:
      m.diagnostics.add msg
      m.diagnosticsEnabled = true

  if checkedBody == nil: return nil

  # The inferrable type params have been identified during the semTryExpr above.
  # We need to put them in the current sigmatch's binding table in order for them
  # to be resolvable while matching the rest of the parameters
  for p in typeParams:
    put(m, p[1], p[0].typ)

  if ff.kind == tyUserTypeClassInst:
    result = generateTypeInstance(c, m.bindings, typeClass.sym.info, ff)
  else:
    result = copyType(ff, ff.owner, true)

  result.n = checkedBody

proc shouldSkipDistinct(m: TCandidate; rules: PNode, callIdent: PIdent): bool =
  # XXX This is bad as 'considerQuotedIdent' can produce an error!
  if rules.kind == nkWith:
    for r in rules:
      if considerQuotedIdent(m.c, r) == callIdent: return true
    return false
  else:
    for r in rules:
      if considerQuotedIdent(m.c, r) == callIdent: return false
    return true

proc maybeSkipDistinct(m: TCandidate; t: PType, callee: PSym): PType =
  if t != nil and t.kind == tyDistinct and t.n != nil and
     shouldSkipDistinct(m, t.n, callee.name):
    result = t.base
  else:
    result = t

proc tryResolvingStaticExpr(c: var TCandidate, n: PNode,
                            allowUnresolved = false): PNode =
  # Consider this example:
  #   type Value[N: static[int]] = object
  #   proc foo[N](a: Value[N], r: range[0..(N-1)])
  # Here, N-1 will be initially nkStaticExpr that can be evaluated only after
  # N is bound to a concrete value during the matching of the first param.
  # This proc is used to evaluate such static expressions.
  let instantiated = replaceTypesInBody(c.c, c.bindings, n, nil,
                                        allowMetaTypes = allowUnresolved)
  result = c.c.semExpr(c.c, instantiated)

proc inferStaticParam*(c: var TCandidate, lhs: PNode, rhs: BiggestInt): bool =
  # This is a simple integer arithimetic equation solver,
  # capable of deriving the value of a static parameter in
  # expressions such as (N + 5) / 2 = rhs
  #
  # Preconditions:
  #
  #   * The input of this proc must be semantized
  #     - all templates should be expanded
  #     - aby constant folding possible should already be performed
  #
  #   * There must be exactly one unresolved static parameter
  #
  # Result:
  #
  #   The proc will return true if the static types was successfully
  #   inferred. The result will be bound to the original static type
  #   in the TCandidate.
  #
  if lhs.kind in nkCallKinds and lhs[0].kind == nkSym:
    case lhs[0].sym.magic
    of mUnaryLt:
      return inferStaticParam(c, lhs[1], rhs + 1)

    of mAddI, mAddU, mInc, mSucc:
      if lhs[1].kind == nkIntLit:
        return inferStaticParam(c, lhs[2], rhs - lhs[1].intVal)
      elif lhs[2].kind == nkIntLit:
        return inferStaticParam(c, lhs[1], rhs - lhs[2].intVal)

    of mDec, mSubI, mSubU, mPred:
      if lhs[1].kind == nkIntLit:
        return inferStaticParam(c, lhs[2], lhs[1].intVal - rhs)
      elif lhs[2].kind == nkIntLit:
        return inferStaticParam(c, lhs[1], rhs + lhs[2].intVal)

    of mMulI, mMulU:
      if lhs[1].kind == nkIntLit:
        if rhs mod lhs[1].intVal == 0:
          return inferStaticParam(c, lhs[2], rhs div lhs[1].intVal)
      elif lhs[2].kind == nkIntLit:
        if rhs mod lhs[2].intVal == 0:
          return inferStaticParam(c, lhs[1], rhs div lhs[2].intVal)

    of mDivI, mDivU:
      if lhs[1].kind == nkIntLit:
        if lhs[1].intVal mod rhs == 0:
          return inferStaticParam(c, lhs[2], lhs[1].intVal div rhs)
      elif lhs[2].kind == nkIntLit:
        return inferStaticParam(c, lhs[1], lhs[2].intVal * rhs)

    of mShlI:
      if lhs[2].kind == nkIntLit:
        return inferStaticParam(c, lhs[1], rhs shr lhs[2].intVal)

    of mShrI:
      if lhs[2].kind == nkIntLit:
        return inferStaticParam(c, lhs[1], rhs shl lhs[2].intVal)

    of mAshrI:
      if lhs[2].kind == nkIntLit:
        return inferStaticParam(c, lhs[1], ashr(rhs, lhs[2].intVal))

    of mUnaryMinusI:
      return inferStaticParam(c, lhs[1], -rhs)

    of mUnaryPlusI, mToInt, mToBiggestInt:
      return inferStaticParam(c, lhs[1], rhs)

    else: discard

  elif lhs.kind == nkSym and lhs.typ.kind == tyStatic and lhs.typ.n == nil:
    var inferred = newTypeWithSons(c.c, tyStatic, lhs.typ.sons)
    inferred.n = newIntNode(nkIntLit, rhs)
    put(c, lhs.typ, inferred)
    if c.c.matchedConcept != nil:
      # inside concepts, binding is currently done with
      # direct mutation of the involved types:
      lhs.typ.n = inferred.n
    return true

  return false

proc failureToInferStaticParam(conf: ConfigRef; n: PNode) =
  let staticParam = n.findUnresolvedStatic
  let name = if staticParam != nil: staticParam.sym.name.s
             else: "unknown"
  localError(conf, n.info, "cannot infer the value of the static param '" & name & "'")

proc inferStaticsInRange(c: var TCandidate,
                         inferred, concrete: PType): TTypeRelation =
  let lowerBound = tryResolvingStaticExpr(c, inferred.n[0],
                                          allowUnresolved = true)
  let upperBound = tryResolvingStaticExpr(c, inferred.n[1],
                                          allowUnresolved = true)
  template doInferStatic(e: PNode, r: Int128) =
    var exp = e
    var rhs = r
    if inferStaticParam(c, exp, toInt64(rhs)):
      return isGeneric
    else:
      failureToInferStaticParam(c.c.config, exp)

  if lowerBound.kind == nkIntLit:
    if upperBound.kind == nkIntLit:
      if lengthOrd(c.c.config, concrete) == upperBound.intVal - lowerBound.intVal + 1:
        return isGeneric
      else:
        return isNone
    doInferStatic(upperBound, lengthOrd(c.c.config, concrete) + lowerBound.intVal - 1)
  elif upperBound.kind == nkIntLit:
    doInferStatic(lowerBound, getInt(upperBound) + 1 - lengthOrd(c.c.config, concrete))

template subtypeCheck() =
  if result <= isSubrange and f.lastSon.skipTypes(abstractInst).kind in {
      tyRef, tyPtr, tyVar, tyLent, tyOwned}:
    result = isNone

proc isCovariantPtr(c: var TCandidate, f, a: PType): bool =
  # this proc is always called for a pair of matching types
  assert f.kind == a.kind

  template baseTypesCheck(lhs, rhs: PType): bool =
    lhs.kind notin {tyPtr, tyRef, tyVar, tyLent, tyOwned} and
      typeRel(c, lhs, rhs, {trNoCovariance}) == isSubtype

  case f.kind
  of tyRef, tyPtr, tyOwned:
    return baseTypesCheck(f.base, a.base)
  of tyGenericInst:
    let body = f.base
    return body == a.base and
           a.sonsLen == 3 and
           tfWeakCovariant notin body.sons[0].flags and
           baseTypesCheck(f.sons[1], a.sons[1])
  else:
    return false

when false:
  proc maxNumericType(prev, candidate: PType): PType =
    let c = candidate.skipTypes({tyRange})
    template greater(s) =
      if c.kind in s: result = c
    case prev.kind
    of tyInt: greater({tyInt64})
    of tyInt8: greater({tyInt, tyInt16, tyInt32, tyInt64})
    of tyInt16: greater({tyInt, tyInt32, tyInt64})
    of tyInt32: greater({tyInt64})

    of tyUInt: greater({tyUInt64})
    of tyUInt8: greater({tyUInt, tyUInt16, tyUInt32, tyUInt64})
    of tyUInt16: greater({tyUInt, tyUInt32, tyUInt64})
    of tyUInt32: greater({tyUInt64})

    of tyFloat32: greater({tyFloat64, tyFloat128})
    of tyFloat64: greater({tyFloat128})
    else: discard

template skipOwned(a) =
  if a.kind == tyOwned: a = a.skipTypes({tyOwned, tyGenericInst})

proc typeRel(c: var TCandidate, f, aOrig: PType,
             flags: TTypeRelFlags = {}): TTypeRelation =
  # typeRel can be used to establish various relationships between types:
  #
  # 1) When used with concrete types, it will check for type equivalence
  # or a subtype relationship.
  #
  # 2) When used with a concrete type against a type class (such as generic
  # signature of a proc), it will check whether the concrete type is a member
  # of the designated type class.
  #
  # 3) When used with two type classes, it will check whether the types
  # matching the first type class are a strict subset of the types matching
  # the other. This allows us to compare the signatures of generic procs in
  # order to give preferrence to the most specific one:
  #
  # seq[seq[any]] is a strict subset of seq[any] and hence more specific.

  result = isNone
  assert(f != nil)

  if f.kind == tyUntyped:
    if aOrig != nil: put(c, f, aOrig)
    return isGeneric

  assert(aOrig != nil)

  var
    useTypeLoweringRuleInTypeClass = c.c.matchedConcept != nil and
                                     not c.isNoCall and
                                     f.kind != tyTypeDesc and
                                     tfExplicit notin aOrig.flags and
                                     tfConceptMatchedTypeSym notin aOrig.flags

    aOrig = if useTypeLoweringRuleInTypeClass:
          aOrig.skipTypes({tyTypeDesc})
        else:
          aOrig

  if aOrig.kind == tyInferred:
    let prev = aOrig.previouslyInferred
    if prev != nil:
      return typeRel(c, f, prev)
    else:
      var candidate = f

      case f.kind
      of tyGenericParam:
        var prev = PType(idTableGet(c.bindings, f))
        if prev != nil: candidate = prev
      of tyFromExpr:
        let computedType = tryResolvingStaticExpr(c, f.n).typ
        case computedType.kind
        of tyTypeDesc:
          candidate = computedType.base
        of tyStatic:
          candidate = computedType
        else:
          # XXX What is this non-sense? Error reporting in signature matching?
          discard "localError(f.n.info, errTypeExpected)"
      else:
        discard

      result = typeRel(c, aOrig.base, candidate)
      if result != isNone:
        c.inferredTypes.add aOrig
        aOrig.sons.add candidate
        result = isEqual
      return

  template doBind: bool = trDontBind notin flags

  # var, sink and static arguments match regular modifier-free types
  var a = maybeSkipDistinct(c, aOrig.skipTypes({tyStatic, tyVar, tyLent, tySink}), c.calleeSym)
  # XXX: Theoretically, maybeSkipDistinct could be called before we even
  # start the param matching process. This could be done in `prepareOperand`
  # for example, but unfortunately `prepareOperand` is not called in certain
  # situation when nkDotExpr are rotated to nkDotCalls

  if aOrig.kind in {tyAlias, tySink}:
    return typeRel(c, f, lastSon(aOrig))

  if a.kind == tyGenericInst and
      skipTypes(f, {tyVar, tyLent, tySink}).kind notin {
        tyGenericBody, tyGenericInvocation,
        tyGenericInst, tyGenericParam} + tyTypeClasses:
    return typeRel(c, f, lastSon(a))

  if a.isResolvedUserTypeClass:
    return typeRel(c, f, a.lastSon)

  template bindingRet(res) =
    if doBind:
      let bound = aOrig.skipTypes({tyRange}).skipIntLit
      put(c, f, bound)
    return res

  template considerPreviousT(body: untyped) =
    var prev = PType(idTableGet(c.bindings, f))
    if prev == nil: body
    else: return typeRel(c, prev, a)

  case a.kind
  of tyOr:
    # XXX: deal with the current dual meaning of tyGenericParam
    c.typedescMatched = true
    # seq[int|string] vs seq[number]
    # both int and string must match against number
    # but ensure that '[T: A|A]' matches as good as '[T: A]' (bug #2219):
    result = isGeneric
    for branch in a.sons:
      let x = typeRel(c, f, branch, flags + {trDontBind})
      if x == isNone: return isNone
      if x < result: result = x
    return

  of tyAnd:
    # XXX: deal with the current dual meaning of tyGenericParam
    c.typedescMatched = true
    # seq[Sortable and Iterable] vs seq[Sortable]
    # only one match is enough
    for branch in a.sons:
      let x = typeRel(c, f, branch, flags + {trDontBind})
      if x != isNone:
        return if x >= isGeneric: isGeneric else: x
    return isNone

  of tyNot:
    case f.kind
    of tyNot:
      # seq[!int] vs seq[!number]
      # seq[float] matches the first, but not the second
      # we must turn the problem around:
      # is number a subset of int?
      return typeRel(c, a.lastSon, f.lastSon)

    else:
      # negative type classes are essentially infinite,
      # so only the `any` type class is their superset
      return if f.kind == tyAnything: isGeneric
             else: isNone

  of tyAnything:
    if f.kind == tyAnything: return isGeneric
    else: return isNone

  of tyUserTypeClass, tyUserTypeClassInst:
    if c.c.matchedConcept != nil and c.c.matchedConcept.depth <= 4:
      # consider this: 'var g: Node' *within* a concept where 'Node'
      # is a concept too (tgraph)
      inc c.c.matchedConcept.depth
      let x = typeRel(c, a, f, flags + {trDontBind})
      if x >= isGeneric:
        return isGeneric
  else: discard

  case f.kind
  of tyEnum:
    if a.kind == f.kind and sameEnumTypes(f, a): result = isEqual
    elif sameEnumTypes(f, skipTypes(a, {tyRange})): result = isSubtype
  of tyBool, tyChar:
    if a.kind == f.kind: result = isEqual
    elif skipTypes(a, {tyRange}).kind == f.kind: result = isSubtype
  of tyRange:
    if a.kind == f.kind:
      if f.base.kind == tyNone: return isGeneric
      result = typeRel(c, base(f), base(a))
      # bugfix: accept integer conversions here
      #if result < isGeneric: result = isNone
      if result notin {isNone, isGeneric}:
        # resolve any late-bound static expressions
        # that may appear in the range:
        for i in 0..1:
          if f.n[i].kind == nkStaticExpr:
            f.n.sons[i] = tryResolvingStaticExpr(c, f.n[i])
        result = typeRangeRel(f, a)
    else:
      if skipTypes(f, {tyRange}).kind == a.kind:
        result = isIntConv
      elif isConvertibleToRange(skipTypes(f, {tyRange}), a):
        result = isConvertible  # a convertible to f
  of tyInt:      result = handleRange(f, a, tyInt8, tyInt32)
  of tyInt8:     result = handleRange(f, a, tyInt8, tyInt8)
  of tyInt16:    result = handleRange(f, a, tyInt8, tyInt16)
  of tyInt32:    result = handleRange(f, a, tyInt8, tyInt32)
  of tyInt64:    result = handleRange(f, a, tyInt, tyInt64)
  of tyUInt:     result = handleRange(f, a, tyUInt8, tyUInt32)
  of tyUInt8:    result = handleRange(f, a, tyUInt8, tyUInt8)
  of tyUInt16:   result = handleRange(f, a, tyUInt8, tyUInt16)
  of tyUInt32:   result = handleRange(f, a, tyUInt8, tyUInt32)
  of tyUInt64:   result = handleRange(f, a, tyUInt, tyUInt64)
  of tyFloat:    result = handleFloatRange(f, a)
  of tyFloat32:  result = handleFloatRange(f, a)
  of tyFloat64:  result = handleFloatRange(f, a)
  of tyFloat128: result = handleFloatRange(f, a)
  of tyVar, tyLent:
    if aOrig.kind == f.kind: result = typeRel(c, f.base, aOrig.base)
    else: result = typeRel(c, f.base, aOrig, flags + {trNoCovariance})
    subtypeCheck()
  of tyArray:
    case a.kind
    of tyArray:
      var fRange = f.sons[0]
      var aRange = a.sons[0]
      if fRange.kind == tyGenericParam:
        var prev = PType(idTableGet(c.bindings, fRange))
        if prev == nil:
          put(c, fRange, a.sons[0])
          fRange = a
        else:
          fRange = prev
      let ff = f.sons[1].skipTypes({tyTypeDesc})
      # This typeDesc rule is wrong, see bug #7331
      let aa = a.sons[1] #.skipTypes({tyTypeDesc})

      if f.sons[0].kind != tyGenericParam and aa.kind == tyEmpty:
        result = isGeneric
      else:
        result = typeRel(c, ff, aa)

      if result < isGeneric:
        if nimEnableCovariance and
           trNoCovariance notin flags and
           ff.kind == aa.kind and
           isCovariantPtr(c, ff, aa):
          result = isSubtype
        else:
          return isNone

      if fRange.rangeHasUnresolvedStatic:
        return inferStaticsInRange(c, fRange, a)
      elif c.c.matchedConcept != nil and aRange.rangeHasUnresolvedStatic:
        return inferStaticsInRange(c, aRange, f)
      else:
        if lengthOrd(c.c.config, fRange) != lengthOrd(c.c.config, aRange):
          result = isNone
    else: discard
  of tyUncheckedArray:
    if a.kind == tyUncheckedArray:
      result = typeRel(c, base(f), base(a))
      if result < isGeneric: result = isNone
    else: discard
  of tyOpenArray, tyVarargs:
    # varargs[expr] is special too but handled earlier. So we only need to
    # handle varargs[stmt] which is the same as varargs[typed]:
    if f.kind == tyVarargs:
      if tfVarargs in a.flags:
        return typeRel(c, f.base, a.lastSon)
      if f.sons[0].kind == tyTyped: return

    template matchArrayOrSeq(aBase: PType) =
      let ff = f.base
      let aa = aBase
      let baseRel = typeRel(c, ff, aa)
      if baseRel >= isGeneric:
        result = isConvertible
      elif nimEnableCovariance and
           trNoCovariance notin flags and
           ff.kind == aa.kind and
           isCovariantPtr(c, ff, aa):
        result = isConvertible

    case a.kind
    of tyOpenArray, tyVarargs:
      result = typeRel(c, base(f), base(a))
      if result < isGeneric: result = isNone
    of tyArray:
      if (f.sons[0].kind != tyGenericParam) and (a.sons[1].kind == tyEmpty):
        return isSubtype
      matchArrayOrSeq(a.sons[1])
    of tySequence:
      if (f.sons[0].kind != tyGenericParam) and (a.sons[0].kind == tyEmpty):
        return isConvertible
      matchArrayOrSeq(a.sons[0])
    of tyString:
      if f.kind == tyOpenArray:
        if f.sons[0].kind == tyChar:
          result = isConvertible
        elif f.sons[0].kind == tyGenericParam and a.len > 0 and
            typeRel(c, base(f), base(a)) >= isGeneric:
          result = isConvertible
    else: discard
  of tySequence:
    case a.kind
    of tySequence:
      if (f.sons[0].kind != tyGenericParam) and (a.sons[0].kind == tyEmpty):
        result = isSubtype
      else:
        let ff = f.sons[0]
        let aa = a.sons[0]
        result = typeRel(c, ff, aa)
        if result < isGeneric:
          if nimEnableCovariance and
             trNoCovariance notin flags and
             ff.kind == aa.kind and
             isCovariantPtr(c, ff, aa):
            result = isSubtype
          else:
            result = isNone
        elif tfNotNil in f.flags and tfNotNil notin a.flags:
          result = isNilConversion
    of tyNil: result = allowsNilDeprecated(c, f)
    else: discard
  of tyOrdinal:
    if isOrdinalType(a):
      var x = if a.kind == tyOrdinal: a.sons[0] else: a
      if f.sons[0].kind == tyNone:
        result = isGeneric
      else:
        result = typeRel(c, f.sons[0], x)
        if result < isGeneric: result = isNone
    elif a.kind == tyGenericParam:
      result = isGeneric
  of tyForward:
    #internalError("forward type in typeRel()")
    result = isNone
  of tyNil:
    skipOwned(a)
    if a.kind == f.kind: result = isEqual
  of tyTuple:
    if a.kind == tyTuple: result = recordRel(c, f, a)
  of tyObject:
    if a.kind == tyObject:
      if sameObjectTypes(f, a):
        result = isEqual
        # elif tfHasMeta in f.flags: result = recordRel(c, f, a)
      else:
        var depth = isObjectSubtype(c, a, f, nil)
        if depth > 0:
          inc(c.inheritancePenalty, depth)
          result = isSubtype
  of tyDistinct:
    a = a.skipTypes({tyOwned, tyGenericInst, tyRange})
    if a.kind == tyDistinct:
      if sameDistinctTypes(f, a): result = isEqual
      #elif f.base.kind == tyAnything: result = isGeneric  # issue 4435
      elif c.coerceDistincts: result = typeRel(c, f.base, a)
    elif a.kind == tyNil and f.base.kind in NilableTypes:
      result = f.allowsNil # XXX remove this typing rule, it is not in the spec
    elif c.coerceDistincts: result = typeRel(c, f.base, a)
  of tySet:
    if a.kind == tySet:
      if f.sons[0].kind != tyGenericParam and a.sons[0].kind == tyEmpty:
        result = isSubtype
      else:
        result = typeRel(c, f.sons[0], a.sons[0])
        if result <= isConvertible:
          result = isNone     # BUGFIX!
  of tyPtr, tyRef:
    skipOwned(a)
    if a.kind == f.kind:
      # ptr[R, T] can be passed to ptr[T], but not the other way round:
      if a.len < f.len: return isNone
      for i in 0..f.len-2:
        if typeRel(c, f.sons[i], a.sons[i]) == isNone: return isNone
      result = typeRel(c, f.lastSon, a.lastSon, flags + {trNoCovariance})
      subtypeCheck()
      if result <= isIntConv: result = isNone
      elif tfNotNil in f.flags and tfNotNil notin a.flags:
        result = isNilConversion
    elif a.kind == tyNil: result = f.allowsNil
    else: discard
  of tyProc:
    skipOwned(a)
    result = procTypeRel(c, f, a)
    if result != isNone and tfNotNil in f.flags and tfNotNil notin a.flags:
      result = isNilConversion
  of tyOwned:
    case a.kind
    of tyOwned:
      result = typeRel(c, lastSon(f), lastSon(a))
    of tyNil: result = f.allowsNil
    else: discard
  of tyPointer:
    skipOwned(a)
    case a.kind
    of tyPointer:
      if tfNotNil in f.flags and tfNotNil notin a.flags:
        result = isNilConversion
      else:
        result = isEqual
    of tyNil: result = f.allowsNil
    of tyProc:
      if a.callConv != ccClosure: result = isConvertible
    of tyPtr:
      # 'pointer' is NOT compatible to regionized pointers
      # so 'dealloc(regionPtr)' fails:
      if a.len == 1: result = isConvertible
    of tyCString: result = isConvertible
    else: discard
  of tyString:
    case a.kind
    of tyString:
      if tfNotNil in f.flags and tfNotNil notin a.flags:
        result = isNilConversion
      else:
        result = isEqual
    of tyNil: result = allowsNilDeprecated(c, f)
    else: discard
  of tyCString:
    # conversion from string to cstring is automatic:
    case a.kind
    of tyCString:
      if tfNotNil in f.flags and tfNotNil notin a.flags:
        result = isNilConversion
      else:
        result = isEqual
    of tyNil: result = f.allowsNil
    of tyString: result = isConvertible
    of tyPtr:
      # ptr[Tag, char] is not convertible to 'cstring' for now:
      if a.len == 1:
        let pointsTo = a.sons[0].skipTypes(abstractInst)
        if pointsTo.kind == tyChar: result = isConvertible
        elif pointsTo.kind == tyUncheckedArray and pointsTo.sons[0].kind == tyChar:
          result = isConvertible
        elif pointsTo.kind == tyArray and firstOrd(nil, pointsTo.sons[0]) == 0 and
            skipTypes(pointsTo.sons[0], {tyRange}).kind in {tyInt..tyInt64} and
            pointsTo.sons[1].kind == tyChar:
          result = isConvertible
    else: discard

  of tyEmpty, tyVoid:
    if a.kind == f.kind: result = isEqual

  of tyAlias, tySink:
    result = typeRel(c, lastSon(f), a)

  of tyGenericInst:
    var prev = PType(idTableGet(c.bindings, f))
    let origF = f
    var f = if prev == nil: f else: prev

    let roota = a.skipGenericAlias
    let rootf = f.skipGenericAlias

    var m = c
    if a.kind == tyGenericInst:
      if roota.base == rootf.base:
        let nextFlags = flags + {trNoCovariance}
        var hasCovariance = false
        # YYYY
        result = isEqual

        for i in 1 .. rootf.sonsLen-2:
          let ff = rootf.sons[i]
          let aa = roota.sons[i]
          let res = typeRel(c, ff, aa, nextFlags)
          if res != isEqual: result = isGeneric
          if res notin {isEqual, isGeneric}:
            if trNoCovariance notin flags and ff.kind == aa.kind:
              let paramFlags = rootf.base.sons[i-1].flags
              hasCovariance =
                if tfCovariant in paramFlags:
                  if tfWeakCovariant in paramFlags:
                    isCovariantPtr(c, ff, aa)
                  else:
                    ff.kind notin {tyRef, tyPtr} and res == isSubtype
                else:
                  tfContravariant in paramFlags and
                    typeRel(c, aa, ff) == isSubtype
              if hasCovariance:
                continue

            return isNone
        if prev == nil: put(c, f, a)
      else:
        let fKind = rootf.lastSon.kind
        if fKind in {tyAnd, tyOr}:
          result = typeRel(c, lastSon(f), a)
          if result != isNone: put(c, f, a)
          return

        var aAsObject = roota.lastSon

        if fKind in {tyRef, tyPtr}:
          if aAsObject.kind == tyObject:
            # bug #7600, tyObject cannot be passed
            # as argument to tyRef/tyPtr
            return isNone
          elif aAsObject.kind == fKind:
            aAsObject = aAsObject.base

        if aAsObject.kind == tyObject:
          let baseType = aAsObject.base
          if baseType != nil:
            c.inheritancePenalty += 1
            let ret = typeRel(c, f, baseType)
            return if ret == isEqual: isSubtype else: ret

        result = isNone
    else:
      assert lastSon(origF) != nil
      result = typeRel(c, lastSon(origF), a)
      if result != isNone and a.kind != tyNil:
        put(c, f, a)

  of tyGenericBody:
    considerPreviousT:
      if a == f or a.kind == tyGenericInst and a.sons[0] == f:
        bindingRet isGeneric
      let ff = lastSon(f)
      if ff != nil:
        result = typeRel(c, ff, a)

  of tyGenericInvocation:
    var x = a.skipGenericAlias
    var preventHack = false
    if x.kind == tyOwned and f.sons[0].kind != tyOwned:
      preventHack = true
      x = x.lastSon
    # XXX: This is very hacky. It should be moved back into liftTypeParam
    if x.kind in {tyGenericInst, tyArray} and
       c.calleeSym != nil and
       c.calleeSym.kind in {skProc, skFunc} and c.call != nil and not preventHack:
      let inst = prepareMetatypeForSigmatch(c.c, c.bindings, c.call.info, f)
      #echo "inferred ", typeToString(inst), " for ", f
      return typeRel(c, inst, a)

    var depth = 0
    if x.kind == tyGenericInvocation or f.sons[0].kind != tyGenericBody:
      #InternalError("typeRel: tyGenericInvocation -> tyGenericInvocation")
      # simply no match for now:
      discard
    elif x.kind == tyGenericInst and f.sons[0] == x.sons[0] and
          sonsLen(x) - 1 == sonsLen(f):
      for i in 1 ..< sonsLen(f):
        if x.sons[i].kind == tyGenericParam:
          internalError(c.c.graph.config, "wrong instantiated type!")
        elif typeRel(c, f.sons[i], x.sons[i]) <= isSubtype:
          # Workaround for regression #4589
          if f.sons[i].kind != tyTypeDesc: return
      result = isGeneric
    elif x.kind == tyGenericInst and isGenericSubtype(c, x, f, depth, f) and
          (sonsLen(x) - 1 == sonsLen(f)):
      # do not recurse here in order to not K bind twice for this code:
      #
      # type
      #   BaseFruit[T] = object of RootObj
      #   Banana[T] = object of BaseFruit[uint32] # Concrete type here, not T!
      # proc setColor[K](self: var BaseFruit[K])
      # var x: Banana[float64]
      # x.setColor()
      c.inheritancePenalty += depth
      result = isGeneric
    else:
      let genericBody = f.sons[0]
      var askip = skippedNone
      var fskip = skippedNone
      let aobj = x.skipToObject(askip)
      let fobj = genericBody.lastSon.skipToObject(fskip)
      var depth = -1
      if fobj != nil and aobj != nil and askip == fskip:
        depth = isObjectSubtype(c, aobj, fobj, f)
      result = typeRel(c, genericBody, x)
      if result != isNone:
        # see tests/generics/tgeneric3.nim for an example that triggers this
        # piece of code:
        #
        # proc internalFind[T,D](n: PNode[T,D], key: T): ref TItem[T,D]
        # proc internalPut[T,D](ANode: ref TNode[T,D], Akey: T, Avalue: D,
        #                       Oldvalue: var D): ref TNode[T,D]
        # var root = internalPut[int, int](nil, 312, 312, oldvalue)
        # var it1 = internalFind(root, 312) # cannot instantiate: 'D'
        #
        # we steal the generic parameters from the tyGenericBody:
        for i in 1 ..< sonsLen(f):
          let x = PType(idTableGet(c.bindings, genericBody.sons[i-1]))
          if x == nil:
            discard "maybe fine (for eg. a==tyNil)"
          elif x.kind in {tyGenericInvocation, tyGenericParam}:
            internalError(c.c.graph.config, "wrong instantiated type!")
          else:
            let key = f.sons[i]
            let old = PType(idTableGet(c.bindings, key))
            if old == nil:
              put(c, key, x)
            elif typeRel(c, old, x, flags + {trDontBind}) == isNone:
              return isNone

      if result == isNone:
        # Here object inheriting from generic/specialized generic object
        # crossing path with metatypes/aliases, so we need to separate them
        # by checking sym.id
        let genericSubtype = isGenericSubtype(c, x, f, depth, f)
        if not (genericSubtype and aobj.sym.id != fobj.sym.id) and aOrig.kind != tyGenericBody:
          depth = -1

      if depth >= 0:
        c.inheritancePenalty += depth
        # bug #4863: We still need to bind generic alias crap, so
        # we cannot return immediately:
        result = if depth == 0: isGeneric else: isSubtype
  of tyAnd:
    considerPreviousT:
      result = isEqual
      for branch in f.sons:
        let x = typeRel(c, branch, aOrig)
        if x < isSubtype: return isNone
        # 'and' implies minimum matching result:
        if x < result: result = x
      if result > isGeneric: result = isGeneric
      bindingRet result

  of tyOr:
    considerPreviousT:
      result = isNone
      let oldInheritancePenalty = c.inheritancePenalty
      var maxInheritance = 0
      for branch in f.sons:
        c.inheritancePenalty = 0
        let x = typeRel(c, branch, aOrig)
        maxInheritance = max(maxInheritance, c.inheritancePenalty)

        # 'or' implies maximum matching result:
        if x > result: result = x
      if result >= isSubtype:
        if result > isGeneric: result = isGeneric
        bindingRet result
      else:
        result = isNone
      c.inheritancePenalty = oldInheritancePenalty + maxInheritance

  of tyNot:
    considerPreviousT:
      for branch in f.sons:
        if typeRel(c, branch, aOrig) != isNone:
          return isNone

      bindingRet isGeneric

  of tyAnything:
    considerPreviousT:
      var concrete = concreteType(c, a)
      if concrete != nil and doBind:
        put(c, f, concrete)
      return isGeneric

  of tyBuiltInTypeClass:
    considerPreviousT:
      let targetKind = f.sons[0].kind
      let effectiveArgType = a.skipTypes({tyRange, tyGenericInst,
                                          tyBuiltInTypeClass, tyAlias, tySink, tyOwned})
      let typeClassMatches = targetKind == effectiveArgType.kind and
                             not effectiveArgType.isEmptyContainer
      if typeClassMatches or
        (targetKind in {tyProc, tyPointer} and effectiveArgType.kind == tyNil):
        put(c, f, a)
        return isGeneric
      else:
        return isNone

  of tyUserTypeClassInst, tyUserTypeClass:
    if f.isResolvedUserTypeClass:
      result = typeRel(c, f.lastSon, a)
    else:
      considerPreviousT:
        if aOrig == f: return isEqual
        var matched = matchUserTypeClass(c, f, aOrig)
        if matched != nil:
          bindConcreteTypeToUserTypeClass(matched, a)
          if doBind: put(c, f, matched)
          result = isGeneric
        else:
          result = isNone

  of tyCompositeTypeClass:
    considerPreviousT:
      let roota = a.skipGenericAlias
      let rootf = f.lastSon.skipGenericAlias
      if a.kind == tyGenericInst and roota.base == rootf.base:
        for i in 1 .. rootf.sonsLen-2:
          let ff = rootf.sons[i]
          let aa = roota.sons[i]
          result = typeRel(c, ff, aa)
          if result == isNone: return
          if ff.kind == tyRange and result != isEqual: return isNone
      else:
        result = typeRel(c, rootf.lastSon, a)
      if result != isNone:
        put(c, f, a)
        result = isGeneric

  of tyGenericParam:
    var x = PType(idTableGet(c.bindings, f))
    if x == nil:
      if c.callee.kind == tyGenericBody and
         f.kind == tyGenericParam and not c.typedescMatched:
        # XXX: The fact that generic types currently use tyGenericParam for
        # their parameters is really a misnomer. tyGenericParam means "match
        # any value" and what we need is "match any type", which can be encoded
        # by a tyTypeDesc params. Unfortunately, this requires more substantial
        # changes in semtypinst and elsewhere.
        if tfWildcard in a.flags:
          result = isGeneric
        elif a.kind == tyTypeDesc:
          if f.sonsLen == 0:
            result = isGeneric
          else:
            internalAssert c.c.graph.config, a.len > 0
            c.typedescMatched = true
            var aa = a
            while aa.kind in {tyTypeDesc, tyGenericParam} and aa.len > 0:
              aa = lastSon(aa)
            if aa.kind == tyGenericParam:
              return isGeneric
            result = typeRel(c, f.base, aa)
            if result > isGeneric: result = isGeneric
        elif c.isNoCall:
          if doBind:
            let concrete = concreteType(c, a, f)
            if concrete == nil: return isNone
            put(c, f, concrete)
          result = isGeneric
        else:
          result = isNone
      else:
        # check if 'T' has a constraint as in 'proc p[T: Constraint](x: T)'
        if f.sonsLen > 0 and f.sons[0].kind != tyNone:
          let oldInheritancePenalty = c.inheritancePenalty
          result = typeRel(c, f.sons[0], a, flags + {trDontBind})
          if doBind and result notin {isNone, isGeneric}:
            let concrete = concreteType(c, a, f)
            if concrete == nil: return isNone
            put(c, f, concrete)
          # bug #6526
          if result in {isEqual, isSubtype}:
            # 'T: Class' is a *better* match than just 'T'
            # but 'T: Subclass' is even better:
            c.inheritancePenalty = oldInheritancePenalty - c.inheritancePenalty -
                                  100 * ord(result == isEqual)
            result = isGeneric
        else:
          result = isGeneric

      if result == isGeneric:
        var concrete = a
        if tfWildcard in a.flags:
          a.sym.kind = skType
          a.flags.excl tfWildcard
        else:
          concrete = concreteType(c, a, f)
          if concrete == nil:
            return isNone
        if doBind:
          put(c, f, concrete)
      elif result > isGeneric:
        result = isGeneric
    elif a.kind == tyEmpty:
      result = isGeneric
    elif x.kind == tyGenericParam:
      result = isGeneric
    else:
      result = typeRel(c, x, a) # check if it fits
      if result > isGeneric: result = isGeneric
  of tyStatic:
    let prev = PType(idTableGet(c.bindings, f))
    if prev == nil:
      if aOrig.kind == tyStatic:
        if f.base.kind != tyNone:
          result = typeRel(c, f.base, a)
          if result != isNone and f.n != nil:
            if not exprStructuralEquivalent(f.n, aOrig.n):
              result = isNone
        else:
          result = isGeneric
        if result != isNone: put(c, f, aOrig)
      elif aOrig.n != nil and aOrig.n.typ != nil:
        result = if f.base.kind != tyNone: typeRel(c, f.lastSon, aOrig.n.typ)
                 else: isGeneric
        if result != isNone:
          var boundType = newTypeWithSons(c.c, tyStatic, @[aOrig.n.typ])
          boundType.n = aOrig.n
          put(c, f, boundType)
      else:
        result = isNone
    elif prev.kind == tyStatic:
      if aOrig.kind == tyStatic:
        result = typeRel(c, prev.lastSon, a)
        if result != isNone and prev.n != nil:
          if not exprStructuralEquivalent(prev.n, aOrig.n):
            result = isNone
      else: result = isNone
    else:
      # XXX endless recursion?
      #result = typeRel(c, prev, aOrig)
      result = isNone

  of tyInferred:
    let prev = f.previouslyInferred
    if prev != nil:
      result = typeRel(c, prev, a)
    else:
      result = typeRel(c, f.base, a)
      if result != isNone:
        c.inferredTypes.add f
        f.sons.add a

  of tyTypeDesc:
    var prev = PType(idTableGet(c.bindings, f))
    if prev == nil:
      # proc foo(T: typedesc, x: T)
      # when `f` is an unresolved typedesc, `a` could be any
      # type, so we should not perform this check earlier
      if a.kind != tyTypeDesc:
        if a.kind == tyGenericParam and tfWildcard in a.flags:
          # TODO: prevent `a` from matching as a wildcard again
          result = isGeneric
        else:
          result = isNone
      elif f.base.kind == tyNone:
        result = isGeneric
      else:
        result = typeRel(c, f.base, a.base)

      if result != isNone:
        put(c, f, a)
    else:
      if tfUnresolved in f.flags:
        result = typeRel(c, prev.base, a)
      elif a.kind == tyTypeDesc:
        result = typeRel(c, prev.base, a.base)
      else:
        result = isNone

  of tyTyped:
    if aOrig != nil:
      put(c, f, aOrig)
    result = isGeneric

  of tyProxy:
    result = isEqual

  of tyFromExpr:
    # fix the expression, so it contains the already instantiated types
    if f.n == nil or f.n.kind == nkEmpty: return isGeneric
    let reevaluated = tryResolvingStaticExpr(c, f.n)
    case reevaluated.typ.kind
    of tyTypeDesc:
      result = typeRel(c, a, reevaluated.typ.base)
    of tyStatic:
      result = typeRel(c, a, reevaluated.typ.base)
      if result != isNone and reevaluated.typ.n != nil:
        if not exprStructuralEquivalent(aOrig.n, reevaluated.typ.n):
          result = isNone
    else:
      localError(c.c.graph.config, f.n.info, "type expected")
      result = isNone

  of tyNone:
    if a.kind == tyNone: result = isEqual
  else:
    internalError c.c.graph.config, " unknown type kind " & $f.kind

when false:
  var nowDebug = false
  var dbgCount = 0

  proc typeRel(c: var TCandidate, f, aOrig: PType,
              flags: TTypeRelFlags = {}): TTypeRelation =
    if nowDebug:
      echo f, " <- ", aOrig
      inc dbgCount
      if dbgCount == 2:
        writeStackTrace()
    result = typeRelImpl(c, f, aOrig, flags)
    if nowDebug:
      echo f, " <- ", aOrig, " res ", result

proc cmpTypes*(c: PContext, f, a: PType): TTypeRelation =
  var m: TCandidate
  initCandidate(c, m, f)
  result = typeRel(m, f, a)

proc getInstantiatedType(c: PContext, arg: PNode, m: TCandidate,
                         f: PType): PType =
  result = PType(idTableGet(m.bindings, f))
  if result == nil:
    result = generateTypeInstance(c, m.bindings, arg, f)
  if result == nil:
    internalError(c.graph.config, arg.info, "getInstantiatedType")
    result = errorType(c)

proc implicitConv(kind: TNodeKind, f: PType, arg: PNode, m: TCandidate,
                  c: PContext): PNode =
  result = newNodeI(kind, arg.info)
  if containsGenericType(f):
    if not m.hasFauxMatch:
      result.typ = getInstantiatedType(c, arg, m, f)
    else:
      result.typ = errorType(c)
  else:
    result.typ = f
  if result.typ == nil: internalError(c.graph.config, arg.info, "implicitConv")
  addSon(result, c.graph.emptyNode)
  addSon(result, arg)

proc userConvMatch(c: PContext, m: var TCandidate, f, a: PType,
                   arg: PNode): PNode =
  result = nil
  for i in 0 ..< len(c.converters):
    var src = c.converters[i].typ.sons[1]
    var dest = c.converters[i].typ.sons[0]
    # for generic type converters we need to check 'src <- a' before
    # 'f <- dest' in order to not break the unification:
    # see tests/tgenericconverter:
    let srca = typeRel(m, src, a)
    if srca notin {isEqual, isGeneric, isSubtype}: continue

    # What's done below matches the logic in ``matchesAux``
    let constraint = c.converters[i].typ.n[1].sym.constraint
    if not constraint.isNil and not matchNodeKinds(constraint, arg):
      continue
    if src.kind in {tyVar, tyLent} and not arg.isLValue:
      continue

    let destIsGeneric = containsGenericType(dest)
    if destIsGeneric:
      dest = generateTypeInstance(c, m.bindings, arg, dest)
    let fdest = typeRel(m, f, dest)
    if fdest in {isEqual, isGeneric} and not (dest.kind == tyLent and f.kind == tyVar):
      markUsed(c, arg.info, c.converters[i], c.graph.usageSym)
      var s = newSymNode(c.converters[i])
      s.typ = c.converters[i].typ
      s.info = arg.info
      result = newNodeIT(nkHiddenCallConv, arg.info, dest)
      addSon(result, s)
      # We build the call expression by ourselves in order to avoid passing this
      # expression trough the semantic check phase once again so let's make sure
      # it is correct
      var param: PNode = nil
      if srca == isSubtype:
        param = implicitConv(nkHiddenSubConv, src, copyTree(arg), m, c)
      elif src.kind == tyVar:
        # Analyse the converter return type
        param = newNodeIT(nkHiddenAddr, arg.info, s.typ[1])
        param.addSon(copyTree(arg))
      else:
        param = copyTree(arg)
      addSon(result, param)

      if dest.kind in {tyVar, tyLent}:
        dest.flags.incl tfVarIsPtr
        result = newDeref(result)

      inc(m.convMatches)
      if not m.genericConverter:
        m.genericConverter = srca == isGeneric or destIsGeneric
      return result

proc localConvMatch(c: PContext, m: var TCandidate, f, a: PType,
                    arg: PNode): PNode =
  # arg.typ can be nil in 'suggest':
  if isNil(arg.typ): return nil

  # sem'checking for 'echo' needs to be re-entrant:
  # XXX we will revisit this issue after 0.10.2 is released
  if f == arg.typ and arg.kind == nkHiddenStdConv: return arg

  var call = newNodeI(nkCall, arg.info)
  call.add(f.n.copyTree)
  call.add(arg.copyTree)
  result = c.semExpr(c, call)
  if result != nil:
    if result.typ == nil: return nil
    # resulting type must be consistent with the other arguments:
    var r = typeRel(m, f.sons[0], result.typ)
    if r < isGeneric: return nil
    if result.kind == nkCall: result.kind = nkHiddenCallConv
    inc(m.convMatches)
    if r == isGeneric:
      result.typ = getInstantiatedType(c, arg, m, base(f))
    m.baseTypeMatch = true

proc incMatches(m: var TCandidate; r: TTypeRelation; convMatch = 1) =
  case r
  of isConvertible, isIntConv: inc(m.convMatches, convMatch)
  of isSubtype, isSubrange: inc(m.subtypeMatches)
  of isGeneric, isInferred, isBothMetaConvertible: inc(m.genericMatches)
  of isFromIntLit: inc(m.intConvMatches, 256)
  of isInferredConvertible:
    inc(m.convMatches)
  of isEqual: inc(m.exactMatches)
  of isNone: discard

template matchesVoidProc(t: PType): bool =
  (t.kind == tyProc and t.len == 1 and t.sons[0] == nil) or
    (t.kind == tyBuiltInTypeClass and t.sons[0].kind == tyProc)

proc paramTypesMatchAux(m: var TCandidate, f, a: PType,
                        argSemantized, argOrig: PNode): PNode =
  var
    fMaybeStatic = f.skipTypes({tyDistinct})
    arg = argSemantized
    a = a
    c = m.c

  if tfHasStatic in fMaybeStatic.flags:
    # XXX: When implicit statics are the default
    # this will be done earlier - we just have to
    # make sure that static types enter here

    # Zahary: weaken tyGenericParam and call it tyGenericPlaceholder
    # and finally start using tyTypedesc for generic types properly.
    # Araq: This would only shift the problems around, in 'proc p[T](x: T)'
    # the T is NOT a typedesc.
    if a.kind == tyGenericParam and tfWildcard in a.flags:
      a.assignType(f)
      # put(m.bindings, f, a)
      return argSemantized

    if a.kind == tyStatic:
      if m.callee.kind == tyGenericBody and
         a.n == nil and
         tfGenericTypeParam notin a.flags:
        return newNodeIT(nkType, argOrig.info, makeTypeFromExpr(c, arg))
    else:
      var evaluated = c.semTryConstExpr(c, arg)
      if evaluated != nil:
        # Don't build the type in-place because `evaluated` and `arg` may point
        # to the same object and we'd end up creating recursive types (#9255)
        let typ = newTypeS(tyStatic, c)
        typ.sons = @[evaluated.typ]
        typ.n = evaluated
        arg.typ = typ
        a = typ
      else:
        if m.callee.kind == tyGenericBody:
          if f.kind == tyStatic and typeRel(m, f.base, a) != isNone:
            result = makeStaticExpr(m.c, arg)
            result.typ.flags.incl tfUnresolved
            result.typ.n = arg
            return

  let oldInheritancePenalty = m.inheritancePenalty
  var r = typeRel(m, f, a)

  # This special typing rule for macros and templates is not documented
  # anywhere and breaks symmetry. It's hard to get rid of though, my
  # custom seqs example fails to compile without this:
  if r != isNone and m.calleeSym != nil and
    m.calleeSym.kind in {skMacro, skTemplate}:
    # XXX: duplicating this is ugly, but we cannot (!) move this
    # directly into typeRel using return-like templates
    incMatches(m, r)
    if f.kind == tyTyped:
      return arg
    elif f.kind == tyTypeDesc:
      return arg
    elif f.kind == tyStatic and arg.typ.n != nil:
      return arg.typ.n
    else:
      return argSemantized # argOrig

  # If r == isBothMetaConvertible then we rerun typeRel.
  # bothMetaCounter is for safety to avoid any infinite loop,
  #  I don't have any example when it is needed.
  # lastBindingsLenth is used to check whether m.bindings remains the same,
  #  because in that case there is no point in continuing.
  var bothMetaCounter = 0
  var lastBindingsLength = -1
  while r == isBothMetaConvertible and
      lastBindingsLength != m.bindings.counter and
      bothMetaCounter < 100:
    lastBindingsLength = m.bindings.counter
    inc(bothMetaCounter)
    if arg.kind in {nkProcDef, nkFuncDef, nkIteratorDef} + nkLambdaKinds:
      result = c.semInferredLambda(c, m.bindings, arg)
    elif arg.kind != nkSym:
      return nil
    else:
      let inferred = c.semGenerateInstance(c, arg.sym, m.bindings, arg.info)
      result = newSymNode(inferred, arg.info)
    inc(m.convMatches)
    arg = result
    r = typeRel(m, f, arg.typ)

  case r
  of isConvertible:
    inc(m.convMatches)
    result = implicitConv(nkHiddenStdConv, f, arg, m, c)
  of isIntConv:
    # I'm too lazy to introduce another ``*matches`` field, so we conflate
    # ``isIntConv`` and ``isIntLit`` here:
    inc(m.intConvMatches)
    result = implicitConv(nkHiddenStdConv, f, arg, m, c)
  of isSubtype:
    inc(m.subtypeMatches)
    if f.kind == tyTypeDesc:
      result = arg
    else:
      result = implicitConv(nkHiddenSubConv, f, arg, m, c)
  of isSubrange:
    inc(m.subtypeMatches)
    if f.kind == tyVar:
      result = arg
    else:
      result = implicitConv(nkHiddenStdConv, f, arg, m, c)
  of isInferred, isInferredConvertible:
    if arg.kind in {nkProcDef, nkFuncDef, nkIteratorDef} + nkLambdaKinds:
      result = c.semInferredLambda(c, m.bindings, arg)
    elif arg.kind != nkSym:
      return nil
    else:
      let inferred = c.semGenerateInstance(c, arg.sym, m.bindings, arg.info)
      result = newSymNode(inferred, arg.info)
    if r == isInferredConvertible:
      inc(m.convMatches)
      result = implicitConv(nkHiddenStdConv, f, result, m, c)
    else:
      inc(m.genericMatches)
  of isGeneric:
    inc(m.genericMatches)
    if arg.typ == nil:
      result = arg
    elif skipTypes(arg.typ, abstractVar-{tyTypeDesc}).kind == tyTuple or
         m.inheritancePenalty > oldInheritancePenalty:
      result = implicitConv(nkHiddenSubConv, f, arg, m, c)
    elif arg.typ.isEmptyContainer:
      result = arg.copyTree
      result.typ = getInstantiatedType(c, arg, m, f)
    else:
      result = arg
  of isBothMetaConvertible:
    # This is the result for the 101th time.
    result = nil
  of isFromIntLit:
    # too lazy to introduce another ``*matches`` field, so we conflate
    # ``isIntConv`` and ``isIntLit`` here:
    inc(m.intConvMatches, 256)
    result = implicitConv(nkHiddenStdConv, f, arg, m, c)
  of isEqual:
    inc(m.exactMatches)
    result = arg
    if skipTypes(f, abstractVar-{tyTypeDesc}).kind == tyTuple or
      (arg.typ != nil and skipTypes(arg.typ, abstractVar-{tyTypeDesc}).kind == tyTuple):
      result = implicitConv(nkHiddenSubConv, f, arg, m, c)
  of isNone:
    # do not do this in ``typeRel`` as it then can't infer T in ``ref T``:
    if a.kind in {tyProxy, tyUnknown}:
      inc(m.genericMatches)
      m.fauxMatch = a.kind
      return arg
    elif a.kind == tyVoid and f.matchesVoidProc and argOrig.kind == nkStmtList:
      # lift do blocks without params to lambdas
      let p = c.graph
      let lifted = c.semExpr(c, newProcNode(nkDo, argOrig.info, body = argOrig,
          params = nkFormalParams.newTree(p.emptyNode), name = p.emptyNode, pattern = p.emptyNode,
          genericParams = p.emptyNode, pragmas = p.emptyNode, exceptions = p.emptyNode), {})
      if f.kind == tyBuiltInTypeClass:
        inc m.genericMatches
        put(m, f, lifted.typ)
      inc m.convMatches
      return implicitConv(nkHiddenStdConv, f, lifted, m, c)
    result = userConvMatch(c, m, f, a, arg)
    # check for a base type match, which supports varargs[T] without []
    # constructor in a call:
    if result == nil and f.kind == tyVarargs:
      if f.n != nil:
        # Forward to the varargs converter
        result = localConvMatch(c, m, f, a, arg)
      else:
        r = typeRel(m, base(f), a)
        case r
        of isGeneric:
          inc(m.convMatches)
          result = copyTree(arg)
          result.typ = getInstantiatedType(c, arg, m, base(f))
          m.baseTypeMatch = true
        of isFromIntLit:
          inc(m.intConvMatches, 256)
          result = implicitConv(nkHiddenStdConv, f[0], arg, m, c)
          m.baseTypeMatch = true
        of isEqual:
          inc(m.convMatches)
          result = copyTree(arg)
          m.baseTypeMatch = true
        of isSubtype: # bug #4799, varargs accepting subtype relation object
          inc(m.subtypeMatches)
          if base(f).kind == tyTypeDesc:
            result = arg
          else:
            result = implicitConv(nkHiddenSubConv, base(f), arg, m, c)
          m.baseTypeMatch = true
        else:
          result = userConvMatch(c, m, base(f), a, arg)
          if result != nil: m.baseTypeMatch = true

proc paramTypesMatch*(m: var TCandidate, f, a: PType,
                      arg, argOrig: PNode): PNode =
  if arg == nil or arg.kind notin nkSymChoices:
    result = paramTypesMatchAux(m, f, a, arg, argOrig)
  else:
    # CAUTION: The order depends on the used hashing scheme. Thus it is
    # incorrect to simply use the first fitting match. However, to implement
    # this correctly is inefficient. We have to copy `m` here to be able to
    # roll back the side effects of the unification algorithm.
    let c = m.c
    var x, y, z: TCandidate
    initCandidate(c, x, m.callee)
    initCandidate(c, y, m.callee)
    initCandidate(c, z, m.callee)
    x.calleeSym = m.calleeSym
    y.calleeSym = m.calleeSym
    z.calleeSym = m.calleeSym
    var best = -1
    for i in 0 ..< arg.len:
      if arg.sons[i].sym.kind in {skProc, skFunc, skMethod, skConverter,
                                  skIterator, skMacro, skTemplate}:
        copyCandidate(z, m)
        z.callee = arg.sons[i].typ
        if tfUnresolved in z.callee.flags: continue
        z.calleeSym = arg.sons[i].sym
        #if arg.sons[i].sym.name.s == "cmp":
        #  ggDebug = true
        #  echo "CALLLEEEEEEEE A ", typeToString(z.callee)
        # XXX this is still all wrong: (T, T) should be 2 generic matches
        # and  (int, int) 2 exact matches, etc. Essentially you cannot call
        # typeRel here and expect things to work!
        let r = typeRel(z, f, arg.sons[i].typ)
        incMatches(z, r, 2)
        #if arg.sons[i].sym.name.s == "cmp": # and arg.info.line == 606:
        #  echo "M ", r, " ", arg.info, " ", typeToString(arg.sons[i].sym.typ)
        #  writeMatches(z)
        if r != isNone:
          z.state = csMatch
          case x.state
          of csEmpty, csNoMatch:
            x = z
            best = i
          of csMatch:
            let cmp = cmpCandidates(x, z)
            if cmp < 0:
              best = i
              x = z
            elif cmp == 0:
              y = z           # z is as good as x

    if x.state == csEmpty:
      result = nil
    elif y.state == csMatch and cmpCandidates(x, y) == 0:
      if x.state != csMatch:
        internalError(m.c.graph.config, arg.info, "x.state is not csMatch")
      # ambiguous: more than one symbol fits!
      # See tsymchoice_for_expr as an example. 'f.kind == tyUntyped' should match
      # anyway:
      if f.kind in {tyUntyped, tyTyped}: result = arg
      else: result = nil
    else:
      # only one valid interpretation found:
      markUsed(m.c, arg.info, arg.sons[best].sym, m.c.graph.usageSym)
      onUse(arg.info, arg.sons[best].sym)
      result = paramTypesMatchAux(m, f, arg.sons[best].typ, arg.sons[best],
                                  argOrig)
  when false:
    if m.calleeSym != nil and m.calleeSym.name.s == "[]":
      echo m.c.config $ arg.info, " for ", m.calleeSym.name.s, " ", m.c.config $ m.calleeSym.info
      writeMatches(m)

proc setSon(father: PNode, at: int, son: PNode) =
  let oldLen = father.len
  if oldLen <= at:
    setLen(father.sons, at + 1)
  father.sons[at] = son
  # insert potential 'void' parameters:
  #for i in oldLen ..< at:
  #  father.sons[i] = newNodeIT(nkEmpty, son.info, getSysType(tyVoid))

# we are allowed to modify the calling node in the 'prepare*' procs:
proc prepareOperand(c: PContext; formal: PType; a: PNode): PNode =
  if formal.kind == tyUntyped and formal.len != 1:
    # {tyTypeDesc, tyUntyped, tyTyped, tyProxy}:
    # a.typ == nil is valid
    result = a
  elif a.typ.isNil:
    # XXX This is unsound! 'formal' can differ from overloaded routine to
    # overloaded routine!
    let flags = {efDetermineType, efAllowStmt}
                #if formal.kind == tyIter: {efDetermineType, efWantIterator}
                #else: {efDetermineType, efAllowStmt}
                #elif formal.kind == tyTyped: {efDetermineType, efWantStmt}
                #else: {efDetermineType}
    result = c.semOperand(c, a, flags)
  else:
    result = a
    considerGenSyms(c, result)

proc prepareOperand(c: PContext; a: PNode): PNode =
  if a.typ.isNil:
    result = c.semOperand(c, a, {efDetermineType})
  else:
    result = a
    considerGenSyms(c, result)

proc prepareNamedParam(a: PNode; c: PContext) =
  if a.sons[0].kind != nkIdent:
    var info = a.sons[0].info
    a.sons[0] = newIdentNode(considerQuotedIdent(c, a.sons[0]), info)

proc arrayConstr(c: PContext, n: PNode): PType =
  result = newTypeS(tyArray, c)
  rawAddSon(result, makeRangeType(c, 0, 0, n.info))
  addSonSkipIntLit(result, skipTypes(n.typ,
      {tyGenericInst, tyVar, tyLent, tyOrdinal}))

proc arrayConstr(c: PContext, info: TLineInfo): PType =
  result = newTypeS(tyArray, c)
  rawAddSon(result, makeRangeType(c, 0, -1, info))
  rawAddSon(result, newTypeS(tyEmpty, c)) # needs an empty basetype!

proc incrIndexType(t: PType) =
  assert t.kind == tyArray
  inc t.sons[0].n.sons[1].intVal

template isVarargsUntyped(x): untyped =
  x.kind == tyVarargs and x.sons[0].kind == tyUntyped

proc matchesAux(c: PContext, n, nOrig: PNode,
                m: var TCandidate, marker: var IntSet) =
  var
    a = 1 # iterates over the actual given arguments
    f = if m.callee.kind != tyGenericBody: 1
        else: 0 # iterates over formal parameters
    arg: PNode # current prepared argument
    formal: PSym # current routine parameter

  template noMatch() =
    m.state = csNoMatch
    m.firstMismatch.arg = a
    m.firstMismatch.formal = formal

  template checkConstraint(n: untyped) {.dirty.} =
    if not formal.constraint.isNil:
      if matchNodeKinds(formal.constraint, n):
        # better match over other routines with no such restriction:
        inc(m.genericMatches, 100)
      else:
        noMatch()
        return

    if formal.typ.kind == tyVar:
      let argConverter = if arg.kind == nkHiddenDeref: arg[0] else: arg
      if argConverter.kind == nkHiddenCallConv:
        if argConverter.typ.kind != tyVar:
          m.firstMismatch.kind = kVarNeeded
          noMatch()
          return
      elif not n.isLValue:
        m.firstMismatch.kind = kVarNeeded
        noMatch()
        return

  m.state = csMatch # until proven otherwise
  m.firstMismatch = MismatchInfo()
  m.call = newNodeI(n.kind, n.info)
  m.call.typ = base(m.callee) # may be nil
  var formalLen = m.callee.n.len
  addSon(m.call, n.sons[0])
  var container: PNode = nil # constructed container
  formal = if formalLen > 1: m.callee.n.sons[1].sym else: nil

  while a < n.len:
    if a >= formalLen-1 and f < formalLen and m.callee.n[f].typ.isVarargsUntyped:
      formal = m.callee.n.sons[f].sym
      incl(marker, formal.position)

      if n.sons[a].kind == nkHiddenStdConv:
        doAssert n.sons[a].sons[0].kind == nkEmpty and
                 n.sons[a].sons[1].kind in {nkBracket, nkArgList}
        # Steal the container and pass it along
        setSon(m.call, formal.position + 1, n.sons[a].sons[1])
      else:
        if container.isNil:
          container = newNodeIT(nkArgList, n.sons[a].info, arrayConstr(c, n.info))
          setSon(m.call, formal.position + 1, container)
        else:
          incrIndexType(container.typ)
        addSon(container, n.sons[a])
    elif n.sons[a].kind == nkExprEqExpr:
      # named param
      m.firstMismatch.kind = kUnknownNamedParam
      # check if m.callee has such a param:
      prepareNamedParam(n.sons[a], c)
      if n.sons[a].sons[0].kind != nkIdent:
        localError(c.config, n.sons[a].info, "named parameter has to be an identifier")
        noMatch()
        return
      formal = getSymFromList(m.callee.n, n.sons[a].sons[0].ident, 1)
      if formal == nil:
        # no error message!
        noMatch()
        return
      if containsOrIncl(marker, formal.position):
        m.firstMismatch.kind = kAlreadyGiven
        # already in namedParams, so no match
        # we used to produce 'errCannotBindXTwice' here but see
        # bug #3836 of why that is not sound (other overload with
        # different parameter names could match later on):
        when false: localError(n.sons[a].info, errCannotBindXTwice, formal.name.s)
        noMatch()
        return
      m.baseTypeMatch = false
      m.typedescMatched = false
      n.sons[a].sons[1] = prepareOperand(c, formal.typ, n.sons[a].sons[1])
      n.sons[a].typ = n.sons[a].sons[1].typ
      arg = paramTypesMatch(m, formal.typ, n.sons[a].typ,
                                n.sons[a].sons[1], n.sons[a].sons[1])
      m.firstMismatch.kind = kTypeMismatch
      if arg == nil:
        noMatch()
        return
      checkConstraint(n.sons[a].sons[1])
      if m.baseTypeMatch:
        #assert(container == nil)
        container = newNodeIT(nkBracket, n.sons[a].info, arrayConstr(c, arg))
        addSon(container, arg)
        setSon(m.call, formal.position + 1, container)
        if f != formalLen - 1: container = nil
      else:
        setSon(m.call, formal.position + 1, arg)
      inc f
    else:
      # unnamed param
      if f >= formalLen:
        # too many arguments?
        if tfVarargs in m.callee.flags:
          # is ok... but don't increment any counters...
          # we have no formal here to snoop at:
          n.sons[a] = prepareOperand(c, n.sons[a])
          if skipTypes(n.sons[a].typ, abstractVar-{tyTypeDesc}).kind==tyString:
            addSon(m.call, implicitConv(nkHiddenStdConv,
                  getSysType(c.graph, n.sons[a].info, tyCString),
                  copyTree(n.sons[a]), m, c))
          else:
            addSon(m.call, copyTree(n.sons[a]))
        elif formal != nil and formal.typ.kind == tyVarargs:
          m.firstMismatch.kind = kTypeMismatch
          # beware of the side-effects in 'prepareOperand'! So only do it for
          # varargs matching. See tests/metatype/tstatic_overloading.
          m.baseTypeMatch = false
          m.typedescMatched = false
          incl(marker, formal.position)
          n.sons[a] = prepareOperand(c, formal.typ, n.sons[a])
          arg = paramTypesMatch(m, formal.typ, n.sons[a].typ,
                                    n.sons[a], nOrig.sons[a])
          if arg != nil and m.baseTypeMatch and container != nil:
            addSon(container, arg)
            incrIndexType(container.typ)
            checkConstraint(n.sons[a])
          else:
            noMatch()
            return
        else:
          m.firstMismatch.kind = kExtraArg
          noMatch()
          return
      else:
        if m.callee.n.sons[f].kind != nkSym:
          internalError(c.config, n.sons[a].info, "matches")
          noMatch()
          return
        formal = m.callee.n.sons[f].sym
        m.firstMismatch.kind = kTypeMismatch
        if containsOrIncl(marker, formal.position) and container.isNil:
          m.firstMismatch.kind = kPositionalAlreadyGiven
          # positional param already in namedParams: (see above remark)
          when false: localError(n.sons[a].info, errCannotBindXTwice, formal.name.s)
          noMatch()
          return

        if formal.typ.isVarargsUntyped:
          if container.isNil:
            container = newNodeIT(nkArgList, n.sons[a].info, arrayConstr(c, n.info))
            setSon(m.call, formal.position + 1, container)
          else:
            incrIndexType(container.typ)
          addSon(container, n.sons[a])
        else:
          m.baseTypeMatch = false
          m.typedescMatched = false
          n.sons[a] = prepareOperand(c, formal.typ, n.sons[a])
          arg = paramTypesMatch(m, formal.typ, n.sons[a].typ,
                                    n.sons[a], nOrig.sons[a])
          if arg == nil:
            noMatch()
            return
          if m.baseTypeMatch:
            assert formal.typ.kind == tyVarargs
            #assert(container == nil)
            if container.isNil:
              container = newNodeIT(nkBracket, n.sons[a].info, arrayConstr(c, arg))
              container.typ.flags.incl tfVarargs
            else:
              incrIndexType(container.typ)
            addSon(container, arg)
            setSon(m.call, formal.position + 1,
                   implicitConv(nkHiddenStdConv, formal.typ, container, m, c))
            #if f != formalLen - 1: container = nil

            # pick the formal from the end, so that 'x, y, varargs, z' works:
            f = max(f, formalLen - n.len + a + 1)
          elif formal.typ.kind != tyVarargs or container == nil:
            setSon(m.call, formal.position + 1, arg)
            inc(f)
            container = nil
          else:
            # we end up here if the argument can be converted into the varargs
            # formal (eg. seq[T] -> varargs[T]) but we have already instantiated
            # a container
            #assert arg.kind == nkHiddenStdConv # for 'nim check'
            # this assertion can be off
            localError(c.config, n.sons[a].info, "cannot convert $1 to $2" % [
              typeToString(n.sons[a].typ), typeToString(formal.typ) ])
            noMatch()
            return
        checkConstraint(n.sons[a])
    inc(a)
  # for some edge cases (see tdont_return_unowned_from_owned test case)
  m.firstMismatch.arg = a
  m.firstMismatch.formal = formal

proc semFinishOperands*(c: PContext, n: PNode) =
  # this needs to be called to ensure that after overloading resolution every
  # argument has been sem'checked:
  for i in 1 ..< n.len:
    n.sons[i] = prepareOperand(c, n.sons[i])

proc partialMatch*(c: PContext, n, nOrig: PNode, m: var TCandidate) =
  # for 'suggest' support:
  var marker = initIntSet()
  matchesAux(c, n, nOrig, m, marker)

proc matches*(c: PContext, n, nOrig: PNode, m: var TCandidate) =
  if m.magic in {mArrGet, mArrPut}:
    m.state = csMatch
    m.call = n
    # Note the following doesn't work as it would produce ambiguities.
    # Instead we patch system.nim, see bug #8049.
    when false:
      inc m.genericMatches
      inc m.exactMatches
    return
  var marker = initIntSet()
  matchesAux(c, n, nOrig, m, marker)
  if m.state == csNoMatch: return
  # check that every formal parameter got a value:
  var f = 1
  while f < sonsLen(m.callee.n):
    var formal = m.callee.n.sons[f].sym
    if not containsOrIncl(marker, formal.position):
      if formal.ast == nil:
        if formal.typ.kind == tyVarargs:
          # For consistency with what happens in `matchesAux` select the
          # container node kind accordingly
          let cnKind = if formal.typ.isVarargsUntyped: nkArgList else: nkBracket
          var container = newNodeIT(cnKind, n.info, arrayConstr(c, n.info))
          setSon(m.call, formal.position + 1,
                 implicitConv(nkHiddenStdConv, formal.typ, container, m, c))
        else:
          # no default value
          m.state = csNoMatch
          m.firstMismatch.kind = kMissingParam
          m.firstMismatch.formal = formal
          break
      else:
        if formal.ast.kind == nkEmpty:
          # The default param value is set to empty in `instantiateProcType`
          # when the type of the default expression doesn't match the type
          # of the instantiated proc param:
          localError(c.config, m.call.info,
                     ("The default parameter '$1' has incompatible type " &
                      "with the explicitly requested proc instantiation") %
                      formal.name.s)
        if nfDefaultRefsParam in formal.ast.flags:
          m.call.flags.incl nfDefaultRefsParam
        var def = copyTree(formal.ast)
        if def.kind == nkNilLit:
          def = implicitConv(nkHiddenStdConv, formal.typ, def, m, c)
        if {tfImplicitTypeParam, tfGenericTypeParam} * formal.typ.flags != {}:
          put(m, formal.typ, def.typ)
        def.flags.incl nfDefaultParam
        setSon(m.call, formal.position + 1, def)
    inc(f)
  # forget all inferred types if the overload matching failed
  if m.state == csNoMatch:
    for t in m.inferredTypes:
      if t.sonsLen > 1: t.sons.setLen 1

proc argtypeMatches*(c: PContext, f, a: PType, fromHlo = false): bool =
  var m: TCandidate
  initCandidate(c, m, f)
  let res = paramTypesMatch(m, f, a, c.graph.emptyNode, nil)
  #instantiateGenericConverters(c, res, m)
  # XXX this is used by patterns.nim too; I think it's better to not
  # instantiate generic converters for that
  if not fromHlo:
    res != nil
  else:
    # pattern templates do not allow for conversions except from int literal
    res != nil and m.convMatches == 0 and m.intConvMatches in [0, 256]

proc instTypeBoundOp*(c: PContext; dc: PSym; t: PType; info: TLineInfo;
                      op: TTypeAttachedOp; col: int): PSym {.procvar.} =
  var m: TCandidate
  initCandidate(c, m, dc.typ)
  if col >= dc.typ.len:
    localError(c.config, info, "cannot instantiate: '" & dc.name.s & "'")
    return nil
  var f = dc.typ.sons[col]

  if op == attachedDeepCopy:
    if f.kind in {tyRef, tyPtr}: f = f.lastSon
  else:
    if f.kind == tyVar: f = f.lastSon
  #if c.config.selectedGC == gcDestructors and f.kind == tySequence:
  # use the canonical type to access the =sink and =destroy etc.
  #  f = c.graph.sysTypes[tySequence]
  #echo "YUP_---------Formal ", typeToString(f, preferDesc), " real ", typeToString(t, preferDesc), " ", f.id, " ", t.id

  if typeRel(m, f, t) == isNone:
    localError(c.config, info, "cannot instantiate: '" & dc.name.s & "'")
  else:
    result = c.semGenerateInstance(c, dc, m.bindings, info)
    if op == attachedDeepCopy:
      assert sfFromGeneric in result.flags

include suggest

when not declared(tests):
  template tests(s: untyped) = discard

tests:
  var dummyOwner = newSym(skModule, getIdent("test_module"), nil, UnknownLineInfo())

  proc `|` (t1, t2: PType): PType =
    result = newType(tyOr, dummyOwner)
    result.rawAddSon(t1)
    result.rawAddSon(t2)

  proc `&` (t1, t2: PType): PType =
    result = newType(tyAnd, dummyOwner)
    result.rawAddSon(t1)
    result.rawAddSon(t2)

  proc `!` (t: PType): PType =
    result = newType(tyNot, dummyOwner)
    result.rawAddSon(t)

  proc seq(t: PType): PType =
    result = newType(tySequence, dummyOwner)
    result.rawAddSon(t)

  proc array(x: int, t: PType): PType =
    result = newType(tyArray, dummyOwner)

    var n = newNodeI(nkRange, UnknownLineInfo())
    addSon(n, newIntNode(nkIntLit, 0))
    addSon(n, newIntNode(nkIntLit, x))
    let range = newType(tyRange, dummyOwner)

    result.rawAddSon(range)
    result.rawAddSon(t)

  suite "type classes":
    let
      int = newType(tyInt, dummyOwner)
      float = newType(tyFloat, dummyOwner)
      string = newType(tyString, dummyOwner)
      ordinal = newType(tyOrdinal, dummyOwner)
      any = newType(tyAnything, dummyOwner)
      number = int | float

    var TFoo = newType(tyObject, dummyOwner)
    TFoo.sym = newSym(skType, getIdent"TFoo", dummyOwner, UnknownLineInfo())

    var T1 = newType(tyGenericParam, dummyOwner)
    T1.sym = newSym(skType, getIdent"T1", dummyOwner, UnknownLineInfo())
    T1.sym.position = 0

    var T2 = newType(tyGenericParam, dummyOwner)
    T2.sym = newSym(skType, getIdent"T2", dummyOwner, UnknownLineInfo())
    T2.sym.position = 1

    setup:
      var c: TCandidate
      initCandidate(nil, c, nil)

    template yes(x, y) =
      test astToStr(x) & " is " & astToStr(y):
        check typeRel(c, y, x) == isGeneric

    template no(x, y) =
      test astToStr(x) & " is not " & astToStr(y):
        check typeRel(c, y, x) == isNone

    yes seq(any), array(10, int) | seq(any)
    # Sure, seq[any] is directly included

    yes seq(int), seq(any)
    yes seq(int), seq(number)
    # Sure, the int sequence is certainly
    # part of the number sequences (and all sequences)

    no seq(any), seq(float)
    # Nope, seq[any] includes types that are not seq[float] (e.g. seq[int])

    yes seq(int|string), seq(any)
    # Sure

    yes seq(int&string), seq(any)
    # Again

    yes seq(int&string), seq(int)
    # A bit more complicated
    # seq[int&string] is not a real type, but it's analogous to
    # seq[Sortable and Iterable], which is certainly a subset of seq[Sortable]

    no seq(int|string), seq(int|float)
    # Nope, seq[string] is not included in not included in
    # the seq[int|float] set

    no seq(!(int|string)), seq(string)
    # A sequence that is neither seq[int] or seq[string]
    # is obviously not seq[string]

    no seq(!int), seq(number)
    # Now your head should start to hurt a bit
    # A sequence that is not seq[int] is not necessarily a number sequence
    # it could well be seq[string] for example

    yes seq(!(int|string)), seq(!string)
    # all sequnece types besides seq[int] and seq[string]
    # are subset of all sequence types that are not seq[string]

    no seq(!(int|string)), seq(!(string|TFoo))
    # Nope, seq[TFoo] is included in the first set, but not in the second

    no seq(!string), seq(!number)
    # Nope, seq[int] in included in the first set, but not in the second

    yes seq(!number), seq(any)
    yes seq(!int), seq(any)
    no seq(any), seq(!any)
    no seq(!int), seq(!any)

    yes int, ordinal
    no  string, ordinal
