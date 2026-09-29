// MARK: - Visibility Condition

/// When a piece of content is visible, stated in terms of named options.
///
/// A printer whose output depends on its configuration — a comment only
/// some configurations ask for, a member only some configurations keep — can
/// print everything once and attach a condition to each such piece with
/// `VisibilityRegion`. A reader later picks any configuration and projects
/// the text to what the printer would have produced for it (see
/// `VisibilityRegionTable`).
///
/// The condition is in disjunctive normal form: it holds when every
/// requirement of at least one alternative holds. No alternatives at all
/// means the content is never visible; an alternative with no requirements
/// means it always is. The option names belong to the caller — this library
/// never interprets them — and must not contain control characters, which
/// the encoding in `AtomicComponent.identifier` reserves.
///
/// Values are normalized on construction, so two conditions that hold for
/// exactly the same option values compare equal when they differ only in the
/// order of their requirements or alternatives, in duplicates, in
/// contradictory alternatives (which can never hold and are dropped), or in
/// alternatives subsumed by a weaker one.
public struct VisibilityCondition: Hashable, Sendable {
    /// One option in one state.
    public struct Requirement: Hashable, Sendable, Comparable {
        public let option: String

        /// `true`: the option must be enabled. `false`: it must be disabled.
        public let isEnabled: Bool

        @inlinable
        public init(option: String, isEnabled: Bool) {
            precondition(!option.isEmpty, "a visibility option needs a name")
            precondition(
                !option.unicodeScalars.contains { $0.value < 0x20 },
                "a visibility option name must not contain control characters"
            )
            self.option = option
            self.isEnabled = isEnabled
        }

        @inlinable
        public static func < (lhs: Requirement, rhs: Requirement) -> Bool {
            if lhs.option != rhs.option {
                return lhs.option < rhs.option
            }
            return !lhs.isEnabled && rhs.isEnabled
        }
    }

    /// The alternatives, each a conjunction of requirements, normalized.
    public let alternatives: [[Requirement]]

    @inlinable
    public init(alternatives: [[Requirement]]) {
        self.alternatives = Self.normalized(alternatives)
    }

    /// Visible whatever the options are.
    public static let always = VisibilityCondition(alternatives: [[]])

    /// Visible under no options at all.
    public static let never = VisibilityCondition(alternatives: [])

    /// Visible when `option` is enabled.
    @inlinable
    public static func enabled(_ option: String) -> VisibilityCondition {
        VisibilityCondition(alternatives: [[Requirement(option: option, isEnabled: true)]])
    }

    /// Visible when `option` is disabled.
    @inlinable
    public static func disabled(_ option: String) -> VisibilityCondition {
        VisibilityCondition(alternatives: [[Requirement(option: option, isEnabled: false)]])
    }

    /// Visible when every one of `conditions` holds. An empty list is
    /// `always`.
    @inlinable
    public static func all(_ conditions: [VisibilityCondition]) -> VisibilityCondition {
        var alternatives: [[Requirement]] = [[]]
        for condition in conditions {
            var combined: [[Requirement]] = []
            combined.reserveCapacity(alternatives.count * condition.alternatives.count)
            for existing in alternatives {
                for added in condition.alternatives {
                    combined.append(existing + added)
                }
            }
            alternatives = Self.normalized(combined)
            if alternatives.isEmpty {
                return .never
            }
        }
        return VisibilityCondition(alternatives: alternatives)
    }

    /// Visible when at least one of `conditions` holds. An empty list is
    /// `never`.
    @inlinable
    public static func any(_ conditions: [VisibilityCondition]) -> VisibilityCondition {
        VisibilityCondition(alternatives: conditions.flatMap(\.alternatives))
    }

    /// Whether the condition holds for every option value.
    @inlinable
    public var isAlways: Bool {
        alternatives.count == 1 && alternatives[0].isEmpty
    }

    /// Whether the condition holds for no option value.
    @inlinable
    public var isNever: Bool {
        alternatives.isEmpty
    }

    /// Whether the condition holds when each option is enabled exactly when
    /// `isOptionEnabled` says so.
    @inlinable
    public func isSatisfied(where isOptionEnabled: (String) -> Bool) -> Bool {
        alternatives.contains { alternative in
            alternative.allSatisfy { isOptionEnabled($0.option) == $0.isEnabled }
        }
    }

    /// Sorted, duplicate-free alternatives with no contradictory alternative
    /// and none subsumed by another (an alternative whose requirements are a
    /// subset of another's makes the larger one redundant).
    @usableFromInline
    static func normalized(_ alternatives: [[Requirement]]) -> [[Requirement]] {
        var consistentAlternatives: [[Requirement]] = []
        consistentAlternatives.reserveCapacity(alternatives.count)
        for alternative in alternatives {
            let sortedRequirements = Array(Set(alternative)).sorted()
            var isContradictory = false
            var previousRequirement: Requirement?
            for requirement in sortedRequirements {
                if let previousRequirement, previousRequirement.option == requirement.option {
                    isContradictory = true
                    break
                }
                previousRequirement = requirement
            }
            if !isContradictory {
                consistentAlternatives.append(sortedRequirements)
            }
        }
        consistentAlternatives.sort { lhs, rhs in
            if lhs.count != rhs.count {
                return lhs.count < rhs.count
            }
            return lhs.lexicographicallyPrecedes(rhs)
        }
        var minimalAlternatives: [[Requirement]] = []
        var minimalRequirementSets: [Set<Requirement>] = []
        for alternative in consistentAlternatives {
            let requirementSet = Set(alternative)
            if minimalRequirementSets.contains(where: { $0.isSubset(of: requirementSet) }) {
                continue
            }
            minimalAlternatives.append(alternative)
            minimalRequirementSets.append(requirementSet)
        }
        return minimalAlternatives
    }
}
