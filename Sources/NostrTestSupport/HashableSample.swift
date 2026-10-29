/// The observed `Hashable` behavior of one type, for a parameterized test across many types.
///
/// Built from two separately constructed equal values and a third that differs, so a test can
/// check that equality is by value, that equal values hash alike, and that a `Set` keeps one copy:
///
/// ```swift
/// let one: Timestamp = 1
/// let sample = HashableSample("Timestamp", one, Timestamp(rawValue: 1), Timestamp(rawValue: 2))
/// ```
public struct HashableSample: Sendable, CustomStringConvertible {
    /// The name of the type under test, shown as the test argument.
    public let description: String

    /// Whether the two equal values compare equal.
    public let equalValuesAreEqual: Bool

    /// Whether the two equal values have the same hash value.
    public let equalValuesHashAlike: Bool

    /// Whether the differing value compares unequal to the others.
    public let differentValueIsUnequal: Bool

    /// The number of elements in a `Set` built from all three values; 2 when hashing is consistent.
    public let setCount: Int

    /// Observes a type's `Hashable` behavior.
    /// - Parameters:
    ///   - name: The name of the type under test.
    ///   - value: A value.
    ///   - equalValue: A separately constructed value equal to `value`.
    ///   - differentValue: A value that differs from `value`.
    public init<Value: Hashable>(_ name: String, _ value: Value, _ equalValue: Value, _ differentValue: Value) {
        description = name
        equalValuesAreEqual = value == equalValue
        equalValuesHashAlike = value.hashValue == equalValue.hashValue
        differentValueIsUnequal = value != differentValue && equalValue != differentValue
        setCount = Set([value, equalValue, differentValue]).count
    }
}
