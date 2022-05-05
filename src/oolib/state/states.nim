import
  std/macros,
  std/sequtils,
  std/sugar,
  .. / util,
  .. / types,
  .. / tmpl,
  state_interface


func hasAsterisk(node: NimNode): bool {.compileTime.} =
  node.kind == nnkPostfix and node[0].eqIdent"*"


func rmAsterisk(node: NimNode): NimNode {.compileTime.} =
  result = node
  if node.hasAsterisk:
    result = node[1]


proc rmAsteriskFromIdent(def: NimNode): NimNode {.compileTime.} =
  result = nnkIdentDefs.newNimNode()
  for v in def[0..^3]:
    result.add v.rmAsterisk
  result.add(def[^2], def[^1])


func toRecList(s: seq[NimNode]): NimNode {.compileTime.} =
  result = nnkRecList.newNimNode()
  for def in s:
    result.add def


proc genConstant(className: string; node: NimNode): NimNode {.compileTime.} =
  ## Generates both a template for use with typedesc and a method for dynamic dispatch.
  newStmtList(
    # template
    nnkTemplateDef.newTree(
      node[0],
      newEmptyNode(),
      newEmptyNode(),
      nnkFormalParams.newTree(
        ident"untyped",
        newIdentDefs(
          ident"self",
          nnkBracketExpr.newTree(
            ident"typedesc",
            ident className
      ),
      newEmptyNode()
    )
      ),
      newEmptyNode(),
      newEmptyNode(),
      newStmtList node[^1]
    ),
    # method
    nnkMethodDef.newTree(
      node[0],
      newEmptyNode(),
      newEmptyNode(),
      nnkFormalParams.newTree(
        node[1],
        newIdentDefs(
          ident"self",
          ident className,
          newEmptyNode(),
      )
    ),
      nnkPragma.newTree ident"optBase",
      newEmptyNode(),
      newStmtList nnkReturnStmt.newTree(node[^1])
    ),
  )


template markWithPostfix(node) =
  node = nnkPostfix.newTree(ident"*", node)


template newPragmaExpr(node; pragma: string) =
  node = nnkPragmaExpr.newTree(
    node,
    nnkPragma.newTree(ident pragma)
  )


func decomposeDefsIntoVars(s: seq[NimNode]): seq[NimNode] {.compileTime.} =
  result = collect:
    for def in s:
      for v in def[0..^3]:
        if v.kind == nnkPragmaExpr: v[0]
        else: v


func newSelfStmt(typeName: NimNode): NimNode {.compileTime.} =
  ## Generates `var self = typeName()`.
  newVarStmt(ident"self", newCall typeName)


func newResultAsgn(rhs: string): NimNode {.compileTime.} =
  newAssignment ident"result", ident rhs


func insertBody(
    constructor: NimNode;
    vars: seq[NimNode]
): NimNode {.compileTime.} =
  result = constructor
  if result.body[0].kind == nnkDiscardStmt:
    return
  result.body.insert 0, newSelfStmt(result.params[0])
  for v in vars.decomposeDefsIntoVars():
    result.body.insert 1, getAst(asgnWith v)
  result.body.add newResultAsgn"self"


proc insertArgs(
    constructor: NimNode;
    vars: seq[NimNode]
) {.compileTime.} =
  ## Inserts `vars` to constructor args.
  for v in vars:
    constructor.params.add v


proc nameWithGenerics(info: ClassInfo): NimNode {.compileTime.} =
  ## Return `name[T, U]` if a class has generics.
  result = info.name
  if info.generics != @[]:
    result = nnkBracketExpr.newTree(
      result & info.generics
    )


proc addOldSignatures(
    constructor: NimNode;
    info: ClassInfo;
    args: seq[NimNode]
): NimNode {.compileTime.} =
  ## Adds signatures to `constructor`.
  constructor.name = ident "new"&info.name.strVal
  if info.isPub:
    markWithPostfix(constructor.name)
  constructor.params[0] = info.name
  constructor.insertArgs(args)
  return constructor


