// Opts the library's own leaves into the zero-allocation streaming path.
//
// Every type listed here inherits `buildComponents()` from
// `AtomicSemanticComponent` unchanged, which is exactly what
// `PlainAtomicSemanticComponent` promises. Adding a leaf that *overrides*
// `buildComponents()` to this list would make it render one way through
// `append` and another through a `@SemanticStringBuilder`; leave such a type
// conforming to `AtomicSemanticComponent` only.
//
// `AtomicComponent` is deliberately absent: it overrides `buildComponents()`
// so that `identifier` survives flattening.

extension Keyword: PlainAtomicSemanticComponent {}
extension Variable: PlainAtomicSemanticComponent {}
extension Numeric: PlainAtomicSemanticComponent {}
extension Argument: PlainAtomicSemanticComponent {}
extension Error: PlainAtomicSemanticComponent {}
extension Standard: PlainAtomicSemanticComponent {}

extension Comment: PlainAtomicSemanticComponent {}
extension InlineComment: PlainAtomicSemanticComponent {}
extension MultipleLineComment: PlainAtomicSemanticComponent {}

extension TypeName: PlainAtomicSemanticComponent {}
extension TypeDeclaration: PlainAtomicSemanticComponent {}
extension MemberName: PlainAtomicSemanticComponent {}
extension MemberDeclaration: PlainAtomicSemanticComponent {}
extension FunctionName: PlainAtomicSemanticComponent {}
extension FunctionDeclaration: PlainAtomicSemanticComponent {}

extension Space: PlainAtomicSemanticComponent {}
extension BreakLine: PlainAtomicSemanticComponent {}
extension Indent: PlainAtomicSemanticComponent {}
