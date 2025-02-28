//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2023–2025 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for Swift project authors
//

private import _TestingInternals

/// The type of the accessor function used to access a test content record.
///
/// - Parameters:
///   - outValue: A pointer to uninitialized memory large enough to contain the
///     corresponding test content record's value.
///   - type: A pointer to the expected type of `outValue`. Use `load(as:)` to
///     get the Swift type, not `unsafeBitCast(_:to:)`.
///   - hint: An optional pointer to a hint value.
///
/// - Returns: Whether or not `outValue` was initialized. The caller is
///   responsible for deinitializing `outValue` if it was initialized.
///
/// - Warning: This type is used to implement the `@Test` macro. Do not use it
///   directly.
public typealias __TestContentRecordAccessor = @convention(c) (
  _ outValue: UnsafeMutableRawPointer,
  _ type: UnsafeRawPointer,
  _ hint: UnsafeRawPointer?
) -> CBool

/// The content of a test content record.
///
/// - Parameters:
///   - kind: The kind of this record.
///   - reserved1: Reserved for future use.
///   - accessor: A function which, when called, produces the test content.
///   - context: Kind-specific context for this record.
///   - reserved2: Reserved for future use.
///
/// - Warning: This type is used to implement the `@Test` macro. Do not use it
///   directly.
public typealias __TestContentRecord = (
  kind: UInt32,
  reserved1: UInt32,
  accessor: __TestContentRecordAccessor?,
  context: UInt,
  reserved2: UInt
)

// MARK: -

/// A protocol describing a type that can be stored as test content at compile
/// time and later discovered at runtime.
///
/// This protocol is used to bring some Swift type safety to the ABI described
/// in `ABI/TestContent.md`. Refer to that document for more information about
/// this protocol's requirements.
///
/// This protocol is not part of the public interface of the testing library. In
/// the future, we could make it public if we want to support runtime discovery
/// of test content by second- or third-party code.
protocol TestContent: ~Copyable {
  /// The unique "kind" value associated with this type.
  ///
  /// The value of this property is reserved for each test content type. See
  /// `ABI/TestContent.md` for a list of values and corresponding types.
  static var testContentKind: UInt32 { get }

  /// A type of "hint" passed to ``allTestContentRecords()`` to help the testing
  /// library find the correct result.
  ///
  /// By default, this type equals `Never`, indicating that this type of test
  /// content does not support hinting during discovery.
  associatedtype TestContentAccessorHint: Sendable = Never

  /// The type to pass (by address) as the accessor function's `type` argument.
  ///
  /// The default value of this property is `Self.self`. A conforming type can
  /// override the default implementation to substitute another type (e.g. if
  /// the conforming type is not public but records are created during macro
  /// expansion and can only reference public types.)
  static var testContentAccessorTypeArgument: any ~Copyable.Type { get }
}

extension TestContent where Self: ~Copyable {
  static var testContentAccessorTypeArgument: any ~Copyable.Type {
    self
  }
}

// MARK: - Individual test content records

/// A type describing a test content record of a particular (known) type.
///
/// Instances of this type can be created by calling
/// ``TestContent/allTestContentRecords()`` on a type that conforms to
/// ``TestContent``.
///
/// This type is not part of the public interface of the testing library. In the
/// future, we could make it public if we want to support runtime discovery of
/// test content by second- or third-party code.
struct TestContentRecord<T>: Sendable where T: TestContent & ~Copyable {
  /// The base address of the image containing this instance, if known.
  ///
  /// On platforms such as WASI that statically link to the testing library, the
  /// value of this property is always `nil`.
  ///
  /// - Note: The value of this property is distinct from the pointer returned
  ///   by `dlopen()` (on platforms that have that function) and cannot be used
  ///   with interfaces such as `dlsym()` that expect such a pointer.
  nonisolated(unsafe) var imageAddress: UnsafeRawPointer?

  /// The underlying test content record loaded from a metadata section.
  private var _record: __TestContentRecord

  fileprivate init(imageAddress: UnsafeRawPointer?, record: __TestContentRecord) {
    self.imageAddress = imageAddress
    self._record = record
  }

  /// The context value for this test content record.
  var context: UInt {
    _record.context
  }

  /// Load the value represented by this record.
  ///
  /// - Parameters:
  ///   - hint: An optional hint value. If not `nil`, this value is passed to
  ///     the accessor function of the underlying test content record.
  ///
  /// - Returns: An instance of the test content type `T`, or `nil` if the
  ///   underlying test content record did not match `hint` or otherwise did not
  ///   produce a value.
  ///
  /// If this function is called more than once on the same instance, a new
  /// value is created on each call.
  func load(withHint hint: T.TestContentAccessorHint? = nil) -> T? {
    guard let accessor = _record.accessor else {
      return nil
    }

    return withUnsafePointer(to: T.testContentAccessorTypeArgument) { type in
      withUnsafeTemporaryAllocation(of: T.self, capacity: 1) { buffer in
        let initialized = if let hint {
          withUnsafePointer(to: hint) { hint in
            accessor(buffer.baseAddress!, type, hint)
          }
        } else {
          accessor(buffer.baseAddress!, type, nil)
        }
        guard initialized else {
          return nil
        }
        return buffer.baseAddress!.move()
      }
    }
  }
}

// MARK: - Enumeration of test content records

extension TestContent where Self: ~Copyable {
  /// Get all test content of this type known to Swift and found in the current
  /// process.
  ///
  /// - Returns: A sequence of instances of ``TestContentRecord``. Only test
  ///   content records matching this ``TestContent`` type's requirements are
  ///   included in the sequence.
  ///
  /// - Bug: This function returns an instance of `AnySequence` instead of an
  ///   opaque type due to a compiler crash. ([143080508](rdar://143080508))
  static func allTestContentRecords() -> AnySequence<TestContentRecord<Self>> {
    let result = SectionBounds.all(.testContent).lazy.flatMap { sb in
      sb.buffer.withMemoryRebound(to: __TestContentRecord.self) { records in
        records.lazy
          .filter { $0.kind == testContentKind }
          .map { TestContentRecord<Self>(imageAddress: sb.imageAddress, record: $0) }
      }
    }
    return AnySequence(result)
  }
}