proc addSignatures(
    constructor: NimNode;
    info: ClassInfo;
    args: seq[NimNode]
): NimNode {.compileTime.} =
  ## Adds signatures to `constructor`.
  constructor.name = ident"new"
  if info.isPub:
    markWithPostfix(constructor.name)
  constructor.params[0] = info.nameWithGenerics
  constructor.insertArgs(args)
  constructor.params.insert 1, newIdentDefs(
    ident"_",
    nnkBracketExpr.newTree(
      ident"typedesc",
      info.nameWithGenerics
    )
  )
  return constructor


proc assistWithOldDef(
    constructor: NimNode;
    info: ClassInfo;
    args: seq[NimNode]
): NimNode {.compileTime.} =
  ## Adds signatures and insert body to `constructor`.
  constructor
    .addOldSignatures(info, args)
    .insertBody(args)


proc assistWithDef(
    constructor: NimNode;
    info: ClassInfo;
    args: seq[NimNode]
): NimNode {.compileTime.} =
  ## Adds signatures and insert body to `constructor`.
  constructor[2] = nnkGenericParams.newTree(
    nnkIdentDefs.newTree(
      info.generics & newEmptyNode() & newEmptyNode()
    )
  )
  constructor
    .addSignatures(info, args)
    .insertBody(args)


func rmSelf(theProc: NimNode): NimNode {.compileTime.} =
  ## Removes `self: typeName` from the 1st of theProc.params.
  result = theProc.copy
  result.params.del(1, 1)


func newVarsColonExpr(v: NimNode): NimNode {.compileTime.} =
  newColonExpr(v, newDotExpr(ident"self", v))


func newLambdaColonExpr(theProc: NimNode): NimNode {.compileTime.} =
  ## Generates `name: proc() = self.name()`.
  var lambdaProc = theProc.rmSelf()
  let name = lambdaProc[0]
  lambdaProc[0] = newEmptyNode()
  lambdaProc.body = newDotExpr(ident"self", name).newCall(
    lambdaProc.params[1..^1].mapIt(it[0])
  )
  result = newColonExpr(name, lambdaProc)


func isSuperFunc(node: NimNode): bool {.compileTime.} =
  ## Returns whether struct is `super.f()` or not.
  node.kind == nnkCall and
  node[0].kind == nnkDotExpr and
  node[0][0].eqIdent"super"


proc replaceSuper(node: NimNode): NimNode =
  ## Replaces `super.f()` with `procCall Base(self).f()`.
  result = node
  if node.isSuperFunc:
    return newTree(
      nnkCommand,
      ident "procCall",
      copyNimTree(node)
    )
  for i, n in node:
    result[i] = n.replaceSuper()


proc genNewBody(
    typeName: NimNode;
    vars: seq[NimNode]
): NimNode {.compileTime.} =
  result = newStmtList(newSelfStmt typeName)
  for v in vars:
    result.insert(1, getAst asgnWith(v))
  result.add newResultAsgn"self"


proc defOldNew(info: ClassInfo; args: seq[NimNode]): NimNode =
  var
    name = ident "new"&strVal(info.name)
    params = info.name&args
    body = genNewBody(
      info.name,
      args.decomposeDefsIntoVars()
    )
  result = newProc(name, params, body)
  if info.isPub:
    markWithPostfix(result.name)
  result[4] = nnkPragma.newTree(
    newColonExpr(ident"deprecated", newLit"Use Type.new instead")
  )


proc defNew(info: ClassInfo; args: seq[NimNode]): NimNode =
  var
    name = ident"new"
    params = info.nameWithGenerics&(
      newIdentDefs(
        ident"_",
        nnkBracketExpr.newTree(ident"typedesc", info.nameWithGenerics)
      )&args
    )
    body = genNewBody(
      info.nameWithGenerics,
      args.decomposeDefsIntoVars()
    )
  result = newProc(name, params, body)
  result[2] = nnkGenericParams.newTree(
    nnkIdentDefs.newTree(
      info.generics & newEmptyNode() & newEmptyNode()
    )
  )
  if info.isPub:
    markWithPostfix(result.name)


