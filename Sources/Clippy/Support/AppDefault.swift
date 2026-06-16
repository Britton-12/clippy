import Combine
import Foundation

// MARK: - AppDefault property wrapper
//
// Collapses the repetitive @Published + didSet + UserDefaults.set pattern
// used throughout AppSettings into a single declaration line.
//
// Why the enclosing-instance subscript matters:
//   A plain property wrapper cannot reach the enclosing ObservableObject to
//   fire objectWillChange. Swift exposes a static subscript hook (SE-0258)
//   that the compiler calls instead of the wrappedValue accessor when the
//   wrapper is used inside a class. That hook receives the instance, so we
//   can call objectWillChange.send() *before* storing the new value, which
//   is the same timing @Published uses.
//
// Two storage strategies (via overloaded inits, not conditional conformance
// -- Swift does not allow conditional conformance on property wrappers):
//   (a) Value is a UserDefaults-native plist type: stored and read directly.
//   (b) Value: RawRepresentable with a plist RawValue: rawValue stored,
//       Value(rawValue:) read back; falls back to the declared default on
//       an unrecognized stored string.
//
// UserDefaults coupling:
//   The wrapper always reads/writes UserDefaults.standard. AppSettings
//   accepts a custom `defaults` injected at init (used only in the
//   private init for the shared singleton via `.standard`). No test
//   constructs AppSettings with a custom UserDefaults -- every test uses
//   AppSettings.shared -- so hardwiring .standard does not break any
//   existing test seam. This is documented explicitly so a future reader
//   knows it is a deliberate trade-off, not an oversight.

@propertyWrapper
struct AppDefault<Value> {

    // MARK: Storage

    let key: String
    let defaultValue: Value

    // How to read/write. Captured at init time so the subscript
    // does not need to know which strategy was chosen.
    private let read: (UserDefaults) -> Value
    private let write: (UserDefaults, Value) -> Void

    // MARK: Inits

    /// Plist-native init: Bool, Int, Double, String, [String], Data.
    init(_ key: String, default defaultValue: Value)
    where Value: UserDefaultsStorable {
        self.key = key
        self.defaultValue = defaultValue
        self.read = { $0.appDefaultRead(forKey: key) ?? defaultValue }
        self.write = { $0.appDefaultWrite($1, forKey: key) }
    }

    /// RawRepresentable init: stores rawValue, reads back via init(rawValue:).
    init<R>(_ key: String, default defaultValue: Value)
    where Value: RawRepresentable, Value.RawValue == R, R: UserDefaultsStorable {
        self.key = key
        self.defaultValue = defaultValue
        self.read = { ud in
            guard let raw: R = ud.appDefaultRead(forKey: key) else { return defaultValue }
            return Value(rawValue: raw) ?? defaultValue
        }
        self.write = { ud, v in ud.appDefaultWrite(v.rawValue, forKey: key) }
    }

    // MARK: wrappedValue (fallback accessor)
    //
    // The compiler calls the static subscript below when the wrapper is
    // inside a class. This accessor is required by the Swift grammar but
    // is never reached via normal AppSettings use.
    var wrappedValue: Value {
        get { read(.standard) }
        set { write(.standard, newValue) }
    }

    // MARK: Enclosing-instance subscript
    //
    // This is the load-bearing path for ObservableObject observation.
    // Called by the compiler instead of `wrappedValue` when the wrapper
    // is declared inside a reference type. Fires objectWillChange *before*
    // writing so SwiftUI sees the change in the same runloop turn as
    // @Published does.
    //
    // Why the where clause:
    //   The ObservableObject protocol declares `objectWillChange` with an
    //   associated type (ObjectWillChangePublisher). Without the constraint
    //   below, the only way to call .send() here is via a conditional cast
    //   (as? ObservableObjectPublisher), which silently does nothing if the
    //   enclosing type ever uses a custom publisher. Constraining
    //   ObjectWillChangePublisher == ObservableObjectPublisher lets the
    //   compiler prove the assignment statically: no cast, no silent failure.
    //   Any type that violates the constraint gets a compile error rather
    //   than a runtime no-op. AppSettings and FixtureSettings both satisfy
    //   the constraint because Swift synthesizes ObservableObjectPublisher
    //   when no explicit objectWillChange is declared.
    static subscript<EnclosingSelf: ObservableObject>(
        _enclosingInstance instance: EnclosingSelf,
        wrapped wrappedKeyPath: ReferenceWritableKeyPath<EnclosingSelf, Value>,
        storage storageKeyPath: ReferenceWritableKeyPath<EnclosingSelf, Self>
    ) -> Value where EnclosingSelf.ObjectWillChangePublisher == ObservableObjectPublisher {
        get {
            let wrapper = instance[keyPath: storageKeyPath]
            return wrapper.read(.standard)
        }
        set {
            // Fire objectWillChange before persisting so SwiftUI observers
            // are notified in the willChange pass, matching @Published semantics.
            // The where clause above proves ObjectWillChangePublisher is
            // ObservableObjectPublisher at compile time, so .send() is called
            // directly with no cast.
            instance.objectWillChange.send()
            let wrapper = instance[keyPath: storageKeyPath]
            wrapper.write(.standard, newValue)
        }
    }
}

// MARK: - UserDefaultsStorable
//
// Marker protocol covering every type that UserDefaults can store/retrieve
// without encoding. We provide typed read/write helpers so the wrapper
// above does not need to switch on type at runtime.

protocol UserDefaultsStorable {}

extension Bool:     UserDefaultsStorable {}
extension Int:      UserDefaultsStorable {}
extension Double:   UserDefaultsStorable {}
extension String:   UserDefaultsStorable {}
extension Data:     UserDefaultsStorable {}

// Array-of-String is the only collection AppSettings uses.
extension Array: UserDefaultsStorable where Element == String {}

// MARK: - UserDefaults typed helpers

extension UserDefaults {
    /// Typed read for plist-native values. Returns nil when the key is absent.
    func appDefaultRead<V: UserDefaultsStorable>(forKey key: String) -> V? {
        switch V.self {
        case is Bool.Type:    return bool(forKey: key) as? V
        case is Int.Type:     return integer(forKey: key) as? V
        case is Double.Type:  return double(forKey: key) as? V
        case is String.Type:  return string(forKey: key) as? V
        case is Data.Type:    return data(forKey: key) as? V
        case is [String].Type: return stringArray(forKey: key) as? V
        default:              return object(forKey: key) as? V
        }
    }

    // Bool needs a nil-vs-false sentinel check so we do not return the
    // default false when the key was never written.
    func appDefaultRead(forKey key: String) -> Bool? {
        guard object(forKey: key) != nil else { return nil }
        return bool(forKey: key)
    }

    // Int needs the same sentinel: integer(forKey:) returns 0 for absent keys.
    func appDefaultRead(forKey key: String) -> Int? {
        guard object(forKey: key) != nil else { return nil }
        return integer(forKey: key)
    }

    // Double: double(forKey:) returns 0.0 for absent keys.
    func appDefaultRead(forKey key: String) -> Double? {
        guard object(forKey: key) != nil else { return nil }
        return double(forKey: key)
    }

    /// Typed write for plist-native values.
    func appDefaultWrite<V: UserDefaultsStorable>(_ value: V, forKey key: String) {
        set(value, forKey: key)
    }
}