func allArgsList(members: ClassMembers): seq[NimNode] {.compileTime.} =
  members.argsList & members.ignoredArgsList


func withoutDefault(argsList: seq[NimNode]): seq[NimNode] =
  result = collect:
    for v in argsList:
      v[^1] = newEmptyNode()
      v


func isEmpty(node: NimNode): bool {.compileTime.} =
  node.kind == nnkEmpty


func hasDefault(node: NimNode): bool {.compileTime.} =
  ## `node` has to be `nnkIdentDefs` or `nnkConstDef`.
  node.expectKind {nnkIdentDefs, nnkConstDef}
  not node.last.isEmpty


func insertSelf(theProc, typeName: NimNode): NimNode {.compileTime.} =
  ## Inserts `self: typeName` in the 1st of theProc.params.
  result = theProc
  result.params.insert 1, newIdentDefs(ident"self", typeName)


func inferValType(node: NimNode) {.compileTime.} =
  ## Infers type from default if a type annotation is empty.
  ## `node` has to be `nnkIdentDefs` or `nnkConstDef`.
  node.expectKind {nnkIdentDefs, nnkConstDef}
  node[^2] = node[^2] or newCall(ident"typeof", node[^1])


func isConstructor(node: NimNode): bool {.compileTime.} =
  ## `node` has to be `nnkProcDef`.
  node.expectKind {nnkProcDef}
  node[0].kind == nnkAccQuoted and node.name.eqIdent"new"


func hasPragma(node: NimNode): bool {.compileTime.} =
  ## `node` has to be `nnkIdentDefs or nnkConstDef`.
  node.expectKind {nnkIdentDefs, nnkConstDef}
  node[0].kind == nnkPragmaExpr


func newSuperStmt(baseName: NimNode): NimNode {.compileTime.} =
  ## Generates `var super = Base(self)`.
  newVarStmt ident"super", newCall(baseName, ident "self")


func insertSuperStmt(theProc, baseName: NimNode): NimNode {.compileTime.} =
  ## Inserts `var super = Base(self)` in the 1st line of `theProc.body`.
  result = theProc
  result.body.insert 0, newSuperStmt(baseName)


type
  NormalState* = ref object

  InheritanceState* = ref object

  DistinctState* = ref object

  AliasState* = ref object

  ImplementationState* = ref object


proc getClassMembers(
  self: NormalState;
  body: NimNode;
  info: ClassInfo
): ClassMembers {.compileTime.} =
  result.body = newStmtList()
  result.ctorBase = newEmptyNode()
  result.ctorBase2 = newEmptyNode()
  for node in body:
    case node.kind
    of nnkVarSection:
      for n in node:
        if "noNewDef" in info.pragmas and n.hasDefault:
          error "default values cannot be used with {.noNewDef.}", n
        if info.generics.anyIt(it.eqIdent n[^2]):
          error "A member variable with generic type is not supported for now"
        n.inferValType()
        if n.hasPragma and "ignored" in n[0][1]:
          error "{.ignored.} pragma cannot be used in non-implemented classes"
        result.argsList.add n
    of nnkConstSection:
      for n in node:
        if not n.hasDefault:
          error "A constant must have a value", node
        if info.generics.anyIt(it.eqIdent n):
          error "A constant with generic type cannot be used"
        n.inferValType()
        result.constsList.add n
    of nnkProcDef:
      if node.isConstructor:
        if result.ctorBase.isEmpty:
          result.ctorBase = node.copy()
          result.ctorBase[4] = nnkPragma.newTree(
            newColonExpr(ident"deprecated", newLit"Use Type.new instead")
          )
          result.ctorBase2 = node.copy()
        else:
          error "Constructor already exists", node
      else:
        result.body.add node.insertSelf(info.nameWithGenerics)
    of nnkMethodDef, nnkFuncDef, nnkIteratorDef, nnkConverterDef, nnkTemplateDef:
      result.body.add node.insertSelf(info.nameWithGenerics)
    else:
      discard


proc defClass(
    self: NormalState;
    theClass: NimNode;
    info: ClassInfo
) {.compileTime.} =
  theClass.add(getAst defObj(info.name))
  if info.generics != @[]:
    theClass[0][0][1] = nnkGenericParams.newTree(
      nnkIdentDefs.newTree(
        info.generics & newEmptyNode() & newEmptyNode()
      )
    )
  if info.isPub:
    markWithPostfix(theClass[0][0][0])
  if "open" in info.pragmas:
    theClass[0][0][2][0][1] = nnkOfInherit.newTree ident"RootObj"
  newPragmaExpr(theClass[0][0][0], "pClass")


proc defConstructor(
    self: NormalState;
    theClass: NimNode;
    info: ClassInfo;
    members: ClassMembers
) {.compileTime.} =
  if "noNewDef" in info.pragmas:
    return
  theClass.insert(
    1,
    if members.ctorBase.isEmpty:
      info.defOldNew(members.argsList.map rmAsteriskFromIdent)
    else:
      members.ctorBase.assistWithOldDef(
        info,
        members.argsList.filter(hasDefault).map rmAsteriskFromIdent
      )
  )
  theClass.insert(
    1,
    if members.ctorBase2.isEmpty:
      info.defNew(members.argsList.map rmAsteriskFromIdent)
    else:
      members.ctorBase2.assistWithDef(
        info,
        members.argsList.filter(hasDefault).map rmAsteriskFromIdent
      )
  )


proc defMemberVars(
    self: NormalState;
    theClass: NimNode;
    members: ClassMembers
) {.compileTime.} =
  theClass[0][0][2][0][2] = members.argsList.withoutDefault().toRecList()


proc defMemberRoutines(
    self: NormalState;
    theClass: NimNode;
    info: ClassInfo;
    members: ClassMembers
) {.compileTime.} =
  for c in members.constsList:
    theClass.insert 1, genConstant(info.name.strVal, c)


proc toInterface*(self: NormalState): IState {.compileTime.} =
  result = (
    getClassMembers:
    (body: NimNode, info: ClassInfo) => self.getClassMembers(body, info),
    defClass: (theClass: NimNode, info: ClassInfo) => self.defClass(theClass, info),
    defConstructor:
    (theClass: NimNode, info: ClassInfo, members: ClassMembers) =>
      self.defConstructor(theClass, info, members),
    defMemberVars: (theClass: NimNode, members: ClassMembers) =>
      self.defMemberVars(theClass, members),
    defMemberRoutines: (theClass: NimNode, info: ClassInfo,
        members: ClassMembers) =>
      self.defMemberRoutines(theClass, info, members)

  )


proc getClassMembers(
  self: InheritanceState;
  body: NimNode;
  info: ClassInfo
): ClassMembers {.compileTime.} =
  result.body = newStmtList()
  result.ctorBase = newEmptyNode()
  result.ctorBase2 = newEmptyNode()
  for node in body:
    case node.kind
    of nnkVarSection:
      for n in node:
        if "noNewDef" in info.pragmas and n.hasDefault:
          error "default values cannot be used with {.noNewDef.}", n
        if n.hasPragma and "ignored" in n[0][1]:
          error "{.ignored.} pragma cannot be used in non-implemented classes"
        n.inferValType()
        result.argsList.add n
    of nnkConstSection:
      for n in node:
        if not n.hasDefault:
          error "A constant must have a value", node
        n.inferValType()
        result.constsList.add n
    of nnkProcDef:
      if node.isConstructor:
        if result.ctorBase.isEmpty:
          result.ctorBase = node.copy()
          result.ctorBase[4] = nnkPragma.newTree(
            newColonExpr(ident"deprecated", newLit"Use Type.new instead")
          )
          result.ctorBase2 = node.copy()
        else:
          error "Constructor already exists", node
      else:
        result.body.add node.insertSelf(info.name)
    of nnkMethodDef:
      node.body = replaceSuper(node.body)
      result.body.add node.insertSelf(info.name).insertSuperStmt(info.base)
    of nnkFuncDef, nnkIteratorDef, nnkConverterDef, nnkTemplateDef:
      result.body.add node.insertSelf(info.name)
    else:
      discard


proc defClass(
    self: InheritanceState;
    theClass: NimNode;
    info: ClassInfo
) {.compileTime.} =
  theClass.add getAst defObjWithBase(info.name, info.base)
  if info.isPub:
    markWithPostfix(theClass[0][0][0])
  newPragmaExpr(theClass[0][0][0], "pClass")


proc defConstructor(
    self: InheritanceState;
    theClass: NimNode;
    info: ClassInfo;
    members: ClassMembers
) {.compileTime.} =
  if not (members.ctorBase.isEmpty or "noNewDef" in info.pragmas):
    theClass.insert 1, members.ctorBase.assistWithOldDef(
      info,
      members.argsList.filter(hasDefault).map rmAsteriskFromIdent
    )
    theClass.insert 1, members.ctorBase2.assistWithDef(
      info,
      members.argsList.filter(hasDefault).map rmAsteriskFromIdent
    )


proc defMemberVars(
    self: InheritanceState;
    theClass: NimNode;
    members: ClassMembers
) {.compileTime.} =
  theClass[0][0][2][0][2] = members.argsList.withoutDefault().toRecList()


proc defMemberRoutines(
    self: InheritanceState;
    theClass: NimNode;
    info: ClassInfo;
    members: ClassMembers
) {.compileTime.} =
  for c in members.constsList:
    theClass.insert 1, genConstant(info.name.strVal, c)


proc toInterface*(self: InheritanceState): IState {.compileTime.} =
  result = (
    getClassMembers:
    (body: NimNode, info: ClassInfo) => self.getClassMembers(body, info),
    defClass: (theClass: NimNode, info: ClassInfo) => self.defClass(theClass, info),
    defConstructor:
    (theClass: NimNode, info: ClassInfo, members: ClassMembers) =>
      self.defConstructor(theClass, info, members),
    defMemberVars: (theClass: NimNode, members: ClassMembers) =>
      self.defMemberVars(theClass, members),
    defMemberRoutines: (theClass: NimNode, info: ClassInfo,
        members: ClassMembers) =>
      self.defMemberRoutines(theClass, info, members)
  )


proc getClassMembers(
  self: DistinctState;
  body: NimNode;
  info: ClassInfo
): ClassMembers {.compileTime.} =
  result.body = newStmtList()
  for node in body:
    case node.kind
    of nnkVarSection:
      error "Distinct type cannot have variables", node
    of nnkConstSection:
      for n in node:
        if not n.hasDefault:
          error "A constant must have a value", node
        n.inferValType()
        result.constsList.add n
    of nnkProcDef, nnkMethodDef, nnkFuncDef, nnkIteratorDef, nnkConverterDef, nnkTemplateDef:
      result.body.add node.insertSelf(info.name)
    else:
      discard


proc defClass(
    self: DistinctState;
    theClass: NimNode;
    info: ClassInfo
) {.compileTime.} =
  theClass.add getAst defDistinct(info.name, info.base)
  if info.isPub:
    markWithPostfix(theClass[0][0][0][0])
  if "open" in info.pragmas:
    # replace {.final.} with {.inheritable.}
    theClass[0][0][0][1][0] = ident "inheritable"
    theClass[0][0][0][1].add ident "pClass"


proc defConstructor(
    self: DistinctState;
    theClass: NimNode;
    info: ClassInfo;
    members: ClassMembers
) {.compileTime.} =
  discard


proc defMemberVars(
    self: DistinctState;
    theClass: NimNode;
    members: ClassMembers
) {.compileTime.} =
  discard


proc defMemberRoutines(
    self: DistinctState;
    theClass: NimNode;
    info: ClassInfo;
    members: ClassMembers
) {.compileTime.} =
  for c in members.constsList:
    theClass.insert 1, genConstant(info.name.strVal, c)


proc toInterface*(self: DistinctState): IState {.compileTime.} =
  result = (
    getClassMembers:
    (body: NimNode, info: ClassInfo) => self.getClassMembers(body, info),
    defClass: (theClass: NimNode, info: ClassInfo) => self.defClass(theClass, info),
    defConstructor:
    (theClass: NimNode, info: ClassInfo, members: ClassMembers) =>
      self.defConstructor(theClass, info, members),
    defMemberVars: (theClass: NimNode, members: ClassMembers) =>
      self.defMemberVars(theClass, members),
    defMemberRoutines: (theClass: NimNode, info: ClassInfo,
        members: ClassMembers) =>
      self.defMemberRoutines(theClass, info, members)


  )


proc getClassMembers(
  self: AliasState;
  body: NimNode;
  info: ClassInfo
): ClassMembers {.compileTime.} =
  result.body = newStmtList()
  for node in body:
    case node.kind
    of nnkVarSection:
      error "Type alias cannot have variables", node
    of nnkConstSection:
      for n in node:
        if not n.hasDefault:
          error "A constant must have a value", node
        n.inferValType()
        result.constsList.add n
    of nnkProcDef, nnkMethodDef, nnkFuncDef, nnkIteratorDef, nnkConverterDef, nnkTemplateDef:
      result.body.add node.insertSelf(info.name)
    else:
      discard


proc defClass(
    self: AliasState;
    theClass: NimNode;
    info: ClassInfo
) {.compileTime.} =
  theClass.add getAst defAlias(info.name, info.base)
  if info.isPub:
    markWithPostfix(theClass[0][0][0])
  newPragmaExpr(theClass[0][0][0], "pClass")


proc defConstructor(
    self: AliasState;
    theClass: NimNode;
    info: ClassInfo;
    members: ClassMembers
) {.compileTime.} =
  discard


proc defMemberVars(
    self: AliasState;
    theClass: NimNode;
    members: ClassMembers
) {.compileTime.} =
  discard


proc defMemberRoutines(
    self: AliasState;
    theClass: NimNode;
    info: ClassInfo;
    members: ClassMembers
) {.compileTime.} =
  for c in members.constsList:
    theClass.insert 1, genConstant(info.name.strVal, c)


proc toInterface*(self: AliasState): IState {.compileTime.} =
  result = (
    getClassMembers:
    (body: NimNode, info: ClassInfo) => self.getClassMembers(body, info),
    defClass: (theClass: NimNode, info: ClassInfo) => self.defClass(theClass, info),
    defConstructor:
    (theClass: NimNode, info: ClassInfo, members: ClassMembers) =>
      self.defConstructor(theClass, info, members),
    defMemberVars: (theClass: NimNode, members: ClassMembers) =>
      self.defMemberVars(theClass, members),
    defMemberRoutines: (theClass: NimNode, info: ClassInfo,
        members: ClassMembers) =>
      self.defMemberRoutines(theClass, info, members)


  )


proc getClassMembers(
  self: ImplementationState;
  body: NimNode;
  info: ClassInfo
): ClassMembers {.compileTime.} =
  result.body = newStmtList()
  result.ctorBase = newEmptyNode()
  result.ctorBase2 = newEmptyNode()
  for node in body:
    case node.kind
    of nnkVarSection:
      for n in node:
        if "noNewDef" in info.pragmas and n.hasDefault:
          error "default values cannot be used with {.noNewDef.}", n
        n.inferValType()
        if n.hasPragma and "ignored" in n[0][1]:
          result.ignoredArgsList.add n
        else:
          result.argsList.add n
    of nnkConstSection:
      for n in node:
        if not n.hasDefault:
          error "A constant must have a value", node
        n.inferValType()
        result.constsList.add n
    of nnkProcDef:
      if node.isConstructor:
        if result.ctorBase.isEmpty:
          result.ctorBase = node.copy()
          result.ctorBase[4] = nnkPragma.newTree(
            newColonExpr(ident"deprecated", newLit"Use Type.new instead")
          )
          result.ctorBase2 = node.copy()
        else:
          error "Constructor already exists", node
      else:
        result.body.add node.insertSelf(info.name)
    of nnkMethodDef, nnkFuncDef, nnkIteratorDef, nnkConverterDef, nnkTemplateDef:
      result.body.add node.insertSelf(info.name)
    else:
      discard


proc defClass(
    self: ImplementationState;
    theClass: NimNode;
    info: ClassInfo
) {.compileTime.} =
  theClass.add getAst defObj(info.name)
  if info.isPub:
    markWithPostfix(theClass[0][0][0])
  newPragmaExpr(theClass[0][0][0], "pClass")


proc defConstructor(
    self: ImplementationState;
    theClass: NimNode;
    info: ClassInfo;
    members: ClassMembers
) {.compileTime.} =
  if "noNewDef" in info.pragmas:
    return
  theClass.insert(
    1,
    if members.ctorBase.isEmpty:
      info.defOldNew(members.allArgsList.map rmAsteriskFromIdent)
    else:
      members.ctorBase.assistWithOldDef(
        info,
        members.allArgsList.filter(hasDefault).map rmAsteriskFromIdent
      )
  )
  theClass.insert(
    1,
    if members.ctorBase2.isEmpty:
      info.defNew(members.allArgsList.map rmAsteriskFromIdent)
    else:
      members.ctorBase2.assistWithDef(
        info,
        members.allArgsList.filter(hasDefault).map rmAsteriskFromIdent
      )
  )


proc defMemberVars(
    self: ImplementationState;
    theClass: NimNode;
    members: ClassMembers
) {.compileTime.} =
  theClass[0][0][2][0][2] = members.allArgsList.withoutDefault().toRecList()


proc defMemberRoutines(
    self: ImplementationState;
    theClass: NimNode;
    info: ClassInfo;
    members: ClassMembers
) {.compileTime.} =
  for c in members.constsList:
    theClass.insert 1, genConstant(info.name.strVal, c)
  theClass.add newProc(
    ident"toInterface",
    [info.base],
    newStmtList(
      nnkReturnStmt.newNimNode.add(
        nnkTupleConstr.newNimNode.add(
          members.argsList.decomposeDefsIntoVars().map newVarsColonExpr
    ).add(
        members.body.filterIt(
          it.kind in {nnkProcDef, nnkFuncDef, nnkMethodDef, nnkIteratorDef}
      ).filterIt("ignored" notin it[4]).map newLambdaColonExpr
    )
    )
    )
  ).insertSelf(info.name)


proc toInterface*(self: ImplementationState): IState {.compileTime.} =
  result = (
    getClassMembers:
    (body: NimNode, info: ClassInfo) => self.getClassMembers(body, info),
    defClass: (theClass: NimNode, info: ClassInfo) => self.defClass(theClass, info),
    defConstructor:
    (theClass: NimNode, info: ClassInfo, members: ClassMembers) =>
      self.defConstructor(theClass, info, members),
    defMemberVars: (theClass: NimNode, members: ClassMembers) =>
      self.defMemberVars(theClass, members),
    defMemberRoutines: (theClass: NimNode, info: ClassInfo,
        members: ClassMembers) =>
      self.defMemberRoutines(theClass, info, members)

  )


proc newState*(info: ClassInfo): IState {.compileTime.} =
  result = case info.kind
    of ClassKind.Normal: NormalState().toInterface()
    of ClassKind.Inheritance: InheritanceState().toInterface()
    of ClassKind.Distinct: DistinctState().toInterface()
    of ClassKind.Alias: AliasState().toInterface()
    of ClassKind.Implementation: ImplementationState().toInterface()
